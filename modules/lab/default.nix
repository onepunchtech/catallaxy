{ lib, ... }:

{
  imports = [
    ./types.nix
    ./dns.nix
    ./network.nix
    ./registry.nix
    ./proxy.nix
    ./ops.nix
    ./secrets.nix
    ./images.nix
    ./lint.nix
    ./planner.nix
    ./bgp-router.nix
    ./out.nix
  ];
}
