{ config, lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    ;
  cfg = config.lab.egress;

  tinyproxyConfig = ''
    User nobody
    Group nobody
    Port 8888
    Timeout 600
    DefaultErrorFile "/usr/share/tinyproxy/default.html"
    StatFile "/usr/share/tinyproxy/stats.html"
    LogLevel Warning
    MaxClients 100
    DisableViaHeader Yes

    # Published on loopback only, so the only reachable clients are on this
    # machine and the address filter would refuse the docker bridge address
    # every request actually arrives from.
    Allow 0.0.0.0/0

    # The lab's ingress answers 80 and 443 on this lab's bridge gateway, which
    # is what the zone's wildcard resolves to. Nothing else is worth tunnelling
    # to, and CONNECT to an arbitrary port is how an open proxy behaves.
    ConnectPort 443
    ConnectPort 80
  '';
in
{
  options.lab.egress = {
    enable = mkEnableOption "A proxy inside the lab network, so host tools can reach lab hostnames" // {
      default = config.lab.proxy.enable;
      defaultText = lib.literalExpression "config.lab.proxy.enable";
    };

    port = mkOption {
      type = types.port;
      default = 3128;
      description = ''
        Host port the proxy listens on, bound to loopback.

        Joins the other host ports in `lab-host-ports`, so two labs cannot
        claim the same one.
      '';
    };

    image = mkOption {
      type = types.str;
      default = "ghcr.io/querateam/docker-tinyproxy:latest";
      description = ''
        Forward proxy image. Tinyproxy has no official image; this one is
        small, takes a mounted config, and runs as a non-root user.
      '';
    };

    containerName = mkOption {
      type = types.str;
      default = "catallaxy-${config.lab.name}-egress";
      description = "Docker container name for the proxy.";
    };

    out = {
      service = mkOption {
        type = types.attrs;
        readOnly = true;
        description = "Computed container service definition for the lab's egress proxy.";
      };
    };
  };

  config.lab.egress.out = mkIf cfg.enable {
    service = {
      description = "Forward proxy inside the lab network (${config.lab.dns.zone})";
      container = cfg.containerName;
      image = cfg.image;
      ports = [ "127.0.0.1:${toString cfg.port}:8888" ];
      volumes = {
        "/etc/tinyproxy/tinyproxy.conf" = {
          content = tinyproxyConfig;
        };
      };
      networks = [ config.lab.name ];
      dnsContainers = [ config.lab.dns.containerName ];
    };
  };
}
