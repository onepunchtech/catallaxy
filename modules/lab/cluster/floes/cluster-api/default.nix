{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
  planTokens = import ../../../../../lib/plan-tokens.nix { inherit lib; };
in
(mkFloe {
  name = "cluster-api";
  version = "1.9.0";
  imports = [ ./options.nix ];
  module =
    {
      config,
      lib,
      cataCharts,
      cfg,
      peers,
      ...
    }:
    let
      inherit (lib)
        mkIf
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

      chartRef = cfg.chart;

      toExtraArgs = attrs: lib.mapAttrsToList (name: value: { inherit name value; }) attrs;

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

      providerCRs =

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
              spec = {
                version = "v${infraProviderVersion ip}";
              }
              // optionalAttrs (ip == "digitalocean") {
                configSecret = {
                  name = "capi-do-credentials";
                  namespace = cfg.namespace;
                };

                deployment = {
                  containers = [
                    {
                      name = "kube-rbac-proxy";
                      imageUrl = cfg.images.rbac-proxy.ref;
                    }
                  ];
                };
              };
            }
          ) cfg.infrastructureProviders
        );

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

          registryMirrorCommands =
            if clusterCfg.registryMirror.enable then
              lib.concatMap (registry: [
                "mkdir -p /etc/containerd/certs.d/${registry}"
                "cat > /etc/containerd/certs.d/${registry}/hosts.toml <<EOF\n[host.\"${clusterCfg.registryMirror.endpoint}\"]\n  capabilities = [\"pull\", \"resolve\"]\nEOF"
              ]) clusterCfg.registryMirror.registries
              ++ [

                "systemctl restart containerd"
              ]
            else
              [ ];

          controlPlaneRef =
            if clusterCfg.talos.enable then
              {
                apiGroup = "controlplane.cluster.x-k8s.io";
                kind = "TalosControlPlane";
                name = "${clusterName}-control-plane";
              }
            else
              {
                apiGroup = "controlplane.cluster.x-k8s.io";
                kind = "KubeadmControlPlane";
                name = "${clusterName}-control-plane";
              };

          clusterResource = {
            "${clusterName}-cluster" = {
              apiVersion = "cluster.x-k8s.io/v1beta2";
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
                  apiGroup = "infrastructure.cluster.x-k8s.io";
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
              apiVersion = "controlplane.cluster.x-k8s.io/v1beta2";
              kind = "KubeadmControlPlane";
              metadata = {
                name = "${clusterName}-control-plane";
                namespace = cfg.namespace;
                labels = commonLabels;
              };
              spec = {
                version = k8sVersion;
                replicas = cpReplicas;
                machineTemplate = {
                  spec.infrastructureRef = {
                    apiGroup = "infrastructure.cluster.x-k8s.io";
                    kind = infraMachineTemplateKind provider;
                    name = "${clusterName}-control-plane";
                  };
                };
                kubeadmConfigSpec =
                  { }
                  // optionalAttrs (clusterCfg.apiServerExtraArgs != { } || clusterCfg.certSANs != [ ]) {
                    clusterConfiguration.apiServer =
                      { }
                      // optionalAttrs (clusterCfg.apiServerExtraArgs != { }) {
                        extraArgs = toExtraArgs clusterCfg.apiServerExtraArgs;
                      }
                      // optionalAttrs (clusterCfg.certSANs != [ ]) {
                        certSANs = clusterCfg.certSANs;
                      };
                  }
                  // {
                    initConfiguration.nodeRegistration.kubeletExtraArgs = toExtraArgs {
                      "eviction-hard" = "nodefs.available<0%,nodefs.inodesFree<0%,imagefs.available<0%";
                    };
                    joinConfiguration.nodeRegistration.kubeletExtraArgs = toExtraArgs {
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
                apiGroup = "bootstrap.cluster.x-k8s.io";
                kind = "TalosConfigTemplate";
                name = "${clusterName}-${pool.name}";
              }
            else
              {
                apiGroup = "bootstrap.cluster.x-k8s.io";
                kind = "KubeadmConfigTemplate";
                name = "${clusterName}-${pool.name}";
              };

          workerDeployments = listToAttrs (
            imap0 (
              idx: pool:
              nameValuePair "${clusterName}-${pool.name}-md" {
                apiVersion = "cluster.x-k8s.io/v1beta2";
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
                        apiGroup = "infrastructure.cluster.x-k8s.io";
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
                  apiVersion = "bootstrap.cluster.x-k8s.io/v1beta2";
                  kind = "KubeadmConfigTemplate";
                  metadata = {
                    name = "${clusterName}-${pool.name}";
                    namespace = cfg.namespace;
                    labels = commonLabels;
                  };
                  spec.template.spec = {
                    joinConfiguration.nodeRegistration.kubeletExtraArgs = toExtraArgs {
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
                  image = docfg.image;
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
                    size = if pool.machineType != null then pool.machineType else docfg.workerSize;
                    image = docfg.image;
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
                    type = if pool.machineType != null then pool.machineType else hcfg.workerType;
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
                    instanceType = if pool.machineType != null then pool.machineType else acfg.workerInstanceType;
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
    lib.mkMerge [

      (mkIf cfg.isManagementCluster {
        floes.cluster-api.images.rbac-proxy = {
          registry = "quay.io";
          repository = "brancz/kube-rbac-proxy";
          tag = "v0.18.1";
        };

        floes.cluster-api.network = {

          declared = true;

        };

        floes.cluster-api.imagesComplete = true;

        floes.cluster-api.images.operator = {

          registry = "registry.k8s.io";

          repository = "capi-operator/cluster-api-operator";

          tag = "v0.27.0";

        };

        bundles.cluster-api = {
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

          requires = refs.needs peers.cert-manager.issuance "webhookReady";
          provides = [ "cluster-api/operator/ready" ];
          readyProbe = {
            kind = "condition";
            resource = "deployment/capi-operator-cluster-api-operator";
            namespace = cfg.namespace;
            condition = "Available";
            timeout = "10m";
          };
        };
      })

      (mkIf cfg.isManagementCluster {
        bundles.capi-providers.resources = providerCRs;
        bundles.capi-providers.requires = [
          "cluster-api/operator/ready"
        ];
        bundles.capi-providers.provides = [
          "cluster-api/providers/ready"
        ];

        bundles.capi-namespaces.createNamespaces = lib.concatMap (
          p:
          {
            digitalocean = [ "capdo-system" ];
          }
          .${p} or [ ]
        ) cfg.infrastructureProviders;

        secrets.projections = lib.mkMerge [
          (optionalAttrs (elem "digitalocean" cfg.infrastructureProviders) {
            capi-do-credentials = {
              source = "do-token";
              namespace = cfg.namespace;
              keys.DO_B64ENCODED_CREDENTIALS = {
                from = "token";
                transform = "base64";
              };
            };
          })
        ];
      })

      (mkIf (enabledClusters != { }) {
        cluster.provisions = lib.mapAttrs (_: _: { }) enabledClusters;

        bundles.capi-clusters.resources = allClusterResources;
        bundles.capi-clusters.requires = [
          "cluster-api/providers/ready"
        ];
        bundles.capi-clusters.provides = [
          "cluster-api/clusters/provisioned"
        ];

        steps.capi-clusters = {
          kind = "run-script";
          direction = "teardown";
          description = "Delete CAPI-managed clusters and wait for cloud resource cleanup";
          provides = [
            planTokens.lab.cleanup
            (planTokens.cluster config.cluster.name).cleanup
          ];
          policy.onFailure = "continue";
          params.bin =
            let

              kubeContext = config.cluster.ref.kubeContext or "";
              namespace = cfg.namespace;
              clusterNames = lib.attrNames enabledClusters;
              deleteCommands = lib.concatStringsSep "\n" (
                map (name: ''
                  echo "Deleting CAPI cluster '${name}'..."
                  kubectl --context "${kubeContext}" delete cluster "${name}" \
                    -n "${namespace}" --ignore-not-found --wait=false
                '') clusterNames
              );
              waitCommands = lib.concatStringsSep "\n" (
                map (name: ''
                  echo "Waiting for cluster '${name}' to be fully deleted..."
                  kubectl --context "${kubeContext}" wait --for=delete \
                    "cluster/${name}" -n "${namespace}" --timeout=600s 2>/dev/null || true
                '') clusterNames
              );
              script = pkgs.writeShellApplication {
                name = "capi-teardown";
                runtimeInputs = [ pkgs.kubectl ];
                text = ''
                  if [ -z "${kubeContext}" ]; then
                    echo "no kube context resolved; skipping CAPI cluster deletion" >&2
                    exit 0
                  fi
                  ${deleteCommands}
                  ${waitCommands}
                  echo "All CAPI clusters deleted"
                '';
              };
            in
            "${script}/bin/capi-teardown";
        };
      })
    ];
})
  __floeModuleArgs
