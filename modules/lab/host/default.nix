{ ... }:

{
  imports = [
    ./docker.nix
    ./egress.nix
    ./proxy.nix
    ./registry.nix
  ];
}
