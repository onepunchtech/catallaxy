{ lib, ... }:

{
  imports = [
    ./docker.nix
    ./k3d.nix
    ./crossplane.nix
  ];
}
