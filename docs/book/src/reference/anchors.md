# Anchors and Tokens

Catallaxy has two dependency graphs. They share this grammar and nothing
else:

|             | Nodes                       | Where you author edges                           |
| ----------- | --------------------------- | ------------------------------------------------ |
| Install DAG | bundles, within one cluster | `bundles.<b>.{after,requires,provides}`          |
| Plan DAG    | steps, across the whole lab | `lab.steps.<n>.{after,before,requires,provides}` |

Both are explained in [How It Works](../understanding/how-it-works.md).

## Anchor grammar

An _anchor_ is a string naming other nodes. It resolves to a set, and every
member becomes a predecessor.

Install DAG (`lib/eval/manifest-graph.nix`):

| Form               | Matches                                          |
| ------------------ | ------------------------------------------------ |
| `<name>`           | the bundle with that exact key                   |
| `bundle:<name>`    | the same, written explicitly                     |
| `kind:<k8s-kind>`  | bundles whose `.kind` is that Kubernetes kind    |
| `floe:<floe-name>` | bundles emitted by that floe                     |
| `provides:<token>` | every bundle whose `provides` contains the token |
| `optional:<expr>`  | any of the above, but a miss is silent           |

Plan DAG (`lib/eval/plan-graph.nix`):

| Form                    | Matches                                        |
| ----------------------- | ---------------------------------------------- |
| `kind:<kind>`           | every step of that kind                        |
| `kind:<kind>:<cluster>` | steps of that kind acting on that cluster      |
| `provides:<token>`      | every step whose `provides` contains the token |
| `optional:<expr>`       | either of the above, but a miss is silent      |

A bare step name is **not** an anchor here, and neither install nor plan
anchors accept one across module boundaries. A name is its emitter's private
vocabulary and moves when the emitter changes; a published token is the
interface. If the step you meant publishes no token, give it one.

Build these through `lib.planTokens` rather than by writing the strings:

```nix
let t = catallaxy.lib.planTokens; in
{
  after = [ (t.needs (t.cluster "mgmt").reachable) ];
  before = [ (t.wants t.lab.manifestsPushed) ];
}
```

`needs` is a hard `provides:` anchor, `wants` the `optional:` form, and
`t.cluster <name>` and `t.lab` carry the framework's own token names, so a
typo is an eval error at the definition rather than a silently missing edge.

`kind:<Kind>` on the install side matches every bundle that declares a
resource of that kind, which is how "after every CRD bundle" is said without
naming each one:

```nix
after = [ "kind:CustomResourceDefinition" ];
```

A bundle's kinds come from its `resources` and nothing else. A kind inside a
`helmCharts` or `yamls` entry is a rendered artefact, not something eval can
see, so a chart-only bundle answers no `kind:` anchor and is reached by
`provides:` or `bundle:` instead.

`floe:<name>` matches every bundle a floe declared. Provenance is stamped
automatically at the point `mkFloe` merges a floe's module output, so a floe
author never sets it and cannot forget to. A bundle a lab declares directly
answers no `floe:` anchor.

## The fail-loud contract

These throw at eval rather than surfacing at apply time: a hard anchor that
matches nothing, a `requires` token nobody provides, and a cycle (reported
with the strongly-connected set). Each message names the offending bundle
and tells you what to do about it.

A `requires` nobody satisfies usually means a floe was enabled without its
dependency; `mkFloe`'s own `requires` catches the common cases earlier with
a message naming both floes. A bundle that both provides and requires the
same token is not a cycle, because self-edges are filtered.

## Structural auto-edges

Some edges are derived from Kubernetes shape rather than authored
(`lib/eval/manifest-autoedges.nix`). They are inserted as **hard**
`bundle:<provider>` anchors, because a consumer referencing a namespace, CRD
kind or SecretStore that nothing declares is a real bug.

| Consumer                                                  | Provider                                                    | Why                                                  |
| --------------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------- |
| anything naming a namespace, including `createNamespaces` | the bundle declaring that `Namespace`, or `namespaces/_all` | the apply blocks or fails until it exists            |
| a resource whose `kind` matches a declared CRD            | the bundle providing the CRD                                | applying a CR first races the apiserver schema cache |
| an `ExternalSecret`                                       | the bundle declaring its `spec.secretStoreRef` store        | ESO will not reconcile until the store is Ready      |

Self-references are filtered: a bundle that declares a Namespace and also
puts workloads in it gets no self-edge.

## Synthesized tokens

| Token                | Emitted by                                                                                          |
| -------------------- | --------------------------------------------------------------------------------------------------- |
| `stage1`             | every bundle in the DAG closure of `cluster.provisioning.rootBundles`                               |
| `secret:<ns>/<name>` | the virtual `projection/<name>` bundle. Consumers of that Secret get a matching `requires` injected |

## Finding the tokens a lab actually has

Bundle tokens follow `<scope>/<subject>/<state>`, as in
`cert-manager/webhook/ready`. Plan tokens follow `lab/<thing>` and
`cluster/<name>/<state>`, as in `cluster/prod/pivoted`.

Do not work from a list on this page; which tokens exist depends on which
floes a lab enables. Ask the lab:

```bash
cata --flake .#<lab> lab plan-manifests --cluster <c>   # bundle tokens and waves
cata --flake .#<lab> lab plan                           # steps, and what each provides
```

Take a peer's tokens from its capability rather than spelling them:
`refs.needs peers.gateway.routing "publicReady"` in `requires`, and
`refs.orderAfter` in `after`. No capability, no edge, so the edge appears
exactly when there is something to wait for.

Two are worth knowing by name.

`lab/cleanup` gates the teardown plan. Every destroy, release and remove
waits on it, so a teardown step that must run while the clusters are still
alive publishes it rather than enumerating them:

```nix
steps.drain-my-thing = {
  kind = "run-script";
  direction = "teardown";
  policy.onFailure = "continue";
  provides = [ t.lab.cleanup ];
  params.bin = "${drainScript}/bin/drain";
};
```

`host/lab-reachable` is the deploy-side counterpart, for a lab whose
endpoints are not reachable from the operator's host until something makes
them so, a mesh join being the usual case. Publish it and every step that
dials the lab from the host lands after you:

```nix
steps.join-the-mesh = {
  kind = "run-script";
  direction = "deploy";
  scope = "lab";
  policy.interactive = true;
  provides = [ t.lab.reachable ];
  params.bin = "${joinScript}/bin/join";
};
```

Which steps those are is a property of the kind, declared as
`dialsLabEndpoints` in `modules/lab/planner/kinds/`: `publish-manifests`,
`publish-images`, `apply-root-application` and `bootstrap-forgejo-repos`.
The planner adds the soft edge, so the publisher names one token instead of
listing every kind that might dial something, and the list stays right when
a lab gains a step or an environment emits a different set.

The kinds that bring the lab up are deliberately not on that list. A step
cannot both make the lab reachable and wait for it to be reachable, so
`create-cluster`, `deploy-manifests` and the argocd bootstraps run before
the gate; anchor those the other way round, with the mesh join `after` them.

Prefer `wants` over `needs` when anchoring on a framework token. Which steps
a plan contains depends on the environment: a local k3d lab has no pivot, a
cloud lab has several more, and a hard anchor on a token that environment
never publishes fails eval by design.
