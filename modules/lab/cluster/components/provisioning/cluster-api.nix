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
    mapAttrs'
    nameValuePair
    optionalAttrs
    concatMapAttrs
    listToAttrs
    imap0
    map
    filterAttrs
    elem
    optional
    ;
  cfg = config.components.cluster-api;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # Compute the first usable IP in a CIDR
  cidrFirstIP =
    cidr:
    let
      network = lib.head (lib.splitString "/" cidr);
      octets = map lib.strings.toInt (lib.splitString "." network);
      firstIP = lib.init octets ++ [ ((lib.last octets) + 1) ];
    in
    lib.concatStringsSep "." (map toString firstIP);

  # Worker pool submodule
  workerPoolType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Name of the worker pool";
      };
      replicas = mkOption {
        type = types.int;
        default = 3;
      };
      machineType = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      taints = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              key = mkOption { type = types.str; };
              value = mkOption {
                type = types.str;
                default = "";
              };
              effect = mkOption {
                type = types.enum [
                  "NoSchedule"
                  "PreferNoSchedule"
                  "NoExecute"
                ];
              };
            };
          }
        );
        default = [ ];
      };
    };
  };

  # CAPI-managed cluster submodule
  capiClusterType = types.submodule (
    { config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
        };
        ref = mkOption {
          type = types.attrs;
          readOnly = true;
        };

        infrastructureProvider = mkOption {
          type = types.enum [
            "docker"
            "digitalocean"
            "hetzner"
            "aws"
            "gcp"
            "azure"
            "vsphere"
          ];
        };

        kubernetes = {
          version = mkOption {
            type = types.str;
            default = "v1.31.0";
          };
          controlPlane = {
            replicas = mkOption {
              type = types.int;
              default = 3;
            };
            machineType = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
          };
          workers = mkOption {
            type = types.listOf workerPoolType;
            default = [
              {
                name = "default";
                replicas = 3;
              }
            ];
          };
        };

        talos = {
          enable = mkOption {
            type = types.bool;
            default = true;
          };
          version = mkOption {
            type = types.str;
            default = "v1.8.0";
          };
        };

        network = {
          podCIDR = mkOption {
            type = types.str;
            default = "10.244.0.0/16";
          };
          serviceCIDR = mkOption {
            type = types.str;
            default = "10.96.0.0/12";
          };
        };

        digitalocean = {
          region = mkOption {
            type = types.str;
            default = "nyc1";
          };
          controlPlaneSize = mkOption {
            type = types.str;
            default = "s-2vcpu-4gb";
          };
          workerSize = mkOption {
            type = types.str;
            default = "s-2vcpu-4gb";
          };
          sshKeys = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "SSH key fingerprints or IDs";
          };
          image = mkOption {
            type = types.str;
            default = "ubuntu-24-04-x64";
          };
        };

        hetzner = {
          region = mkOption {
            type = types.str;
            default = "fsn1";
          };
          controlPlaneType = mkOption {
            type = types.str;
            default = "cpx31";
          };
          workerType = mkOption {
            type = types.str;
            default = "cpx31";
          };
          sshKeyName = mkOption {
            type = types.nullOr types.str;
            default = null;
          };
          placementGroup = mkOption {
            type = types.bool;
            default = true;
          };
          network = {
            enabled = mkOption {
              type = types.bool;
              default = true;
            };
            cidr = mkOption {
              type = types.str;
              default = "10.0.0.0/8";
            };
          };
        };

        certSANs = mkOption {
          type = types.listOf types.str;
          default = [ ];
        };
        apiServerExtraArgs = mkOption {
          type = types.attrsOf types.str;
          default = { };
        };
        clientCaCert = mkOption {
          type = types.nullOr types.str;
          default = null;
        };

        registryMirror = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Configure containerd registry mirrors on CAPI cluster nodes";
          };
          endpoint = mkOption {
            type = types.str;
            default = "http://172.17.0.1:5050";
            description = "Registry mirror endpoint (e.g., http://docker-host:port)";
          };
          registries = mkOption {
            type = types.listOf types.str;
            default = [
              "docker.io"
              "ghcr.io"
              "quay.io"
              "registry.k8s.io"
            ];
            description = "Upstream registries to mirror through the cache";
          };
        };

        docker = {
          loadBalancerImage = mkOption {
            type = types.str;
            default = "kindest/haproxy:v20230606-42a2262b";
          };
        };

        aws = {
          region = mkOption {
            type = types.str;
            default = "us-east-1";
          };
          sshKeyName = mkOption {
            type = types.nullOr types.str;
            default = null;
          };
          controlPlaneInstanceType = mkOption {
            type = types.str;
            default = "t3.large";
          };
          workerInstanceType = mkOption {
            type = types.str;
            default = "t3.large";
          };
        };
      };

      config.ref = {
        kubernetesServiceIP = cidrFirstIP config.network.serviceCIDR;
        kubernetesServicePort = "443";
        serviceCIDR = config.network.serviceCIDR;
        podCIDR = config.network.podCIDR;
      };
    }
  );

  # Provider name mappings
  infraProviderVersion =
    provider:
    {
      docker = cfg.providerVersions.core;
      digitalocean = cfg.providerVersions.digitalocean;
      hetzner = cfg.providerVersions.hetzner;
      aws = cfg.providerVersions.aws;
    }
    .${provider} or "";

  bootstrapProviderVersion =
    provider:
    {
      talos = cfg.providerVersions.talosBootstrap;
      kubeadm = cfg.providerVersions.core;
    }
    .${provider} or "";

  controlPlaneProviderVersion =
    provider:
    {
      talos = cfg.providerVersions.talosControlPlane;
      kubeadm = cfg.providerVersions.core;
    }
    .${provider} or "";

  infraApiVersion =
    provider:
    {
      docker = "infrastructure.cluster.x-k8s.io/v1beta1";
      digitalocean = "infrastructure.cluster.x-k8s.io/v1beta1";
      hetzner = "infrastructure.cluster.x-k8s.io/v1beta1";
      aws = "infrastructure.cluster.x-k8s.io/v1beta2";
    }
    .${provider} or "infrastructure.cluster.x-k8s.io/v1beta1";

  infraClusterKind =
    provider:
    {
      docker = "DockerCluster";
      digitalocean = "DOCluster";
      hetzner = "HetznerCluster";
      aws = "AWSCluster";
    }
    .${provider} or "DockerCluster";

  infraMachineTemplateKind =
    provider:
    {
      docker = "DockerMachineTemplate";
      digitalocean = "DOMachineTemplate";
      hetzner = "HetznerMachineTemplate";
      aws = "AWSMachineTemplate";
    }
    .${provider} or "DockerMachineTemplate";

  # Provider CR objects
  providerCRs =
    # CoreProvider
    {
      capi-core-provider = {
        apiVersion = "operator.cluster.x-k8s.io/v1alpha2";
        kind = "CoreProvider";
        metadata = {
          name = "cluster-api";
          namespace = cfg.namespace;
          labels = {
            "app.kubernetes.io/managed-by" = "catallaxy";
          };
        };
        spec.version = "v${cfg.providerVersions.core}";
      };
    }
    # BootstrapProviders
    // listToAttrs (
      map (
        bp:
        nameValuePair "capi-bootstrap-${bp}" {
          apiVersion = "operator.cluster.x-k8s.io/v1alpha2";
          kind = "BootstrapProvider";
          metadata = {
            name = bp;
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/managed-by" = "catallaxy";
            };
          };
          spec.version = "v${bootstrapProviderVersion bp}";
        }
      ) cfg.bootstrapProviders
    )
    # ControlPlaneProviders
    // listToAttrs (
      map (
        cp:
        nameValuePair "capi-controlplane-${cp}" {
          apiVersion = "operator.cluster.x-k8s.io/v1alpha2";
          kind = "ControlPlaneProvider";
          metadata = {
            name = cp;
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/managed-by" = "catallaxy";
            };
          };
          spec.version = "v${controlPlaneProviderVersion cp}";
        }
      ) cfg.controlPlaneProviders
    )
    # InfrastructureProviders
    // listToAttrs (
      map (
        ip:
        nameValuePair "capi-infra-${ip}" {
          apiVersion = "operator.cluster.x-k8s.io/v1alpha2";
          kind = "InfrastructureProvider";
          metadata = {
            name = ip;
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/managed-by" = "catallaxy";
            };
          };
          spec.version = "v${infraProviderVersion ip}";
        }
      ) cfg.infrastructureProviders
    );

  # Cluster resource generation
  mkClusterResources =
    clusterName: clusterCfg:
    let
      k8sVersion = clusterCfg.kubernetes.version;
      talosVersion = clusterCfg.talos.version;
      provider = clusterCfg.infrastructureProvider;
      cpReplicas = clusterCfg.kubernetes.controlPlane.replicas;
      commonLabels = {
        "cluster.x-k8s.io/cluster-name" = clusterName;
        "app.kubernetes.io/managed-by" = "catallaxy";
      };

      # Registry mirror preKubeadmCommands for containerd
      registryMirrorCommands =
        if clusterCfg.registryMirror.enable then
          lib.concatMap (registry: [
            "mkdir -p /etc/containerd/certs.d/${registry}"
            "cat > /etc/containerd/certs.d/${registry}/hosts.toml <<EOF\n[host.\"${clusterCfg.registryMirror.endpoint}\"]\n  capabilities = [\"pull\", \"resolve\"]\nEOF"
          ]) clusterCfg.registryMirror.registries
          ++ [
            # Restart containerd to pick up mirror config
            "systemctl restart containerd"
          ]
        else
          [ ];

      controlPlaneRef =
        if clusterCfg.talos.enable then
          {
            apiVersion = "controlplane.cluster.x-k8s.io/v1alpha3";
            kind = "TalosControlPlane";
            name = "${clusterName}-control-plane";
          }
        else
          {
            apiVersion = "controlplane.cluster.x-k8s.io/v1beta1";
            kind = "KubeadmControlPlane";
            name = "${clusterName}-control-plane";
          };

      clusterResource = {
        "${clusterName}-cluster" = {
          apiVersion = "cluster.x-k8s.io/v1beta1";
          kind = "Cluster";
          metadata = {
            name = clusterName;
            namespace = cfg.namespace;
            labels = commonLabels;
          };
          spec = {
            clusterNetwork = {
              pods.cidrBlocks = [ clusterCfg.network.podCIDR ];
              services.cidrBlocks = [ clusterCfg.network.serviceCIDR ];
            };
            inherit controlPlaneRef;
            infrastructureRef = {
              apiVersion = infraApiVersion provider;
              kind = infraClusterKind provider;
              name = clusterName;
            };
          };
        };
      };

      talosControlPlane = optionalAttrs clusterCfg.talos.enable {
        "${clusterName}-control-plane" = {
          apiVersion = "controlplane.cluster.x-k8s.io/v1alpha3";
          kind = "TalosControlPlane";
          metadata = {
            name = "${clusterName}-control-plane";
            namespace = cfg.namespace;
            labels = commonLabels;
          };
          spec = {
            version = k8sVersion;
            replicas = cpReplicas;
            infrastructureTemplate = {
              apiVersion = infraApiVersion provider;
              kind = infraMachineTemplateKind provider;
              name = "${clusterName}-control-plane";
            };
            controlPlaneConfig = {
              controlplane = {
                generateType = "controlplane";
                talosVersion = talosVersion;
              }
              // optionalAttrs (clusterCfg.apiServerExtraArgs != { } || clusterCfg.clientCaCert != null) {
                configPatches =
                  (optional (clusterCfg.apiServerExtraArgs != { }) {
                    op = "add";
                    path = "/cluster/apiServer/extraArgs";
                    value = clusterCfg.apiServerExtraArgs;
                  })
                  ++ (optional (clusterCfg.clientCaCert != null) {
                    op = "add";
                    path = "/machine/files/-";
                    value = {
                      path = "/etc/kubernetes/pki/client-ca.crt";
                      permissions = 292;
                      content = clusterCfg.clientCaCert;
                    };
                  });
              };
            };
          };
        };
      };

      kubeadmControlPlane = optionalAttrs (!clusterCfg.talos.enable) {
        "${clusterName}-control-plane" = {
          apiVersion = "controlplane.cluster.x-k8s.io/v1beta1";
          kind = "KubeadmControlPlane";
          metadata = {
            name = "${clusterName}-control-plane";
            namespace = cfg.namespace;
            labels = commonLabels;
          };
          spec = {
            version = k8sVersion;
            replicas = cpReplicas;
            machineTemplate.infrastructureRef = {
              apiVersion = infraApiVersion provider;
              kind = infraMachineTemplateKind provider;
              name = "${clusterName}-control-plane";
            };
            kubeadmConfigSpec = {
              clusterConfiguration = {
                apiServer = {
                  extraArgs = clusterCfg.apiServerExtraArgs;
                }
                // optionalAttrs (clusterCfg.certSANs != [ ]) { certSANs = clusterCfg.certSANs; };
                controllerManager.extraArgs = { };
                scheduler.extraArgs = { };
              };
              initConfiguration.nodeRegistration.kubeletExtraArgs = {
                "eviction-hard" = "nodefs.available<0%,nodefs.inodesFree<0%,imagefs.available<0%";
              };
              joinConfiguration.nodeRegistration.kubeletExtraArgs = {
                "eviction-hard" = "nodefs.available<0%,nodefs.inodesFree<0%,imagefs.available<0%";
              };
            }
            // optionalAttrs (registryMirrorCommands != [ ]) {
              preKubeadmCommands = registryMirrorCommands;
            };
          };
        };
      };

      bootstrapConfigRef =
        pool:
        if clusterCfg.talos.enable then
          {
            apiVersion = "bootstrap.cluster.x-k8s.io/v1alpha3";
            kind = "TalosConfigTemplate";
            name = "${clusterName}-${pool.name}";
          }
        else
          {
            apiVersion = "bootstrap.cluster.x-k8s.io/v1beta1";
            kind = "KubeadmConfigTemplate";
            name = "${clusterName}-${pool.name}";
          };

      workerDeployments = listToAttrs (
        imap0 (
          idx: pool:
          nameValuePair "${clusterName}-${pool.name}-md" {
            apiVersion = "cluster.x-k8s.io/v1beta1";
            kind = "MachineDeployment";
            metadata = {
              name = "${clusterName}-${pool.name}";
              namespace = cfg.namespace;
              labels = commonLabels // {
                "cluster.x-k8s.io/deployment-name" = pool.name;
              };
            };
            spec = {
              clusterName = clusterName;
              replicas = pool.replicas;
              selector.matchLabels = { };
              template = {
                metadata.labels = commonLabels // pool.labels;
                spec = {
                  version = k8sVersion;
                  clusterName = clusterName;
                  bootstrap.configRef = bootstrapConfigRef pool;
                  infrastructureRef = {
                    apiVersion = infraApiVersion provider;
                    kind = infraMachineTemplateKind provider;
                    name = "${clusterName}-${pool.name}";
                  };
                };
              };
            };
          }
        ) clusterCfg.kubernetes.workers
      );

      workerTalosConfigs = optionalAttrs clusterCfg.talos.enable (
        listToAttrs (
          map (
            pool:
            nameValuePair "${clusterName}-${pool.name}-talos-config" {
              apiVersion = "bootstrap.cluster.x-k8s.io/v1alpha3";
              kind = "TalosConfigTemplate";
              metadata = {
                name = "${clusterName}-${pool.name}";
                namespace = cfg.namespace;
                labels = commonLabels;
              };
              spec.template.spec = {
                generateType = "worker";
                talosVersion = talosVersion;
              };
            }
          ) clusterCfg.kubernetes.workers
        )
      );

      workerKubeadmConfigs = optionalAttrs (!clusterCfg.talos.enable) (
        listToAttrs (
          map (
            pool:
            nameValuePair "${clusterName}-${pool.name}-kubeadm-config" {
              apiVersion = "bootstrap.cluster.x-k8s.io/v1beta1";
              kind = "KubeadmConfigTemplate";
              metadata = {
                name = "${clusterName}-${pool.name}";
                namespace = cfg.namespace;
                labels = commonLabels;
              };
              spec.template.spec = {
                joinConfiguration.nodeRegistration.kubeletExtraArgs = {
                  "eviction-hard" = "nodefs.available<0%,nodefs.inodesFree<0%,imagefs.available<0%";
                };
              }
              // optionalAttrs (registryMirrorCommands != [ ]) {
                preKubeadmCommands = registryMirrorCommands;
              };
            }
          ) clusterCfg.kubernetes.workers
        )
      );

      # Infrastructure-specific resources
      mkDockerResources = {
        "${clusterName}-docker-cluster" = {
          apiVersion = "infrastructure.cluster.x-k8s.io/v1beta1";
          kind = "DockerCluster";
          metadata = {
            name = clusterName;
            namespace = cfg.namespace;
            labels = commonLabels;
          };
          spec = { };
        };
        "${clusterName}-control-plane-docker-template" = {
          apiVersion = "infrastructure.cluster.x-k8s.io/v1beta1";
          kind = "DockerMachineTemplate";
          metadata = {
            name = "${clusterName}-control-plane";
            namespace = cfg.namespace;
            labels = commonLabels;
          };
          spec.template.spec.extraMounts = [
            {
              containerPath = "/var/run/docker.sock";
              hostPath = "/var/run/docker.sock";
            }
          ];
        };
      }
      // listToAttrs (
        map (
          pool:
          nameValuePair "${clusterName}-${pool.name}-docker-template" {
            apiVersion = "infrastructure.cluster.x-k8s.io/v1beta1";
            kind = "DockerMachineTemplate";
            metadata = {
              name = "${clusterName}-${pool.name}";
              namespace = cfg.namespace;
              labels = commonLabels;
            };
            spec.template.spec.extraMounts = [
              {
                containerPath = "/var/run/docker.sock";
                hostPath = "/var/run/docker.sock";
              }
            ];
          }
        ) clusterCfg.kubernetes.workers
      );

      mkDOResources =
        let
          docfg = clusterCfg.digitalocean;
        in
        {
          "${clusterName}-do-cluster" = {
            apiVersion = "infrastructure.cluster.x-k8s.io/v1beta1";
            kind = "DOCluster";
            metadata = {
              name = clusterName;
              namespace = cfg.namespace;
              labels = commonLabels;
            };
            spec = {
              region = docfg.region;
            };
          };
          "${clusterName}-control-plane-do-template" = {
            apiVersion = "infrastructure.cluster.x-k8s.io/v1beta1";
            kind = "DOMachineTemplate";
            metadata = {
              name = "${clusterName}-control-plane";
              namespace = cfg.namespace;
              labels = commonLabels;
            };
            spec.template.spec = {
              size = docfg.controlPlaneSize;
              image.slug = docfg.image;
            }
            // optionalAttrs (docfg.sshKeys != [ ]) {
              sshKeys = docfg.sshKeys;
            };
          };
        }
        // listToAttrs (
          map (
            pool:
            nameValuePair "${clusterName}-${pool.name}-do-template" {
              apiVersion = "infrastructure.cluster.x-k8s.io/v1beta1";
              kind = "DOMachineTemplate";
              metadata = {
                name = "${clusterName}-${pool.name}";
                namespace = cfg.namespace;
                labels = commonLabels;
              };
              spec.template.spec = {
                size = pool.machineType or docfg.workerSize;
                image.slug = docfg.image;
              }
              // optionalAttrs (docfg.sshKeys != [ ]) {
                sshKeys = docfg.sshKeys;
              };
            }
          ) clusterCfg.kubernetes.workers
        );

      mkHetznerResources =
        let
          hcfg = clusterCfg.hetzner;
        in
        {
          "${clusterName}-hetzner-cluster" = {
            apiVersion = "infrastructure.cluster.x-k8s.io/v1beta1";
            kind = "HetznerCluster";
            metadata = {
              name = clusterName;
              namespace = cfg.namespace;
              labels = commonLabels;
            };
            spec = {
              controlPlaneRegions = [ hcfg.region ];
              controlPlaneLoadBalancer = {
                enabled = true;
                region = hcfg.region;
              };
            }
            // optionalAttrs hcfg.network.enabled {
              hcloudNetwork = {
                enabled = true;
                networkZone = hcfg.region;
                cidrBlock = hcfg.network.cidr;
              };
            }
            // optionalAttrs hcfg.placementGroup {
              hcloudPlacementGroups = [
                {
                  name = "${clusterName}-control-plane";
                  type = "spread";
                }
                {
                  name = "${clusterName}-workers";
                  type = "spread";
                }
              ];
            }
            // optionalAttrs (hcfg.sshKeyName != null) {
              sshKeys.hcloud = [ { name = hcfg.sshKeyName; } ];
            };
          };
          "${clusterName}-control-plane-hetzner-template" = {
            apiVersion = "infrastructure.cluster.x-k8s.io/v1beta1";
            kind = "HetznerMachineTemplate";
            metadata = {
              name = "${clusterName}-control-plane";
              namespace = cfg.namespace;
              labels = commonLabels;
            };
            spec.template.spec = {
              type = hcfg.controlPlaneType;
              imageName = "talos-${clusterCfg.talos.version}";
            }
            // optionalAttrs hcfg.placementGroup { placementGroupName = "${clusterName}-control-plane"; };
          };
        }
        // listToAttrs (
          map (
            pool:
            nameValuePair "${clusterName}-${pool.name}-hetzner-template" {
              apiVersion = "infrastructure.cluster.x-k8s.io/v1beta1";
              kind = "HetznerMachineTemplate";
              metadata = {
                name = "${clusterName}-${pool.name}";
                namespace = cfg.namespace;
                labels = commonLabels;
              };
              spec.template.spec = {
                type = pool.machineType or hcfg.workerType;
                imageName = "talos-${clusterCfg.talos.version}";
              }
              // optionalAttrs hcfg.placementGroup { placementGroupName = "${clusterName}-workers"; };
            }
          ) clusterCfg.kubernetes.workers
        );

      mkAWSResources =
        let
          acfg = clusterCfg.aws;
        in
        {
          "${clusterName}-aws-cluster" = {
            apiVersion = "infrastructure.cluster.x-k8s.io/v1beta2";
            kind = "AWSCluster";
            metadata = {
              name = clusterName;
              namespace = cfg.namespace;
              labels = commonLabels;
            };
            spec = {
              region = acfg.region;
              sshKeyName = acfg.sshKeyName;
            };
          };
          "${clusterName}-control-plane-aws-template" = {
            apiVersion = "infrastructure.cluster.x-k8s.io/v1beta2";
            kind = "AWSMachineTemplate";
            metadata = {
              name = "${clusterName}-control-plane";
              namespace = cfg.namespace;
              labels = commonLabels;
            };
            spec.template.spec = {
              instanceType = acfg.controlPlaneInstanceType;
              iamInstanceProfile = "control-plane.cluster-api-provider-aws.sigs.k8s.io";
              sshKeyName = acfg.sshKeyName;
            };
          };
        }
        // listToAttrs (
          map (
            pool:
            nameValuePair "${clusterName}-${pool.name}-aws-template" {
              apiVersion = "infrastructure.cluster.x-k8s.io/v1beta2";
              kind = "AWSMachineTemplate";
              metadata = {
                name = "${clusterName}-${pool.name}";
                namespace = cfg.namespace;
                labels = commonLabels;
              };
              spec.template.spec = {
                instanceType = pool.machineType or acfg.workerInstanceType;
                iamInstanceProfile = "nodes.cluster-api-provider-aws.sigs.k8s.io";
                sshKeyName = acfg.sshKeyName;
              };
            }
          ) clusterCfg.kubernetes.workers
        );

      infraResources =
        {
          docker = mkDockerResources;
          digitalocean = mkDOResources;
          hetzner = mkHetznerResources;
          aws = mkAWSResources;
        }
        .${provider} or { };

    in
    clusterResource
    // talosControlPlane
    // kubeadmControlPlane
    // workerDeployments
    // workerTalosConfigs
    // workerKubeadmConfigs
    // infraResources;

  enabledClusters = filterAttrs (_: c: c.enable) cfg.clusters;
  allClusterResources = concatMapAttrs mkClusterResources enabledClusters;
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.cluster-api = {
    enable = mkEnableOption "Cluster API";

    phase = mkOption {
      type = types.str;
      default = "infrastructure";
    };
    version = mkOption {
      type = types.str;
      default = "1.9.0";
    };
    namespace = mkOption {
      type = types.str;
      default = "capi-system";
    };
    chart = mkOption {
      type = types.package;
      default = cataCharts.capi-operator.chart;
    };
    isManagementCluster = mkOption {
      type = types.bool;
      default = false;
    };

    infrastructureProviders = mkOption {
      type = types.listOf (
        types.enum [
          "docker"
          "digitalocean"
          "aws"
          "gcp"
          "azure"
          "hetzner"
          "vsphere"
        ]
      );
      default = [ ];
    };
    bootstrapProviders = mkOption {
      type = types.listOf (
        types.enum [
          "kubeadm"
          "talos"
        ]
      );
      default = [ "talos" ];
    };
    controlPlaneProviders = mkOption {
      type = types.listOf (
        types.enum [
          "kubeadm"
          "talos"
        ]
      );
      default = [ "talos" ];
    };

    providerVersions = {
      core = mkOption {
        type = types.str;
        default = "1.9.0";
      };
      talosBootstrap = mkOption {
        type = types.str;
        default = "0.6.7";
      };
      talosControlPlane = mkOption {
        type = types.str;
        default = "0.5.13";
      };
      docker = mkOption {
        type = types.str;
        default = "1.9.0";
      };
      hetzner = mkOption {
        type = types.str;
        default = "1.0.0-beta.40";
      };
      digitalocean = mkOption {
        type = types.str;
        default = "0.5.0";
      };
      aws = mkOption {
        type = types.str;
        default = "2.7.0";
      };
    };

    clusters = mkOption {
      type = types.attrsOf capiClusterType;
      default = { };
    };
  };

  # =========================================================================
  # PART 2: Config and IR writer
  # =========================================================================

  config = lib.mkMerge [
    # Deploy phases for CAPI
    (mkIf cfg.enable {
      phases.capi-providers = mkIf cfg.isManagementCluster {
        order = 55;
        dependsOn = [ "infrastructure" ];
      };

      phases.capi-clusters = mkIf (enabledClusters != { }) {
        order = 150;
        dependsOn = [ "capi-providers" ];
        waitForCRDs = true;
        crdNames = [
          "clusters.cluster.x-k8s.io"
          "machinedeployments.cluster.x-k8s.io"
          "kubeadmcontrolplanes.controlplane.cluster.x-k8s.io"
          "kubeadmconfigtemplates.bootstrap.cluster.x-k8s.io"
          "dockerclusters.infrastructure.cluster.x-k8s.io"
          "dockermachinetemplates.infrastructure.cluster.x-k8s.io"
        ];
      };
    })

    # =========================================================================
    # PART 3: Phase writer - CAPI Operator Helm chart
    # =========================================================================

    (mkIf (cfg.enable && cfg.isManagementCluster) {
      phases.${cfg.phase}.bundles.cluster-api = {
        helmCharts.capi-operator = {
          chart = chartRef;
          releaseName = "capi-operator";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            cert-manager.enabled = false;
          };
        };

        createNamespaces = [ cfg.namespace ];
      };
    })

    # =========================================================================
    # PART 4: Phase writer - Provider CRs (capi-providers phase)
    # =========================================================================

    (mkIf (cfg.enable && cfg.isManagementCluster) {
      phases.capi-providers.bundles.capi-providers.resources = providerCRs;
    })

    # =========================================================================
    # PART 5: Phase writer - Cluster resources (capi-clusters phase)
    # =========================================================================

    (mkIf (cfg.enable && enabledClusters != { }) {
      phases.capi-clusters.bundles.capi-clusters.resources = allClusterResources;
    })
  ];
}
