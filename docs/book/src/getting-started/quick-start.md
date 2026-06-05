# Quick Start

This guide walks you through standing up the example homelab — a multi-cluster local environment with networking, identity, GitOps, observability, and more — all running in Docker via k3d.

## Clone the repository

```bash
git clone https://github.com/onepunchtech/catallaxy.git
cd catallaxy
```

## Enter the dev shell

```bash
nix develop
```

This drops you into a shell with every tool catallaxy needs: `cata`, `kubectl`, `helm`, `kapp`, `k3d`, and others. You do not need any of these installed on your system.

## Bring the lab up

```bash
cata --flake ./examples/labs#homelab.local lab up
```

This is the main command. It evaluates the lab configuration defined in `examples/labs/flake.nix` for the lab named `homelab`, provisions k3d clusters, and applies all rendered manifests in phase order. Phases run from CRDs and namespaces through networking, operators, infrastructure, GitOps, databases, and applications.

The `--flake ./examples/labs#homelab` argument points to the flake directory and selects the `homelab` lab by name. This pattern is used for all `cata` commands.

## Set up DNS

```bash
cata --flake ./examples/labs#homelab.local lab dns --setup
```

Configures your local DNS resolution so that `*.homelab.test` domains route to the lab's ingress. This lets you access services by name in your browser without editing `/etc/hosts`.

## Trust the lab CA

```bash
cata --flake ./examples/labs#homelab.local lab trust --setup
```

Adds the lab's certificate authority to your system's trust store. The lab generates its own CA via cert-manager, and this command ensures your browser and CLI tools trust the TLS certificates it issues. Without this, you will see certificate warnings on every service.

## Verify the lab is running

```bash
cata --flake ./examples/labs#homelab.local lab status
```

Shows the state of each cluster and its components. Once everything is healthy, the lab's services are accessible at their configured domains:

- **ArgoCD** — [https://argocd.homelab.test](https://argocd.homelab.test)
- **Grafana** — [https://grafana.homelab.test](https://grafana.homelab.test)

Additional services depend on which components are enabled in the lab configuration.

## Tear it down

```bash
cata --flake ./examples/labs#homelab.local lab down      # stop clusters (preserves state)
cata --flake ./examples/labs#homelab.local lab destroy    # delete everything
```

`lab down` stops clusters but preserves state — run `lab up` to restart. `lab destroy` deletes clusters, services, and network completely.

## Next steps

The example lab is a useful reference, but the real power is defining your own. See [Creating Your Own Lab](./consumer-flake.md) to set up a standalone flake that imports catallaxy as an input.
