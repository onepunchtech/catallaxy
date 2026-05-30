{ lib, ... }:

{
  imports = [
    ./types.nix
    ./dns.nix
    ./network.nix
    ./registry.nix
    ./ingress.nix
    ./ops.nix
    ./secrets.nix
    ./planner.nix
    ./bgp-router.nix
    ./out.nix
  ];
}
