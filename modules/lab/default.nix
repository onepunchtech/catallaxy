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
    ./bgp-router.nix
    ./out.nix
  ];
}
