{
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    optionalAttrs
    mapAttrsToList
    ;
  cfg = config.components.external-dns;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # RFC2136 provider args (passed via extraArgs)
  # Note: Boolean flags should be null to indicate presence-only (no =value)
  rfc2136Args =
    optionalAttrs (cfg.provider == "rfc2136") {
      "rfc2136-host" = cfg.rfc2136.host;
      "rfc2136-port" = toString cfg.rfc2136.port;
      "rfc2136-zone" = lib.removeSuffix "." cfg.rfc2136.zone;
      "rfc2136-tsig-keyname" = cfg.rfc2136.tsigKeyname;
      "rfc2136-tsig-secret" = cfg.rfc2136.tsigSecret;
      "rfc2136-tsig-secret-alg" = cfg.rfc2136.tsigSecretAlg;
    }
    // optionalAttrs (cfg.provider == "rfc2136" && cfg.rfc2136.tsigAxfr) {
      "rfc2136-tsig-axfr" = null; # Boolean flag - presence only, no value
    };

  # Default targets arg
  defaultTargetArgs = optionalAttrs (cfg.defaultTargets != [ ]) {
    "default-targets" = lib.concatStringsSep "," cfg.defaultTargets;
  };

  # Merge user extraArgs with provider-specific args
  allExtraArgs = rfc2136Args // defaultTargetArgs // cfg.extraArgs;

  # Convert args to CLI format, handling boolean flags (null value = no =value)
  formatExtraArgs = args: mapAttrsToList (k: v: if v == null then "--${k}" else "--${k}=${v}") args;
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.external-dns = {
    enable = mkEnableOption "ExternalDNS";

    phase = mkOption {
      type = types.str;
      default = "operators";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "1.15.0";
      description = "ExternalDNS Helm chart version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.external-dns.chart;
      description = "ExternalDNS Helm chart derivation (default: cataCharts.external-dns)";
    };

    namespace = mkOption {
      type = types.str;
      default = "external-dns";
      description = "Namespace for ExternalDNS";
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

    # RFC2136 (dynamic DNS update) provider settings
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

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for ExternalDNS";
    };
  };

  # =========================================================================
  # PART 2: Computed refs
  # =========================================================================

  # =========================================================================
  # PART 3: Phase writer
  # =========================================================================

  config = lib.mkMerge [
    {
      components.external-dns.ref = {
        namespace = cfg.namespace;
        serviceName = "external-dns";
      };
    }
    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.external-dns = {
        # Main ExternalDNS helm chart
        helmCharts.external-dns = {
          chart = chartRef;
          releaseName = "external-dns";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            provider.name = cfg.provider;
            sources = cfg.sources;
            policy = cfg.policy;
            logLevel = cfg.logLevel;
            interval = cfg.interval;
            triggerLoopOnEvent = cfg.triggerLoopOnEvent;
            txtOwnerId = if cfg.txtOwnerId != null then cfg.txtOwnerId else config.cluster.name;
            txtPrefix = cfg.txtPrefix;
          }
          // optionalAttrs (cfg.domainFilters != [ ]) {
            domainFilters = cfg.domainFilters;
          }
          // optionalAttrs (cfg.excludeDomains != [ ]) {
            excludeDomains = cfg.excludeDomains;
          }
          // optionalAttrs (allExtraArgs != { }) {
            extraArgs = formatExtraArgs allExtraArgs;
          }
          // optionalAttrs (cfg.env != [ ]) {
            env = cfg.env;
          }
          // optionalAttrs (cfg.serviceAccount.annotations != { }) {
            serviceAccount.annotations = cfg.serviceAccount.annotations;
          };
        };

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}
