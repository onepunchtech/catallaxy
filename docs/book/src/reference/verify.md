# Verifying a Running Lab

`cata lab verify` is to a running lab what [`lab lint`](./lint.md) is to a
rendered one. Lint reads manifests and needs no cluster; verify reads live
state and needs the lab to be up.

```bash
cata --flake .#<lab> lab verify
cata --flake .#<lab> lab verify --check endpoints
cata --flake .#<lab> lab verify --json
```

Exit code is non-zero if any diagnostic is an error, which is what makes it
usable from a script. `--json` emits the diagnostics array for a caller that
wants to do something with them.

## What it checks

In this order, because each is only meaningful when the ones before it
passed:

| Check       | Question                                                             |
| ----------- | -------------------------------------------------------------------- |
| `clusters`  | does every cluster's apiserver answer at its runtime context         |
| `services`  | is every host service running, and does its ready probe pass         |
| `rollouts`  | does every lab-owned namespace exist, with every workload rolled out |
| `endpoints` | does every hostname the lab routes answer                            |
| `declared`  | do the lab's own `lab.verify.checks` pass                            |

`rollouts` reads the namespaces from the lab rather than from the cluster,
so a namespace the lab declares and the cluster does not have is a finding
rather than an absence nobody notices.

## The endpoint check is the one that earns its keep

The others restate things `lab up` already waited for. `endpoints` does not:
it goes out through the lab's ingress, gets routed by hostname, and comes
back through a workload, over TLS signed by the lab's own CA. No amount of
eval or lint can exercise that.

The hosts come from the `HTTPRoute` and `TLSRoute` resources the bundles
declare, not from each floe's `domain` option. A floe may route a name it
does not own, and `floes.custom` routes names that belong to the app rather
than to the floe, so the routes are the only complete answer. Wildcard
hostnames belong to a gateway's certificate rather than to anything you can
GET, and are left out.

Hosts the gateway lists as internal-tier resolve only from inside the lab's
mesh, so they are skipped rather than probed and failed.

Each host is pinned to the proxy's published address rather than looked up,
so this works whether or not [`lab.dns.configureHost`](./options/lab.md)
pointed your machine's resolver at the lab. Nothing about verifying a lab
needs `sudo`.

Anything below a 500 counts as an answer: the routing is what is under test,
not the application's opinion of the request. A lab that expects a status
the default rejects adds it to `lab.verify.endpoints.acceptStatuses`.

## Checks a floe ships

A floe declares assertions about itself at `floes.<n>.verify.<name>`, beside
the `readyProbe` it already writes. `readyProbe` gates the install wave;
these answer "is it still right". Every lab enabling the floe inherits them,
which is why coverage grows as floes are written rather than as labs are
hand-edited: `gitops.local` declares none of the five checks it runs.

They are [Chainsaw](https://kyverno.github.io/chainsaw/) assertions,
declared in Nix and rendered to one `Test` per cluster into the lab package
at `verify/<cluster>/`. A lab adds its own the same way at
`lab.verify.checks.<n>` or `cluster.verify.checks.<n>`.

### `expect` is "at least one"

```nix
floes.forgejo.verify.bootstrap-completed = {
  description = "The forgejo bootstrap Job created the orgs, repos and deploy keys";
  expect = {
    apiVersion = "batch/v1";
    kind = "Job";
    metadata.namespace = "forgejo";
    metadata.labels."app.kubernetes.io/component" = "forgejo-bootstrap";
    status.succeeded = 1;
  };
};
```

`expect` is Chainsaw's `assert`, and naming a kind without a name matches
**at least one** resource. With two of that kind, one matching and one not,
it passes. That makes it the wrong tool for "every X is fine".

### `reject` is how you say "all of them"

Say instead that none of them is not fine:

```nix
floes.argocd.verify.applications-converged = {
  description = "Every argocd Application reached Synced and Healthy";
  timeout = "10m";
  reject = [
    {
      apiVersion = "argoproj.io/v1alpha1";
      kind = "Application";
      metadata.namespace = cfg.namespace;
      ${verifyTypes.fieldIsNot { field = "status.health.status"; value = "Healthy"; }} = true;
    }
  ];
};
```

Build the expression with `verifyTypes.fieldIsNot` or `conditionIsNot`
rather than by hand. Two things bite otherwise. JMESPath's `|` binds looser
than `&&`, so the obvious spelling parses as a pipeline and evaluates to
nonsense without erroring. And the null guard is not decoration: selection
is a wildcard over the kind, every namespace carries an auto-injected
`kube-root-ca.crt`, and its missing field makes a bare `field != 'x'` true.

### Namespaces

A check on a namespaced kind is scoped to the namespace it names. Omit it
and the check silently searches one namespace and finds nothing, which
passes. Assert about what your floe owns, in the namespace it owns.

### Verify does not change anything

The rendered tests pin a namespace and set `skipDelete`, and an eval-time
assertion refuses any operation other than `assert` and `error`. Running
`cata lab verify` against a lab you care about is not a question you have to
think about.

## The escape hatch

`steps` takes raw Chainsaw steps for an assertion `expect` and `reject`
cannot express, including Chainsaw's own `script` and `command` operations.
That is deliberately the only shell in the picture: there is one vocabulary
for declared checks rather than a second one beside it.
