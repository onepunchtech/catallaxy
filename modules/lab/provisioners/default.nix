# lib/provisioners/default.nix
#
# Provisioner modules. Handle cluster creation via different methods.

{ lib, ... }:

{
  imports = [
    ./docker.nix
    ./k3d.nix
    ./crossplane.nix
  ];
}
