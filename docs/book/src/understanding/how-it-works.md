# How It Works

Your configuration is evaluated by Nix into two things: an ordered plan, and
a tree of rendered manifests. A Rust CLI then executes them. Nothing is
computed at apply time.

```
your modules ──nix eval──> a plan + rendered manifests ──cata──> clusters
```

The consequence worth knowing up front is that everything is decided before
anything runs, so `cata lab plan` and `cata lab plan-manifests` show you the
whole decision without touching a cluster.

## The three layers

| Directory  | Is                                            | Public?                             |
| ---------- | --------------------------------------------- | ----------------------------------- |
| `modules/` | the option tree: everything a lab can declare | internal, configure through options |
| `lib/`     | the algorithms: graphs, plans, rendering      | `lib/pure.nix` only                 |
| `cli/`     | `cata`: executes the plan                     | the CLI surface                     |

`cli/` is organised so that only `io/` talks to the outside world;
`domain/`, `plan/`, `lint/`, `codegen/` and `topology/` are pure, and
`commands/` is thin glue.

## The seam

Nix and Rust meet at exactly two commands:

```bash
nix eval  --json …#legacyPackages.<system>.labs."<lab>"          # what to do
nix build       …#legacyPackages.<system>.labPackages."<lab>"    # what to do it with
```

The first resolves to `lab.out.cliConfig` and is parsed once into a typed
`LabSpec`. The second resolves to `lab.out.package`: a store path holding
the rendered manifests, the lint checks, and every hook binary.

The CLI re-derives nothing. The Rust code is as dumb as possible. This is
essentially the interpreter pattern. The definition for what to do is all
contained in Nix. The actions for how are in Rust.

## Ordering: two graphs

With the complexity of Kubernetes it is easy to get tangled up in the order
of deploying or applying things. This is where catallaxy shines. By
introducing structure with floes it can build a dependency graph so that the
deployment order is automatically derived. Each node says what it needs and
what it offers, and the order is computed. There are two graphs, and they
share a vocabulary without sharing anything else:

|             | Install graph             | Plan graph         |
| ----------- | ------------------------- | ------------------ |
| orders      | bundles                   | steps              |
| within      | one cluster               | the whole lab      |
| declared at | `bundles.<name>`          | `lab.steps.<name>` |
| printed by  | `cata lab plan-manifests` | `cata lab plan`    |

Think of the install graph as the graph that tracks the order in which to
apply Kubernetes resources. The plan graph is for things outside of the
Kubernetes API like infrastructure, scripts, or ad-hoc jobs. Things that
need to happen in a certain order but that we can't rely on Kubernetes to
schedule it.

A bundle declares tokens:

```nix
bundles.cert-manager = {
  requires = [ "cert-manager/crds/established" ];  # must be READY first
  provides = [ "cert-manager/webhook/ready" ];     # what I offer once ready
  after    = [ "bundle:namespaces" ];              # sequence only, no readiness
  readyProbe = { /* how "ready" is decided */ };
};
```

Tokens are arbitrary strings; only the matching matters. A token names a
_state_, not a bundle, so renaming or splitting the bundle that satisfies it
breaks nothing.

`after` and `requires` differ in one way that matters: `after` means "a
later wave than that", while `requires` means "that must be **ready**
first". Applying a CRD and the CRD being usable are two different moments.

Bundles whose requirements are all met form a **wave** and install together.
Some edges are derived rather than written. A namespaced resource depends on
whatever declares its namespace, a custom resource on whatever declares its
CRD.

Steps work the same way, over the actions that are not applying a manifest:
creating a cluster, setting up host DNS, copying a Secret between clusters.
The CLI does one thing with them: `topoSort(steps)`, then execute in order.

A step anchor cannot name another step. A name belongs to whichever module
emitted it and moves when that module changes, so the plan graph only
resolves published tokens and step kinds. That is what lets a cluster's
floe, an aspect and the framework each contribute steps without any of them
knowing what the others called theirs.

Some step edges are derived too. A kind declares whether it dials a lab
endpoint from the operator's machine, so a lab that puts its endpoints
behind a mesh publishes `host/lab-reachable` once and every such step waits,
without naming any of them.
