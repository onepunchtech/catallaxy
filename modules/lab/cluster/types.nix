{
  config,
  lib,
  lab,
  ...
}:

let
  inherit (lib) mkOption types;
in
{
  config.cluster.provider =
    if config.cluster.provisioner == "k3d" || config.cluster.provisioner == "talos" then
      "docker"
    else
      config.cluster.provisioner;

  config.cluster.ref.kubeContext = lib.mkDefault (
    if lab.contextPrefix == "" then
      config.cluster.name
    else
      "${lab.contextPrefix}-${config.cluster.name}"
  );

  options.cluster = {
    name = mkOption {
      type = types.str;
      description = "Unique name for this cluster";
      example = "local";
    };

    provisioner = mkOption {
      type = types.enum [
        "k3d"
        "talos"
        "crossplane"
        "external"
      ];
      default = "k3d";
      description = ''
        How this cluster is provisioned:
        - k3d: k3s-in-Docker (local development)
        - talos: Talos-in-Docker (local development)
        - crossplane: Provisioned via Crossplane from another cluster
        - external: Pre-existing cluster, just configure it
      '';
    };

    provider = mkOption {
      type = types.enum [
        "docker"
        "crossplane"
        "external"
      ];
      readOnly = true;
      description = "Computed provider category (derived from cluster.provisioner)";
    };

    registryDomains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Hostnames of OCI registries this cluster hosts. A registry floe
        (harbor, zot) declares the domain it serves here, and the planner
        routes `lab.images` entries destined for that registry to a
        `publish-images` step on this cluster.

        This is the capability the planner asks for, so it reads no registry
        floe's own configuration and a new one needs no planner change.
      '';
    };

    provisions = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              resourceKind = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Fully qualified CRD kind of the in-cluster object whose
                  deletion destroys the provisioned cluster, as in
                  `cluster.kubernetes.digitalocean.crossplane.io`. Null when
                  the floe tears its clusters down itself, which the
                  cluster-api floe does with a script.
                '';
              };

              resourceName = mkOption {
                type = types.str;
                default = name;
                description = "Name of that object, when it differs from the cluster's.";
              };

              externalNameDiscoveryBin = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Executable that recovers the provider's external name for
                  the object before it is deleted, for a provider that
                  cannot find the cloud resource without it.
                '';
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Lab clusters this cluster brings into existence, keyed as they are
        named under `lab.clusters`. A floe that manages cluster lifecycle
        (crossplane, cluster-api) declares what it will create here, and the
        planner derives the rest: which clusters need their kubeconfig
        synced, whether this cluster provisions itself and therefore has to
        pivot, and what the teardown deletes and waits for.

        This is the capability the planner asks for. It reads no floe's
        internal configuration, so a new provisioner floe needs no planner
        change.
      '';
    };

    kubernetes = {
      distribution = mkOption {
        type = types.enum [
          "talos"
          "k3s"
          "k8s"
        ];
        default = "talos";
        description = "Kubernetes distribution to use";
      };

      version = mkOption {
        type = types.str;
        default = "1.31";
        description = "Kubernetes API version for type generation (e.g., '1.31')";
      };

      controlPlanes = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of control plane nodes";
      };

      workers = mkOption {
        type = types.ints.unsigned;
        default = 1;
        description = "Number of worker nodes";
      };
    };

    talos = {
      version = mkOption {
        type = types.str;
        default = "v1.13.0";
        description = "Talos version";
      };

      cniNone = mkOption {
        type = types.bool;
        default = true;
        description = "Disable built-in CNI (for Cilium)";
      };

      kubeProxyDisabled = mkOption {
        type = types.bool;
        default = true;
        description = "Disable kube-proxy (for Cilium kube-proxy replacement)";
      };
    };

    network = {
      podSubnet = mkOption {
        type = types.str;
        default = "10.244.0.0/16";
        description = "Pod network CIDR";
      };

      serviceSubnet = mkOption {
        type = types.str;
        default = "10.96.0.0/12";
        description = "Service network CIDR";
      };
    };

    provisioning = {
      rootBundles = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "crossplane-resources" ];
        description = ''
          Bundle names that drive cluster provisioning. On a
          self-provisioning cluster, the
          k3d bootstrap installs the transitive DAG closure of these
          including all CRDs, operators, and secrets the roots
          require.

          Empty (default): the cluster does not self-provision; no
          stage1 subset is rendered.
        '';
      };
    };

    ref = {
      kubeContext = mkOption {
        type = types.str;
        description = "Kubernetes context name for kubectl/velero/etc. Set by provisioner modules.";
      };
    };

    security = {
      podSecurity = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Apply Pod Security Admission labels to lab-managed namespaces";
        };
        default = mkOption {
          type = types.enum [
            "restricted"
            "baseline"
            "privileged"
          ];
          default = "restricted";
          description = "Default PSA level for lab namespaces. Components can override per-namespace.";
        };
        namespaceOverrides = mkOption {
          type = types.attrsOf (
            types.enum [
              "restricted"
              "baseline"
              "privileged"
            ]
          );
          default = { };
          description = "Per-namespace PSA level overrides (e.g., kube-system = privileged)";
        };
      };

      networkPolicies = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Generate default-deny NetworkPolicies for lab namespaces. Components add allow rules.";
        };

        default = mkOption {
          type = (import ../network-policy-types.nix { inherit lib; }).namespacePolicyType;
          default = { };
          description = ''
            What every lab-managed namespace gets before any floe asks for
            anything.
          '';
        };

        namespaceOverrides = mkOption {
          type = types.attrsOf (import ../network-policy-types.nix { inherit lib; }).namespacePolicyType;
          default = { };
          example = lib.literalExpression ''
            {
              harbor.egress.internet.ports = [ 443 ];
            }
          '';
          description = ''
            Per-namespace configuration, used instead of `default` rather
            than merged into it, so what a namespace ends up with reads in
            one place.

            `dns`, `apiServer` and `sameNamespace` still default to true
            here. Replacing the rest of `default` is a reasonable thing to
            want; silently dropping name resolution because a line was not
            restated is not, and unlike a missing flow nothing downstream
            would catch it.
          '';
        };

        apiServerCidrs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "172.19.0.0/16" ];
          description = ''
            Address ranges the API server answers on, used only when the
            cluster has no CNI that can name it.

            A plain `NetworkPolicy` cannot say "the API server": the service
            IP resolves to a host-network node address, so the only way to
            permit it is an address range that covers the control plane. On a
            local lab that is the docker bridge the nodes sit on, which is
            what this defaults to. Cilium names the API server outright and
            ignores this.

            Widening it widens what every pod in the lab may reach on the API
            ports, so it is worth setting to the control plane rather than
            leaving it at something generous.
          '';
        };
      };

      auditLogging = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable Kubernetes API server audit logging. Provisioner-specific.";
        };
      };
    };

    certSANs = mkOption {
      type = types.listOf types.str;
      default = [
        "127.0.0.1"
        "localhost"
      ];
      description = ''
        Extra Subject Alternative Names added to CAPI cluster API server certificates.
        Includes 127.0.0.1 so kubeconfigs rewritten for host access work with valid TLS.
      '';
    };
  };
}
