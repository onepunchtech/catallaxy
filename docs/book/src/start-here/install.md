# Install

Two things on your machine. Everything else comes from the flake.

## Nix, with flakes

The
[Determinate Systems installer](https://github.com/DeterminateSystems/nix-installer)
enables flakes by default:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

If you already have Nix, make sure `~/.config/nix/nix.conf` contains:

```
experimental-features = nix-command flakes
```

## Docker

Local clusters run as [k3d](https://k3d.io/) containers, so a running Docker
daemon is required:

```bash
docker info
```

On macOS, [Colima](https://github.com/abiosoft/colima) is used to try to
provide a controlled reproducible environment.
