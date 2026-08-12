# mesh: a lab reachable only over a VPN

This lab's services are reachable only from a WireGuard mesh. It exists to
answer the question the other examples cannot: _what does an awkward
requirement look like in this framework?_

The short answer is that it looks like the same mechanisms everything else
uses. No bespoke tooling, no manual runbook step, no "and then someone SSHes
in".

## What it is

Two k3d clusters:

- **mgmt**, kanidm, the netbird management server and operator, and an
  internal-tier gateway whose Service holds a pinned ClusterIP.
- **apps**: a peer-only cluster: a netbird agent advertising its own Service
  CIDR, an internal-tier gateway, and one app behind it.

Each cluster runs a demo page behind its own internal gateway, so both
halves of the mesh are visible rather than just one:

| Name                       | Cluster | Reached via                          |
| -------------------------- | ------- | ------------------------------------ |
| `ops.internal.mesh.test`   | mgmt    | mgmt internal gateway, over the mesh |
| `hello.internal.mesh.test` | apps    | apps internal gateway, over the mesh |
| `idm.mesh.test`            | mgmt    | the host ingress, publicly           |

The split is the point. `mesh.test` stays with the lab's own DNS and the
host ingress; `internal.mesh.test` is handed to netbird, which is why both
resolve at once. Leave the mesh and the internal names stop resolving: the
lab's authoritative DNS answers NXDOMAIN for them.

Each cluster gets its own netbird Network and router group, because routing
peers are redundant paths to one Network's whole resource set: a Network
spanning both clusters would balance traffic onto a router that cannot reach
half of it.

## Running it

This lab has a two-tier CA, so unlike the other examples it needs a secret
store before it will come up: `lab.secrets.stores.trust` holds the root CA,
and `lab up` decrypts it during preflight.

You need an age key and a `.sops.yaml` rule for `secrets/mesh\.local/`; see
[Secrets](../README.md#secrets) for both. With that in place:

```bash
cata --flake .#mesh.local lab ops -- trust init-ca
cata --flake .#mesh.local lab plan
cata --flake .#mesh.local lab up
```

`init-ca` mints a 4096-bit CA and SOPS-encrypts it to
`secrets/mesh.local/trust.enc.yaml`. It is throwaway and local: the store is
gitignored, so every operator runs this once against their own key rather
than sharing one.

`lab up` writes the decrypted CA to
`~/.local/share/catallaxy/labs/mesh.local/proxy/{ca.crt,ca.key}` (`.crt`
0644, `.key` 0600) and brings up a netbird daemon on your machine, isolated
from your personal one.

## The plan it produces

`cata --flake .#mesh.local lab plan` prints the usual local-lab preamble
(certificates, network, host trust, services, then a cluster each), and then
two steps this lab added: a `run-script` that joins the mesh, and a
`cross-cluster-secret-copy` that carries a Secret from `mgmt` to `apps`.

Neither names a position. They land at the tail because of what they
declared, which is the point of the rest of this page.

## The mechanisms

### A lab-wide exposure policy

```nix
lab.policy.exposure.defaultTier = "internal";
```

One line. Every floe's `gateway.tier` inherits it, so a floe added next
month is behind the mesh because that is the lab's default, not because
somebody remembered.

This option exists because the alternative was observed: the tier restated
at every consumer, with the framework default set to the _permissive_ value.
A security property enforced by copy-paste holds until the first time
someone copies imperfectly.

### A step that moves a credential

The netbird operator on mgmt mints a setup key as a Kubernetes Secret. The
apps cluster needs its value. Reading an export would give apps the right
_address_ for something on mgmt. This is a value that has to be transported.

```nix
lab.steps.xcs-netbird-router-key = {
  kind = "cross-cluster-secret-copy";
  after = map (c: t.needs (t.cluster c).reachable) [ "mgmt" "apps" ];
  params = {
    sourceCluster = "mgmt";  sourceNamespace = "netbird";
    sourceSecret  = "setup-key-cluster-router-apps";
    targetCluster = "apps";  targetNamespace = "netbird";
    targetSecret  = "setup-key-cluster-router-apps";
  };
};
```

Both anchors are hard, and both are load-bearing: the source has to have
minted the key, and the target cluster has to exist to receive it. The first
draft of this example anchored only on mgmt, and the plan cheerfully
scheduled the copy _before the apps cluster was created_, visible
immediately in `lab plan`, which is the point of printing it.

Neither anchor names a step. `t.cluster "mgmt"` is `lib.planTokens`, which
carries the framework's own token strings, and `cluster/mgmt/reachable` is
published by whatever brings that cluster up: `create-cluster` locally, or a
`pivot` in an environment that bootstraps a cloud cluster. Anchoring on the
capability is what lets the same line hold in both.

### A step the lab does not have to write

Everything in this lab lives behind the mesh, so the machine running `cata`
has to be _on_ the mesh before any later step dials a mesh-only address.

Nothing in this lab says so. Enabling `floes.netbird` is what produces the
step:

```
[013] deploy-manifests  name=deploy-manifests-mgmt  params.target=mgmt
[014] run-script        name=mgmt-netbird-mesh-join policy.interactive=true
[015] cross-cluster-secret-copy  name=xcs-netbird-router-key ...
```

The floe declares it, in the same DSL a lab would use:

```nix
steps.netbird-mesh-join = {
  kind = "run-script";
  direction = "deploy";
  scope = "lab";                    # the operator's machine, not a cluster
  policy.interactive = true;        # a human completes the browser login
  provides = [ "netbird/mesh/joined" t.lab.reachable ];
  after = t.wantsAll [
    (t.cluster config.cluster.name).deployed   # management must exist
    t.lab.hostTrust                            # CA before HTTPS
    t.lab.hostDns                              # *.<zone> must resolve
  ];
};
```

That the join belongs to netbird and not to this lab is the whole point: a
lab expresses _what it wants_, and how the host reaches a mesh-only endpoint
is an implementation detail of the floe providing the mesh. An earlier draft
of this example carried a netbird-named `run-script` step here, purely
because a floe had no way to declare one.

The step has no `before` list, and that is the interesting half.
`t.lab.reachable` is `host/lab-reachable`: a claim that the lab's endpoints
now answer from this machine. Each step kind declares whether it dials one,
in `modules/lab/planner/kinds/`, and the planner adds the edge. So the copy
at [015] waits without the mesh floe having heard of it, and so would a
`publish-images` or an argocd root application, in a lab that had them.

An earlier draft did enumerate them,
`before = [ "optional:kind:publish-images" ... ]`, and it was wrong in a way
that only showed up in a different environment: the list held for this lab
and missed two kinds in one that pivots.

The `after` half stays the lab's own problem, because only netbird knows
that its management server has to exist first. With just the host-side
anchors the topological sort hoisted the join to step 8, before the clusters
existed. Visible immediately in `lab plan`, which is the point of printing
it.

### The netbird the lab runs is the lab's

The client is not taken from the operator's PATH:

```nix
floes.netbird.client.package = pkgs.netbird;   # override to stage an upgrade
```

The CLI has to match the daemon it talks to over a socket, and the daemon
has to match the management server. A host install therefore pins every lab
on the machine to one version, which makes "test the upgrade in staging
first" impossible without touching the host, the exact thing a staging lab
exists to avoid.

So the arrow is reversed. `floes.netbird.version` follows `client.package`,
and management, signal, relay and the in-cluster agent tags all follow that.
Staging a netbird upgrade is one line, and a skewed pair fails at `nix eval`
rather than by hanging silently during peer registration.

The lab's client runs its own daemon on its own service name, socket,
profile, WireGuard interface and UDP port, so your personal netbird (the one
you use for meshes you did not build) is untouched by `lab up`. Ask this
lab's daemon about itself with:

```bash
cata --flake '.#mesh.local' lab ops -- netbird status
```

A bare `netbird status` answers about yours.

### Identity as the authorization source

Mesh access is decided by group membership, and the groups come from kanidm:

```nix
floes.netbird.operator = {
  autoGroupsFromJwt = [
    "netbird-users@idm.${dns.zone}"
    "netbird-admins@idm.${dns.zone}"
  ];
  adminGroupsFromJwt = [ "netbird-admins@idm.${dns.zone}" ];
};

floes.netbird.routing.resources = {
  internal-gateway = {
    address = config.floes.gateway.internal.clusterIPAddress;
    sourceGroups = [ "netbird-users@idm.${dns.zone}"
                     "netbird-admins@idm.${dns.zone}" ];
  };
  cluster-services = {
    address = config.cluster.network.serviceSubnet;
    sourceGroups = [ "netbird-admins@idm.${dns.zone}" ];
  };
};
```

Changing someone's mesh access is a group-membership edit in
`aspects/identity.nix`. Adding a role is three edits: the group, an entry in
`autoGroupsFromJwt`, and a mention in `sourceGroups`.

The addresses are read, not written: the gateway's pinned ClusterIP and the
cluster's Service CIDR both come from config. Hardcoding either gives you a
mesh that routes to the wrong place after an unrelated change.

Note what is deliberately **not** set: `serviceCIDR`, `podCIDR`,
`apiServerHost` on `routing`. Those lift into implicit resources gated on
the whole mesh: the opposite of role-scoped access.

## Two sharp edges worth reading

**Group SPNs, not names.** Kanidm returns `netbird-admins@idm.mesh.test`,
not `netbird-admins`. Every consumer that matches on groups has to expect
the SPN form.

**One OAuth2 client, not two.** The CLI's PKCE loopback flow and the browser
dashboard share a client. Kanidm mints per-client signing keys, so a
separate dashboard client would issue `id_tokens` signed by a key the
management server, which fetches JWKS from the _other_ client's discovery
URL, cannot verify. The symptom is a 401 saying "unable to find appropriate
key".

## What it is not

A production mesh deployment. It is trimmed to two roles and two network
resources so the mechanisms are visible. A real one carries more roles, more
resources, and more identity plumbing.

It is also not the recommended shape for a normal lab. `../homelab` is that.
This one exists to show the framework does not run out of vocabulary when
the requirement gets strange.

## Related

- [Configure a Lab](https://onepunchtech.github.io/catallaxy/using/configuring.html)
- [How It Works](https://onepunchtech.github.io/catallaxy/understanding/how-it-works.html)
