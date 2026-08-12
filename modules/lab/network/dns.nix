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

  internalLabel =
    if cfg.internalZone != cfg.zone && lib.hasSuffix ".${cfg.zone}" cfg.internalZone then
      lib.removeSuffix ".${cfg.zone}" cfg.internalZone
    else
      null;

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
    ${lib.optionalString config.lab.proxy.enable ''

      ; Every host-facing endpoint on a local lab arrives through the
      ; ingress, which routes by Host header, so one wildcard answers
      ; for all of them. The target is the docker bridge gateway
      ; because the same zone is served to the host and to pods, and
      ; that address reaches the ingress's published port from both.
      ;
      ; A more specific record always wins, so external-dns keeps
      ; control of anything it publishes. Without this a lab that runs
      ; no DNS controller resolves nothing at all.
      *   IN  A   ${cfg.server}''}
    ${lib.optionalString (internalLabel != null) ''

      ; The internal tier is reached over the mesh, never through the
      ; ingress. This node exists only to be a closer encloser: without
      ; it the wildcard above answers for every name beneath it, handing
      ; back the ingress address for a mesh-only name and turning a
      ; clean NXDOMAIN into a 503 from a gateway that has no such route.
      ${internalLabel}   IN  TXT "internal tier; resolved over the mesh"''}
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

    configureHost = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Point this machine's resolver at the lab's DNS as part of
        `cata lab up`, so `*.<zone>` resolves in your browser and in any
        tool you run by hand.

        Off by default, for the same reason
        `lab.trust.installIntoHostStore` is: it needs `sudo` and it edits
        configuration outside the lab, which is a poor default for a
        command whose whole job is to be reversible. On Linux it writes a
        `systemd-resolved` drop-in and restarts the resolver; on macOS it
        writes `/etc/resolver/<zone>`.

        Leave it off and reach the lab without touching the host:
        `cata lab verify` probes every exposed host by resolving through
        the lab's own DNS, and `curl --resolve <host>:80:127.0.0.1` does
        the same by hand. Turn it on for a lab you live in, or run
        `cata lab dns --setup` once when you want it for this session
        only.

        When it is on, `cata lab destroy` removes what it wrote.
      '';
    };

    internalZone = mkOption {
      type = types.str;
      default = "internal.${cfg.zone}";
      description = ''
        Zone for internal-tier hostnames: the ones reachable only from
        inside the cluster or over the mesh, never through the host
        ingress.

        It must be a strict subdomain of `zone`. Resolvers route by
        domain suffix and prefer the most specific match, so a mesh
        client can be handed `internal.<zone>` while `<zone>` itself
        keeps resolving to the host ingress. Both tiers then answer at
        once, which one flat zone cannot do: netbird pushing `<zone>`
        took every public name on the host with it (mesh.local,
        2026-08-04).

        A name prefix such as `internal-foo.<zone>` cannot substitute
        for this. Resolvers match suffixes, never prefixes.
      '';
    };

    server = mkOption {
      type = types.str;
      default =
        let

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

    coredns = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          When enabled, catallaxy emits the `coredns-custom` ConfigMap
          for each cluster's CoreDNS: a single `<zone>:53` server
          block containing:
            - a `hosts` plugin section with internal-tier hostnames
              (collected from `floes.gateway.internalHostnames`)
              pointing at the cluster's pinned
              `traefik-internal` ClusterIP;
            - `fallthrough` to a `forward` to the lab knot DNS
              (`dns.server:dns.port`) for everything else.

          Consumer labs MUST NOT also declare a `coredns-custom`
          ConfigMap; catallaxy owns this resource when the option is
          on. To extend with extra server blocks, add them via the
          `extraServers` option below.
        '';
      };

      extraServers = mkOption {
        type = types.attrsOf types.lines;
        default = { };
        example = lib.literalExpression ''
          {
            "logs.internal" = '''
              logs.internal:53 {
                forward . 10.0.0.5
              }
            ''';
          }
        '';
        description = ''
          Additional CoreDNS server blocks to splice into the
          `coredns-custom` ConfigMap as extra `*.server` files. Each
          key becomes a separate file; CoreDNS imports them via
          `import /etc/coredns/custom/*.server`.
        '';
      };
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
      tsigKeyname = cfg.tsigKeyname;
      tsigSecret = cfg.tsigSecret;
      tsigSecretAlg = cfg.tsigSecretAlg;
    };
  };
}
