{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption types;
in
{
  options.floes.external-dns = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.external-dns.chart;
      description = "ExternalDNS Helm chart derivation (default: cataCharts.external-dns)";
    };

    provider = mkOption {
      type = types.str;
      default = "cloudflare";
      description = "DNS provider (cloudflare, route53, google, azure-dns, etc.)";
    };

    sources = mkOption {
      type = types.listOf types.str;
      default = [
        "service"
        "ingress"
        "gateway-httproute"
        "gateway-tlsroute"
      ];
      description = "Kubernetes resource types to watch for DNS records";
    };

    domainFilters = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Domains to manage (empty = all)";
    };

    excludeDomains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Domains to exclude from management";
    };

    policy = mkOption {
      type = types.enum [
        "sync"
        "upsert-only"
        "create-only"
      ];
      default = "sync";
      description = "Record management policy (sync creates+updates+deletes)";
    };

    txtOwnerId = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "TXT record ownership ID (defaults to cluster name)";
    };

    txtPrefix = mkOption {
      type = types.str;
      default = "externaldns-";
      description = "Prefix for TXT ownership records";
    };

    interval = mkOption {
      type = types.str;
      default = "1m";
      description = "Sync interval";
    };

    triggerLoopOnEvent = mkOption {
      type = types.bool;
      default = true;
      description = "React to resource events immediately rather than waiting for interval";
    };

    logLevel = mkOption {
      type = types.enum [
        "debug"
        "info"
        "warning"
        "error"
      ];
      default = "info";
      description = "Log verbosity level";
    };

    defaultTargets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Override the target IP/hostname for all DNS records (e.g. [\"127.0.0.1\"] for local dev)";
    };

    excludeInternalGateway = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When true, ExternalDNS skips publishing HTTPRoutes attached to
        Gateways labeled `catallaxy.io/network-tier=internal`. Off-mesh
        clients (including peer-cluster k3d nodes) see NXDOMAIN for
        those hostnames; cross-cluster image pulls break unless the
        peer cluster has a netbird peer.

        Default `false`: both tiers publish, mesh override happens
        in cluster CoreDNS, authentication enforces the boundary.
      '';
    };

    extraArgs = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Provider-specific extra arguments (e.g. { cloudflare-proxied = \"true\"; })";
    };

    env = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      description = "Extra environment variables (e.g. API tokens from secrets)";
    };

    rfc2136 = {
      host = mkOption {
        type = types.str;
        default = "";
        description = "DNS server host for RFC2136 updates";
      };

      port = mkOption {
        type = types.port;
        default = 53;
        description = "DNS server port";
      };

      zone = mkOption {
        type = types.str;
        default = "";
        description = "DNS zone to manage (e.g. 'lab.test.')";
      };

      tsigKeyname = mkOption {
        type = types.str;
        default = "externaldns-key";
        description = "TSIG key name for authenticating DNS updates";
      };

      tsigSecret = mkOption {
        type = types.str;
        default = "";
        description = "Base64-encoded TSIG secret";
      };

      tsigSecretAlg = mkOption {
        type = types.enum [
          "hmac-sha256"
          "hmac-sha512"
          "hmac-sha1"
        ];
        default = "hmac-sha256";
        description = "TSIG secret algorithm";
      };

      tsigAxfr = mkOption {
        type = types.bool;
        default = false;
        description = "Enable AXFR (zone transfer) using TSIG. Not needed for basic operation.";
      };
    };

    serviceAccount = {
      annotations = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "ServiceAccount annotations (for AWS IRSA, GCP Workload Identity, etc.)";
      };
    };
  };
}
