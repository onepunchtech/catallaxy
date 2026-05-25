{ config, lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    ;
  cfg = config.lab.dns;

  knotConf = ''
    server:
      listen: 0.0.0.0@53

    log:
      - target: stdout
        any: info

    key:
      - id: ${cfg.tsigKeyname}
        algorithm: ${cfg.tsigSecretAlg}
        secret: ${cfg.tsigSecret}

    acl:
      - id: update-acl
        key: ${cfg.tsigKeyname}
        action: [update, transfer]

    zone:
      - domain: ${cfg.zone}.
        storage: /storage
        file: ${cfg.zone}.zone
        acl: update-acl
  '';

  # Generate seed zone file from options
  zoneFile = ''
    $ORIGIN ${cfg.zone}.
    $TTL 300

    @   IN  SOA ns1.${cfg.zone}. admin.${cfg.zone}. (
            2024010101  ; serial
            3600        ; refresh
            900         ; retry
            604800      ; expire
            300         ; minimum TTL
        )

    @   IN  NS  ns1.${cfg.zone}.
    ns1 IN  A   127.0.0.1
  '';
in
{
  options.lab.dns = {
    enable = mkEnableOption "Lab DNS server (Knot DNS with RFC2136 for ExternalDNS)";

    zone = mkOption {
      type = types.str;
      default = "${config.lab.name}.test";
      description = "DNS zone for the lab (defaults to '<labname>.test')";
    };

    server = mkOption {
      type = types.str;
      default =
        let
          # Docker gateway is first usable IP in the subnet (e.g. 172.19.0.1)
          octets = lib.splitString "." (lib.head (lib.splitString "/" config.lab.network.dockerSubnet));
          nums = map lib.strings.toInt octets;
          firstIP = lib.init nums ++ [ ((lib.last nums) + 1) ];
        in
        lib.concatStringsSep "." (map toString firstIP);
      description = "IP address where the DNS server is reachable from clusters (Docker gateway by default)";
    };

    port = mkOption {
      type = types.port;
      default = cfg.hostPort;
      description = "Port for the DNS server (as seen from clusters, defaults to hostPort)";
    };

    hostPort = mkOption {
      type = types.port;
      default = 5354;
      description = "Host-mapped port for the DNS server (for host access). Avoids 5353 which conflicts with mDNS.";
    };

    tsigKeyname = mkOption {
      type = types.str;
      default = "externaldns-key";
      description = "TSIG key name for RFC2136 dynamic updates";
    };

    tsigSecret = mkOption {
      type = types.str;
      default = "kp4bgnFAVCmajGIqOW7rj0MNwRNZHBqMvYaLTwzPHgI=";
      description = "Base64-encoded TSIG secret (pre-generated for local dev)";
    };

    tsigSecretAlg = mkOption {
      type = types.str;
      default = "hmac-sha256";
      description = "TSIG algorithm";
    };

    image = mkOption {
      type = types.str;
      default = "cznic/knot:latest";
      description = "Knot DNS container image";
    };

    containerName = mkOption {
      type = types.str;
      default = "catallaxy-dns";
      description = "Docker container name for the DNS server";
    };

    out = {
      service = mkOption {
        type = types.attrs;
        readOnly = true;
        description = "Computed container service definition for the lab DNS server";
      };

      dnsInfo = mkOption {
        type = types.attrs;
        readOnly = true;
        description = "DNS server info for host resolver configuration";
      };
    };
  };

  config.lab.dns.out = mkIf cfg.enable {
    service = {
      description = "Knot DNS server (${cfg.zone})";
      container = cfg.containerName;
      image = cfg.image;
      command = [ "knotd" ];
      ports = [
        "${toString cfg.hostPort}:53/tcp"
        "${toString cfg.hostPort}:53/udp"
      ];
      volumes = {
        "/config/knot.conf" = {
          content = knotConf;
        };
        "/storage/${cfg.zone}.zone" = {
          content = zoneFile;
        };
      };
      networks = [ config.lab.name ];
    };

    dnsInfo = {
      host = "127.0.0.1";
      port = cfg.hostPort;
      zone = cfg.zone;
    };
  };
}
