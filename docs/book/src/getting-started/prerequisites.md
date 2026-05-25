# Prerequisites

Catallaxy requires two things on your system. Everything else is provided by the flake.

## Nix with flakes enabled

Install Nix using the [Determinate Systems installer](https://github.com/DeterminateSystems/nix-installer), which enables flakes by default:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -o install-self
```

If you already have Nix installed, ensure flakes are enabled. Add the following to `~/.config/nix/nix.conf` if it is not already present:

```
experimental-features = nix-command flakes
```

## Docker

A running Docker daemon is required for local development. Catallaxy uses [k3d](https://k3d.io/) to run K3s clusters inside Docker containers.

Install Docker through your system's package manager or from [docker.com](https://docs.docker.com/get-docker/). Verify it is running:

```bash
docker info
```

## That is everything

You do not need to install kubectl, Helm, kapp, k3d, talosctl, or any other Kubernetes tooling. The catallaxy flake provides all of these through its dev shell. When you run `nix develop`, every tool the CLI needs is available on your `PATH`.

This is intentional. Pinning tool versions in the flake eliminates "works on my machine" issues and ensures the CLI, the manifest renderer, and the cluster tooling all agree on versions.
