{ config, lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    ;
  cfg = config.lab.bgpRouter;

  # FRR daemons file — enable zebra (routing) and bgpd
  daemonsFile = ''
    zebra=yes
    bgpd=yes
    ospfd=no
    ospf6d=no
    ripd=no
    ripngd=no
    isisd=no
    pimd=no
    ldpd=no
    nhrpd=no
    eigrpd=no
    babeld=no
    sharpd=no
    pbrd=no
    bfdd=no
    fabricd=no
    vrrpd=no
    pathd=no
  '';

  # FRR configuration — BGP peering with Cilium nodes
  frrConf = ''
    frr version 10
    frr defaults traditional
    hostname catallaxy-router
    log stdout informational

    router bgp ${toString cfg.asn}
      no bgp ebgp-requires-policy
      neighbor cilium peer-group
      neighbor cilium remote-as ${toString cfg.peerASN}
      bgp listen range ${config.lab.network.dockerSubnet} peer-group cilium

      address-family ipv4 unicast
        redistribute connected
        neighbor cilium activate
      exit-address-family
  '';
in
{
  options.lab.bgpRouter = {
    enable = mkEnableOption "Lab BGP router (FRRouting) for LoadBalancer IP advertisement";

    asn = mkOption {
      type = types.int;
      default = 65000;
      description = "BGP Autonomous System Number for the router";
    };

    peerASN = mkOption {
      type = types.int;
      default = 65001;
      description = "BGP ASN for Cilium nodes (peers)";
    };

    lbPool = mkOption {
      type = types.str;
      default = "172.19.200.0/24";
      description = "IP pool CIDR for LoadBalancer service allocation";
    };

    peerAddress = mkOption {
      type = types.str;
      default = "172.19.0.1";
      description = "IP address where the BGP router is reachable by Cilium nodes (Docker network gateway)";
    };

    image = mkOption {
      type = types.str;
      default = "frrouting/frr:latest";
      description = "FRRouting container image";
    };

    containerName = mkOption {
      type = types.str;
      default = "catallaxy-router";
      description = "Docker container name for the BGP router";
    };

    out = {
      service = mkOption {
        type = types.attrs;
        readOnly = true;
        description = "Computed container service definition for the BGP router";
      };
    };
  };

  config.lab.bgpRouter.out = mkIf cfg.enable {
    service = {
      description = "FRRouting BGP router (LB advertisement)";
      container = cfg.containerName;
      image = cfg.image;
      ports = [ ];
      volumes = {
        "/etc/frr/daemons" = {
          content = daemonsFile;
        };
        "/etc/frr/frr.conf" = {
          content = frrConf;
        };
      };
      # Host network so FRR can install routes in the host routing table
      networkMode = "host";
      capAdd = [
        "NET_ADMIN"
        "SYS_ADMIN"
      ];
    };
  };
}
