# Bootstrap and Pivot

Your child clusters get GitOps, drift detection and reconciliation. The
management cluster that runs all of that got clicked into existence by
somebody following a wiki page. It is always the special case, and it is the
one you least want to be a special case, because rebuilding it is exactly
what you are doing on your worst day.

Pivot is how catallaxy closes that loop. A cloud cluster provisions itself,
and then takes over managing itself.

## The idea

You cannot run Crossplane on a cluster that does not exist yet. So you run
it somewhere temporary, let it build the real cluster, then move the
controllers and their state into the cluster they just built and throw the
temporary one away.

```
k3d bootstrap ──provisions──> cloud cluster
      │                             ▲
      └────── move state ───────────┘
      │
   destroyed
```

The bootstrap is a local k3d cluster. It exists for a few minutes and is
never mentioned again.

## When it happens

You do not ask for a pivot. It is derived.

A cluster is **self-provisioning** when it appears in its own list of
clusters to provision, that is, when the cluster named `prod` declares
`floes.crossplane.digitalocean.kubernetesClusters.prod` or
`floes.cluster-api.clusters.prod`. That self-reference is the signal, and
the planner inserts the whole sequence for it.

Declare a cluster that provisions some _other_ cluster and you get no pivot,
because nothing needs to move; the provisioner stays where it is.

## The sequence

The sequence, all of it visible in `cata lab plan`:

| Step                 | Does                                                       |
| -------------------- | ---------------------------------------------------------- |
| `create-cluster`     | stand up the local k3d bootstrap                           |
| `deploy-manifests`   | apply **stage1** to the bootstrap                          |
| `wait-for-resources` | wait for the provisioner to report the cloud cluster ready |
| `sync-kubeconfig`    | fetch the new cluster's kubeconfig and context             |
| `pivot`              | move state across, then destroy the bootstrap              |

Stage1 is the subset of bundles needed to provision: the provisioner itself,
its CRDs, its credentials. A bundle opts out with
`includeInBootstrap = false`, which is how you keep your application
workloads from being installed onto a cluster that is about to be deleted.

Everything after the pivot targets the cloud context. `cata lab plan` shows
this: the ArgoCD install step's predecessor is `pivot-<cluster>` rather than
`create-cluster-<cluster>`, so the CD bootstrap lands on the real cluster.

## What moving state means

It depends on the provisioner, because the two have different notions of
where ownership lives.

**Crossplane** waits for its own controllers to come up on the target, then
copies the `crossplane.io/external-name` annotations across. Those
annotations are what tie a managed resource to the real cloud object, so
copying them is what makes the new controller adopt the existing droplet
rather than create a second one. It waits for the managed resources to
report ready, then orphans them on the bootstrap so tearing the bootstrap
down does not delete the cluster it just built.

**CAPI** has a purpose-built command for this and catallaxy uses it:
`clusterctl move --to-kubeconfig-context <target>`.

Then the bootstrap cluster is deprovisioned.

## Running it twice

`pivot` is a one-shot step, and it carries `policy.skipIfClusterReachable`.
If the cloud cluster already answers, the pivot is skipped: stage1 is
applied directly to the real cluster, and any bootstrap cluster still lying
around from an interrupted run gets cleaned up.

So `cata lab up` on an already-pivoted lab does the right thing, and an
interrupted pivot is recoverable by running it again rather than by hand.

## What you get

The cloud cluster runs the controllers that manage the cloud cluster. There
is no bootstrap cluster left, no `terraform.tfstate` anybody has to find,
and no wiki page. Rebuilding is `cata lab up` from a clean machine.
