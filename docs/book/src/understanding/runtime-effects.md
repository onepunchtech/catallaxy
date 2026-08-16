# Runtime Effects

Most of what catallaxy applies is inert. A Deployment describes a desired
state and Kubernetes converges on it; applying the same Deployment twice
changes nothing the second time.

Bootstrap Jobs are not like that. Applying one calls someone else's API. It
mints a token, creates a repository, uploads an SSH key, deletes a policy.
The manifest is declarative; running it is not.

Catallaxy has no vocabulary for that difference in the install graph, and
this page is about what that costs.

## The symptom

`nix/checks/scripts.nix` lints the shell scripts under
`modules/lab/cluster/floes/netbird/scripts/`. It runs shellcheck but
deliberately does not run `shfmt`, and the comment says why: reformatting
those files would change their text, which would change a hash, which would
re-run every netbird bootstrap Job on the next deploy.

A whitespace change causes calls to a live API. That is why the formatter is
not adopted.

## How the current mechanism works

A Job's `spec.template` is immutable. Change the script inside a Job that
already exists and you cannot update it — you can only replace it. So a
one-shot bootstrap Job that ever changes becomes a permanent sync error.

`lib/util/idempotent-job.nix` avoids that by content-addressing the Job:

```nix
hash = hashContent { inherit contentInputs podSpec; };
jobName = "${name}-${hash}";
```

Same content, same name, and applying is a no-op. Changed content, new name,
and a new Job object that runs immediately.

The hash lands in four places: the Job's name, a label on the Job, a label
on the pod template, and a key in the `<name>-runs` ConfigMap.

## Why cosmetic changes re-run things

Two reasons, and they compound.

**The hash covers the whole pod spec, not just what you declared.** The
argument is `{ inherit contentInputs podSpec; }`. `podSpec` holds the image,
the command, the environment, the volumes. Bump a `bootstrapImage` tag or
reorder an `env` list and the hash moves, even though nothing about the
desired state changed.

**Some call sites put the implementation into the declaration.** The netbird
routing and admin-reconciler Jobs list `image` and `script` in their
`contentInputs`, so the script text is content twice over.

Until recently the reference page for `mkIdempotentJob` said the name
carried "a SHA256 of `contentInputs`", which is the design we actually want.
The code never did that, and the gap between the two is the bug.

## What actually happens on a re-run

Worth being precise, because the mechanism is worse than the consequences.
Most of these scripts are already guarded:

| Job                                                        | On re-run                                                                                               |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `argocd-redis-secret-init`                                 | nothing; its Role grants create, not update                                                             |
| netbird PAT mint                                           | re-validates the existing token and skips on success                                                    |
| netbird relay secret, datastore key, harbor admin password | `get secret \|\| create`; never re-mints                                                                |
| netbird routing, admin reconciler                          | already re-run every two minutes by a CronJob                                                           |
| kanidm heal                                                | exits early when authentication is healthy                                                              |
| forgejo deploy keys                                        | **mints a new keypair and deletes the old one upstream** if the target Secret is missing or has drifted |

One Job in that list is genuinely dangerous. The problem is that the
mechanism cannot tell you which, so the whole class has to be treated as if
it were.

## The asymmetry

The plan graph already grades work by consequence. Every step kind under
`modules/lab/planner/kinds/` declares one of three values:

```nix
idempotency = "idempotent";   # or "oneShot", or "destructive"
```

The CLI reads it and decides how many times a failed step may be retried.
`create-cluster` is `oneShot`. `delete-managed-resource` is `destructive`.
`deploy-manifests` is `idempotent`.

The install graph has no equivalent. A bundle says what it `requires` and
what it `provides` — what must be true before it lands, and what is true
after. It cannot say what applying it _does_, so nothing downstream can
reason about it.

That is the actual gap. Everything else on this page follows from it.

## Two related defects

**A bundle of only Jobs is not waited on.** When a bundle has no
`readyProbe`, the applier falls back to waiting for workload rollout, and
that only recognises Deployments, StatefulSets and DaemonSets. A bundle
containing only Jobs is not waited on at all, and the next wave starts while
it is still running. `bundles.netbird-admin-reconciler` has exactly this
shape.

**Label selectors match every generation.** Bundles wait on Jobs by label,
never by the hashed name, because the name rotates:

```
kubectl wait --for=condition=complete job -l catallaxy.io/netbird-routing=true
```

That selector matches every generation at once. The kapp and ArgoCD paths
prune the old ones, but the plain server-side-apply path prunes nothing, so
a failed Job from an earlier hash stays in the namespace and the probe waits
on it too.

## The fix

1. Hash `contentInputs` only.
2. Stop declaring `script` and `image` as content in the call sites that
   did.
3. Add `behaviourVersion`, for the change declarations cannot express.

The rule that falls out is worth stating on its own: **the hash covers what
you declare, not how you implemented it.** Reformatting a script is not a
change to desired state. Bumping a base image is not a change to desired
state. Adding a repository to forgejo's list is, and forgejo keeps
re-running when it happens.

That is the whole of the reported problem, and it needs no new options, no
CLI work and no migration.

## The larger design, and its cost

The fix above makes cosmetic changes inert. It does not give you _control_ —
you still cannot say "this Job must never re-run unless I ask". Getting that
means separating a Job's identity from its content: the name comes from a
declared revision, the content hash becomes an annotation for reporting, and
a re-run happens only when the revision is bumped or the Job is graded
`idempotent`.

It is worth writing down why that is not simply better.

**It requires create-only apply.** Once the name stops moving, the rendered
`spec.template` differs from the live one and applying it is an
immutable-field error. The Job must be created if absent and otherwise left
alone. Each backend spells that differently: kapp has
`update-strategy: skip`, which this repo already relies on elsewhere; ArgoCD
has `ignoreDifferences`, and `RespectIgnoreDifferences` is already set; the
server-side-apply path needs new code; and Fleet's `comparePatches` is
per-bundle, so it would ignore more than intended.

**One existing annotation becomes a landmine.** The helper sets
`kapp.k14s.io/update-strategy: fallback-on-replace`. Today that never fires,
because a content change produces a different name and therefore a create
rather than an update. The moment names stop moving it starts meaning
"delete and recreate this Job whenever its template changes" — which is the
bug we set out to remove, arriving silently and only under kapp.

**`ttlSecondsAfterFinished` becomes unsafe.** Under create-only, the Job's
existence is the record that it ran. Deleting a completed Job on a timer
means the next deploy re-creates it.

**A noisy failure becomes a quiet one.** Add a repository to forgejo's
config, forget to bump the revision, and the deploy is green while nothing
happened. Today that case is automatic and correct.

**And it still does not deliver the guarantee.** Deleting the Job object is
indistinguishable from its never having run. A namespace recreate, a stray
`kubectl delete`, or an accidental prune all re-create it, and a credential
rotation fires unattended. Closing that needs the payload itself to check
whether its work is already done — a pattern the netbird secret-mint Jobs
already use by hand, with `kubectl get secret && exit 0`.

So the direction is right and the sequencing matters: fix the hash first,
because it costs nothing and solves the reported problem; adopt identity and
grading only where the guarantee is worth the machinery, which is the three
or four Jobs that mint credentials.
