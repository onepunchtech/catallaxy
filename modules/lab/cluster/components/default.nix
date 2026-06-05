{ ... }:

{
  imports = [
    ./backups
    ./cni
    ./custom.nix
    ./databases
    ./filesystems
    ./gateway.nix
    ./idm
    ./observability
    ./pki
    ./provisioning
    ./registries
    ./secrets
    ./security
    ./source-control
    ./vpn
    ./gitops
    ./external-dns.nix
    ./redis-operator.nix
  ];
}
