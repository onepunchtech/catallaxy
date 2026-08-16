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
      name = mkOption {
        type = types.str;
        description = "Name of the Secret holding the credential.";
      };
      namespace = mkOption {
        type = types.str;
        default = "crossplane-system";
        description = "Namespace it lives in.";
      };
      key = mkOption {
        type = types.str;
        default = "credentials";
        description = "Key within it.";
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
      description = "Helm chart to install. Defaults to the chart catallaxy pins.";
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
      description = "Crossplane providers to install. Each adds the custom resources for one cloud.";
    };

    providerVersions = {
      digitalocean = mkOption {
        type = types.str;
        default = "0.3.2";
        description = "Version of provider-digitalocean to install.";
      };
      cloudflare = mkOption {
        type = types.str;
        default = "0.2.5";
        description = "Version of provider-cloudflare.";
      };
      kubernetes = mkOption {
        type = types.str;
        default = "1.2.1";
        description = "Version of provider-kubernetes.";
      };
      helm = mkOption {
        type = types.str;
        default = "1.2.0";
        description = "Version of provider-helm.";
      };
    };

    digitalocean = {
      enable = mkOption {
        type = types.bool;
        default = builtins.elem "digitalocean" cfg.providers;
        description = "Configure the DigitalOcean provider. Defaults to on when it appears in `providers`.";
      };

      apiToken = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "API token, inline. Prefer `credentialSecretRef`, since anything written here lands in the rendered manifests.";
      };

      credentialSecretRef = mkOption {
        type = types.nullOr secretRefType;
        default = {
          name = "do-credentials";
          namespace = cfg.namespace;
          key = "credentials";
        };
        description = "Secret holding the API token.";
      };

      droplets = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              region = mkOption {
                type = types.str;
                default = "nyc1";
                description = "DigitalOcean region slug.";
              };
              size = mkOption {
                type = types.str;
                default = "s-2vcpu-4gb";
                description = "Droplet size slug.";
              };
              image = mkOption {
                type = types.str;
                default = "ubuntu-24-04-x64";
                description = "Image slug to boot from.";
              };
              sshKeys = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Names of SSH keys already in the account to install.";
              };
              userData = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "cloud-init user data.";
              };
              vpcUuid = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "VPC to attach to. Null uses the region default.";
              };
            };
          }
        );
        default = { };
        description = "Droplets to declare. Crossplane creates and reconciles each.";
      };

      loadBalancers = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              region = mkOption {
                type = types.str;
                default = "nyc1";
                description = "Region the load balancer lives in.";
              };
              dropletTag = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Tag selecting which droplets it forwards to.";
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
                description = "Port forwarding rules, entry and exit protocol and port.";
              };
            };
          }
        );
        default = { };
        description = "Load balancers to declare.";
      };

      kubernetesClusters = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              region = mkOption {
                type = types.str;
                default = "nyc1";
                description = "Region the cluster runs in.";
              };
              version = mkOption {
                type = types.str;
                default = "1.36.0-do.0";
                description = "DigitalOcean version slug. A slug that is no longer offered fails the preflight rather than the apply.";
              };
              ha = mkOption {
                type = types.bool;
                default = false;
                description = "Run a highly available control plane. Costs more and is what a production cluster wants.";
              };
              autoUpgrade = mkOption {
                type = types.bool;
                default = false;
                description = "Let DigitalOcean upgrade the patch version.";
              };
              surgeUpgrade = mkOption {
                type = types.bool;
                default = true;
                description = "Add a new node before removing the old one during an upgrade.";
              };
              clusterSubnet = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Pod CIDR. Null takes the provider default.";
              };
              serviceSubnet = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Service CIDR. Null takes the provider default.";
              };
              nodePool = {
                name = mkOption {
                  type = types.str;
                  default = "default";
                  description = "Name of the default node pool.";
                };
                size = mkOption {
                  type = types.str;
                  default = "s-2vcpu-4gb";
                  description = "Size slug for its nodes.";
                };
                nodeCount = mkOption {
                  type = types.int;
                  default = 2;
                  description = "How many nodes it holds when autoscaling is off.";
                };
                autoScale = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Let the pool scale itself between the bounds below.";
                };
                minNodes = mkOption {
                  type = types.nullOr types.int;
                  default = null;
                  description = "Fewest nodes when autoscaling. Null leaves it unset.";
                };
                maxNodes = mkOption {
                  type = types.nullOr types.int;
                  default = null;
                  description = "Most nodes when autoscaling.";
                };
              };
            };
          }
        );
        default = { };
        description = "Managed Kubernetes clusters to declare. A cluster naming itself here is what makes a lab self-provisioning.";
      };
    };

    cloudflare = {
      enable = mkOption {
        type = types.bool;
        default = builtins.elem "cloudflare" cfg.providers;
        description = "Configure the Cloudflare provider. Defaults to on when it appears in `providers`.";
      };

      apiToken = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "API token, inline. Prefer `credentialSecretRef`.";
      };

      credentialSecretRef = mkOption {
        type = types.nullOr secretRefType;
        default = {
          name = "cf-credentials";
          namespace = cfg.namespace;
          key = "credentials";
        };
        description = "Secret holding the API token.";
      };

      zones = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              domain = mkOption {
                type = types.str;
                description = "Domain name of the zone.";
              };
              plan = mkOption {
                type = types.str;
                default = "free";
                description = "Cloudflare plan for it.";
              };
              accountId = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Account the zone belongs to. Null uses the token's account.";
              };
            };
          }
        );
        default = { };
        description = "DNS zones to declare.";
      };

      records = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              zoneRef = mkOption {
                type = types.str;
                description = "Zone this record belongs to.";
              };
              name = mkOption {
                type = types.str;
                description = "Record name, relative to the zone.";
              };
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
                description = "Record type.";
              };
              value = mkOption {
                type = types.str;
                description = "Record value: an address for A and AAAA, a hostname for CNAME.";
              };
              proxied = mkOption {
                type = types.bool;
                default = false;
                description = "Route the record through Cloudflare's proxy rather than resolving straight to the value.";
              };
              ttl = mkOption {
                type = types.int;
                default = 300;
                description = "Time to live, in seconds. Ignored while proxied.";
              };
            };
          }
        );
        default = { };
        description = "DNS records to declare.";
      };

      tunnels = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              accountId = mkOption {
                type = types.str;
                description = "Account the tunnel belongs to.";
              };
              name = mkOption {
                type = types.str;
                description = "Name of the tunnel.";
              };
              secret = mkOption {
                type = types.str;
                description = "Tunnel secret. Prefer supplying this from a secret store rather than inline.";
              };
            };
          }
        );
        default = { };
        description = "Cloudflare tunnels to declare, for reaching a service with no public address.";
      };
    };

  };
}
