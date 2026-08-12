{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
in
{
  options.floes.cert-manager = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.cert-manager.chart;
      description = "cert-manager Helm chart derivation (default: cataCharts.cert-manager)";
    };

    selfSignedCA = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Create a self-signed CA ClusterIssuer";
      };

      issuerName = mkOption {
        type = types.str;
        default = "lab-ca";
        description = "Name of the ClusterIssuer backed by the self-signed CA";
      };

      intermediate = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            When true, emit a second ClusterIssuer backed by an
            intermediate CA Secret (populated by an operator via
            `cata secrets init-intermediate`: the root signs the
            intermediate offline; only the intermediate key is ever
            projected into a running cluster). The
            intermediate becomes the default issuer (`defaultIssuerRef`
            resolves to it), so Certificate CRs across the lab
            automatically pick it up. The root ClusterIssuer stays
            emitted for edge cases (e.g., bootstrap signing during
            initial deploy) but should not be referenced directly.
          '';
        };

        issuerName = mkOption {
          type = types.str;
          default = "lab-ca-intermediate";
          description = "Name of the intermediate ClusterIssuer";
        };

        secretName = mkOption {
          type = types.str;
          default = "lab-ca-intermediate-ca-secret";
          description = ''
            k8s Secret name (in cert-manager namespace) that holds
            the intermediate CA's tls.crt + tls.key. Populated by a
            SOPS projection (see `lab.secrets.projections`) at
            deploy time. The intermediate ClusterIssuer references
            this Secret via spec.ca.secretName.
          '';
        };
      };
    };

    acme = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Create an ACME ClusterIssuer for Let's Encrypt";
      };

      email = mkOption {
        type = types.str;
        default = "";
        description = "Email for ACME registration";
      };

      server = mkOption {
        type = types.str;
        default = "https://acme-v02.api.letsencrypt.org/directory";
        description = "ACME server URL (use staging for testing)";
      };

      issuerName = mkOption {
        type = types.str;
        default = "letsencrypt";
        description = "Name of the ACME ClusterIssuer";
      };

      solvers = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = "Raw ACME solver config (overrides dns01 provider if set)";
      };

      dns01 = {
        provider = mkOption {
          type = types.enum [
            "none"
            "cloudflare"
            "route53"
          ];
          default = "none";
          description = "Public DNS provider for ACME DNS01 challenges";
        };

        cloudflare = {
          apiTokenSecretName = mkOption {
            type = types.str;
            default = "cloudflare-api-token";
            description = "Name of Secret containing the Cloudflare API token (key: api-token)";
          };

          apiToken = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Cloudflare API token (if set, auto-creates the Secret)";
          };
        };

        route53 = {
          region = mkOption {
            type = types.str;
            default = "us-east-1";
            description = "AWS region for Route53";
          };

          hostedZoneID = mkOption {
            type = types.str;
            default = "";
            description = "Route53 hosted zone ID";
          };

          accessKeyID = mkOption {
            type = types.str;
            default = "";
            description = "AWS access key ID (for explicit credentials)";
          };

          secretAccessKeySecretName = mkOption {
            type = types.str;
            default = "route53-credentials";
            description = "Name of Secret containing AWS secret access key (key: secret-access-key)";
          };

          secretAccessKey = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "AWS secret access key (if set, auto-creates the Secret)";
          };
        };
      };
    };
  };
}
