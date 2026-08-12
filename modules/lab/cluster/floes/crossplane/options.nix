{
  lib,
  config,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkDefault types;
  cfg = config.floes.crossplane;

  secretRefType = types.submodule {
    options = {
      name = mkOption { type = types.str; };
      namespace = mkOption {
        type = types.str;
        default = "crossplane-system";
      };
      key = mkOption {
        type = types.str;
        default = "credentials";
      };
    };
  };
in
{
  config.floes.crossplane.namespace = mkDefault "crossplane-system";

  options.floes.crossplane = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.crossplane.chart;
    };

    providers = mkOption {
      type = types.listOf (
        types.enum [
          "digitalocean"
          "cloudflare"
          "kubernetes"
          "helm"
        ]
      );
      default = [ ];
    };

    providerVersions = {
      digitalocean = mkOption {
        type = types.str;
        default = "0.3.2";
      };
      cloudflare = mkOption {
        type = types.str;
        default = "0.2.5";
      };
      kubernetes = mkOption {
        type = types.str;
        default = "1.2.1";
      };
      helm = mkOption {
        type = types.str;
        default = "1.2.0";
      };
    };

    digitalocean = {
      enable = mkOption {
        type = types.bool;
        default = builtins.elem "digitalocean" cfg.providers;
      };

      apiToken = mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      credentialSecretRef = mkOption {
        type = types.nullOr secretRefType;
        default = {
          name = "do-credentials";
          namespace = cfg.namespace;
          key = "credentials";
        };
      };

      droplets = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              region = mkOption {
                type = types.str;
                default = "nyc1";
              };
              size = mkOption {
                type = types.str;
                default = "s-2vcpu-4gb";
              };
              image = mkOption {
                type = types.str;
                default = "ubuntu-24-04-x64";
              };
              sshKeys = mkOption {
                type = types.listOf types.str;
                default = [ ];
              };
              userData = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
              vpcUuid = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
            };
          }
        );
        default = { };
      };

      loadBalancers = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              region = mkOption {
                type = types.str;
                default = "nyc1";
              };
              dropletTag = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
              forwardingRules = mkOption {
                type = types.listOf types.attrs;
                default = [
                  {
                    entryPort = 80;
                    entryProtocol = "http";
                    targetPort = 80;
                    targetProtocol = "http";
                  }
                ];
              };
            };
          }
        );
        default = { };
      };

      kubernetesClusters = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              region = mkOption {
                type = types.str;
                default = "nyc1";
              };
              version = mkOption {
                type = types.str;
                default = "1.36.0-do.0";
              };
              ha = mkOption {
                type = types.bool;
                default = false;
              };
              autoUpgrade = mkOption {
                type = types.bool;
                default = false;
              };
              surgeUpgrade = mkOption {
                type = types.bool;
                default = true;
              };
              clusterSubnet = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
              serviceSubnet = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
              nodePool = {
                name = mkOption {
                  type = types.str;
                  default = "default";
                };
                size = mkOption {
                  type = types.str;
                  default = "s-2vcpu-4gb";
                };
                nodeCount = mkOption {
                  type = types.int;
                  default = 2;
                };
                autoScale = mkOption {
                  type = types.bool;
                  default = false;
                };
                minNodes = mkOption {
                  type = types.nullOr types.int;
                  default = null;
                };
                maxNodes = mkOption {
                  type = types.nullOr types.int;
                  default = null;
                };
              };
            };
          }
        );
        default = { };
      };
    };

    cloudflare = {
      enable = mkOption {
        type = types.bool;
        default = builtins.elem "cloudflare" cfg.providers;
      };

      apiToken = mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      credentialSecretRef = mkOption {
        type = types.nullOr secretRefType;
        default = {
          name = "cf-credentials";
          namespace = cfg.namespace;
          key = "credentials";
        };
      };

      zones = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              domain = mkOption { type = types.str; };
              plan = mkOption {
                type = types.str;
                default = "free";
              };
              accountId = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
            };
          }
        );
        default = { };
      };

      records = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              zoneRef = mkOption { type = types.str; };
              name = mkOption { type = types.str; };
              type = mkOption {
                type = types.enum [
                  "A"
                  "AAAA"
                  "CNAME"
                  "MX"
                  "TXT"
                  "SRV"
                  "NS"
                ];
                default = "A";
              };
              value = mkOption { type = types.str; };
              proxied = mkOption {
                type = types.bool;
                default = false;
              };
              ttl = mkOption {
                type = types.int;
                default = 300;
              };
            };
          }
        );
        default = { };
      };

      tunnels = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              accountId = mkOption { type = types.str; };
              name = mkOption { type = types.str; };
              secret = mkOption { type = types.str; };
            };
          }
        );
        default = { };
      };
    };

  };
}
