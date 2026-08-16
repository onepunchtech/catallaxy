# catallaxy

**Declarative Kubernetes platform management.** A lab is a typed, ordered
graph of modules: the clusters, the capabilities running on them, and the
plan that builds all of it, expressed in the Nix module system and executed
by a Rust CLI.

The name is Hayek's, for the order that emerges when independent actors
follow their own rules rather than a central plan. It is the same claim
functional programmers make about **local reasoning**: if every part can be
understood on its own, composing them is safe and the global structure need
not be authored by hand.

So no part here knows the deployment plan. Each declares its own options,
the manifests it emits, and the conditions it needs, and the install order
is _derived_ from those declarations rather than typed as a sequence of
numbers.

**[Documentation](https://onepunchtech.github.io/catallaxy)**

---

The unit is a **floe**: a self-contained module with an option surface, the
manifests it emits, and a typed interface other floes can read.

```nix
floes.cert-manager.enable = true;

floes.forgejo = {
  enable = true;
  domain = "git.${lab.dns.zone}";
  tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
};
```

That last line is the argument: one component reading another's computed
output, checked at evaluation. No string templating, no values file
duplicated in two places, no sync-wave number chosen by looking at the
neighbouring numbers.

## Quick start

```bash
nix develop

cata --flake ./examples/labs#minimal.local lab plan     # read it first
cata --flake ./examples/labs#minimal.local lab up
cata --flake ./examples/labs#minimal.local lab topology --format table

curl http://podinfo.minimal.test

cata --flake ./examples/labs#minimal.local lab destroy
```

`minimal.local` is one k3d cluster with a gateway and one app (podinfo),
served over plain HTTP so it comes up on any machine. `homelab.local` adds
identity, observability and GitOps over TLS. `mesh.local` is reachable only
from a WireGuard mesh, and is where the lab CA and host trust are
demonstrated.

Walkthrough:
[Run the Example Lab](https://onepunchtech.github.io/catallaxy/start-here/first-lab.html).

## What it does

- **A plan you read before it runs.** `cata lab plan` prints the ordered
  step list `cata lab up` will execute, provisioning, host DNS and TLS,
  secret projections, your own hooks.
- **Install order that is derived.** Bundles declare what they need and what
  they offer. Waves fall out. Nothing carries a number.
- **Failures that happen early.** Types, assertions, graph contracts, lint
  over rendered manifests, snapshot tests over the plan.
- **27 built-in floes**. CNI, gateway, PKI, identity, observability,
  databases, registries, GitOps, backup, and yours built the same way, in
  your own repository.
- **Bootstrap and pivot.** Cloud clusters provisioned by Crossplane from a
  throwaway local one, which is then destroyed.
- **kapp, ArgoCD or Fleet**, with the handoff between imperative bootstrap
  and GitOps steady state modelled rather than scripted.

## Your own lab

```bash
nix flake init -t github:onepunchtech/catallaxy#consumer
```

You never fork catallaxy, your flake takes it as an input. See
[Build Your Own Lab](https://onepunchtech.github.io/catallaxy/start-here/your-own-lab.html).

## Development

```bash
nix develop                       # cata, cata-dev, and every runtime tool
cargo build                       # the CLI
nix flake check                   # everything: tests, lint, snapshots, docs
nix fmt                           # nixfmt, rustfmt, yamlfmt
nix build .#docs                  # the book
```

[Contributing](https://onepunchtech.github.io/catallaxy/contributing.html) ·
[Conventions](https://onepunchtech.github.io/catallaxy/contributing.html#conventions)

## License

[MIT](LICENSE)
