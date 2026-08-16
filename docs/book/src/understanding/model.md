# The Model

A lab holds clusters, a cluster is made up of metadata + floes, and a floe
emits bundles of Kubernetes resources as rendered manifests. Four things,
each inside the one before it:

```
Lab            everything: clusters, host services, secrets, the plan
 └─ Cluster        one Kubernetes cluster
     └─ Floe           one capability
         └─ Bundle        resources that install together
```

Every option path and every error message sits somewhere in that stack.

## A real one

This is the `minimal` example lab, near enough in full: one cluster, a
gateway, one app behind it:

```nix
{ lib, ... }:
{
  lab.name = lib.mkDefault "minimal";
  lab.dns.zone = lib.mkDefault "minimal.test";

  lab.clusters.app = { lab, ... }: {
    cluster.name = "app";
    cluster.kubernetes = {
      distribution = "k3s";
      controlPlanes = 1;
      workers = 0;
    };

    floes.gateway.enable = true;

    floes.custom.enable = true;
    floes.custom.apps.podinfo = {
      namespace = "podinfo";
      gateway = {
        enable = true;
        domain = "podinfo.${lab.dns.zone}";
        serviceName = "podinfo";
        servicePort = 80;
      };
      resources = { /* Deployment, Service */ };
    };
  };
}
```

Run it with `cata --flake .#minimal.local lab up`. The source is
[`examples/labs/minimal`](https://github.com/onepunchtech/catallaxy/tree/master/examples/labs/minimal).

## Lab

One `mkLab` evaluation, configured under `lab.*`. It holds the clusters, the
host-side services they depend on (DNS resolver, image registry, TLS proxy),
the encrypted secrets, and the ordered plan that builds all of it.

A lab is not only cluster state. `lab up` creates containers on your machine
too, which is why `lab plan` has host steps in it.

## Cluster

One Kubernetes cluster, at `lab.clusters.<name>`. It owns what the cluster
_is_ and which capabilities run on it.

### The scope rule

This catches everyone once, so it is worth thirty seconds now.

**Inside a cluster block, `config` means the cluster, not the lab.**

A cluster's configuration has no `lab` attribute, so `config.lab.dns.zone`
fails with `The option 'lab' does not exist`. Lab-level values arrive as a
module argument named `lab`:

```nix
lab.clusters.app = { lab, config, ... }: {
  floes.my-app.domain = "app.${lab.dns.zone}";   # not config.lab.dns.zone
};
```

That argument also carries `lab.clusters`, so one cluster can read another's
computed values. Nix is lazy and each cluster's exports depend only on its
own configuration, so this is not circular:

```nix
issuerUrl = lab.clusters.core.floes.my-idp.exports.externalUrl;
```

Reading across clusters gives you the right _address_ for something
elsewhere. It moves no data. A Secret two clusters both need is authored
once in a store and projected into each of them. One that only the running
lab can produce is published by the cluster that mints it and subscribed to
by the others; see [Secrets](../using/secrets.md#sharing-between-clusters).

## Floe

The unit of capability, and the one worth understanding properly:
[Floes](./floes.md).

## Bundle

A group of Kubernetes resources installed as a unit, written to
`bundles.<name>`. Bundles are the nodes of the install graph, which is why
one floe usually emits several. A certificate manager's CRDs, its operator
and its issuers cannot install at the same moment.

Bundles say what they need and what they offer; the order is derived from
that, never assigned. See [How It Works](./how-it-works.md).
