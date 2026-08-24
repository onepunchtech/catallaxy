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

    trust.caConfigMaps = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            namespace = mkOption {
              type = types.str;
              description = "Namespace to write the ConfigMap in.";
            };
            name = mkOption {
              type = types.str;
              description = "Name of the ConfigMap.";
            };
            key = mkOption {
              type = types.str;
              description = "Key under which the CA certificate is stored.";
            };
          };
        }
      );
      default = [ ];
      example = lib.literalExpression ''
        [
          {
            namespace = "argocd";
            name = "argocd-tls-certs-cm";
            key = "git.homelab.test";
          }
        ]
      '';
      description = ''
        Where the lab's CA certificate should appear in this cluster as a
        ConfigMap, beyond the trust bundle every namespace already gets.

        A workload that verifies TLS against its own trust store can be
        handed the lab CA by mounting that bundle. One that reads a CA from
        a particular object, under a particular key, cannot: argocd takes
        repository CAs only from `argocd-tls-certs-cm`, keyed by hostname.
        This says where those objects are, and `cata lab up` writes them
        when it creates the cluster, before anything that reads them exists.

        Entries sharing a namespace and name become one ConfigMap with a key
        each. Only the certificate travels; the key stays on this machine.
      '';
    };

    cd.repoUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://git.homelab.test/infrastructure/manifests.git";
      description = ''
        Where this cluster's reconciler clones the manifests repository
        from, when that address differs from `lab.cd.<strategy>.repoUrl`.

        A lab that hosts its own git server reaches it from the cluster it
        runs on by a service address no other cluster can resolve, so a
        second cluster has to be told the address it can reach: the lab
        hostname through the ingress, rather than the in-cluster service.

        Null means the lab-wide URL, which is right for the cluster the git
        server runs on and for any lab whose repository is remote.
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

      uncheckedResources = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "cluster.x-k8s.io/v1beta2/Cluster" ];
        description = ''
          `<group>/<version>/<Kind>` pairs whose spec is passed through
          without a schema, on purpose.

          A resource is checked against the schema its `apiVersion` and
          `kind` name together. When the tree holds schemas for that kind
          but none for that apiVersion, evaluation refuses, because the
          resource looks checked and is not. That is usually a typo in the
          apiVersion. When it is not, the CRD genuinely is not in the tree:
          Cluster API and Crossplane install their resource CRDs at runtime
          through an operator, and an out-of-tree floe can ship a kind this
          repo never sees.

          Listing a pair here says so deliberately, and keeps the refusal
          available for the typo it is really there to catch. The way to
          remove an entry is to add a `crd` definition in `lib/charts.nix`
          and run `nix run .#generate-k8s-types`.
        '';
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
        default = config.floes.cilium.enable or false;
        defaultText = lib.literalExpression "config.floes.cilium.enable";
        description = ''
          Tell Talos not to install a CNI, because something else will.
          Defaults to on exactly when the cilium floe is enabled to replace it,
          the same way `provisioner.k3d.noFlannel` does. A cluster with this on
          and nothing supplying a CNI never schedules anything.
        '';
      };

      kubeProxyDisabled = mkOption {
        type = types.bool;
        default = config.floes.cilium.enable or false;
        defaultText = lib.literalExpression "config.floes.cilium.enable";
        description = ''
          Tell Talos not to install kube-proxy, for a CNI that replaces it.
          Defaults from the cilium floe for the same reason `cniNone` does.
        '';
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

    bootstrapManifests = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Manifest filename, without the .yaml suffix.";
            };
            content = mkOption {
              type = types.path;
              description = "Store path of the rendered manifest.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Manifests the cluster must have before its nodes can become Ready,
        applied by the provisioner as the cluster comes up rather than by the
        deploy that follows it. A CNI is the case this exists for: without one,
        nothing schedules, so nothing can apply it.

        Provisioner-neutral because how they are delivered is not: k3s reads
        `/var/lib/rancher/k3s/server/manifests`, Talos takes inline manifests
        in machine config. A floe declares what the cluster needs and the
        provisioner decides how it arrives. Cilium used to write straight into
        `provisioner.k3d.autoDeployManifests`, so on any other provisioner it
        contributed nothing and the cluster came up with no CNI at all.
      '';
    };

    provisionerOut = {
      ingressBackend = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Hostname the lab's ingress proxy sends this cluster's traffic to,
          as resolvable on the lab's docker network.

          Answered by the provisioner because only it knows what its nodes are
          called: k3d names them `k3d-<cluster>-server-0`, Talos names them
          `<cluster>-controlplane-1`. The proxy used to derive the k3d form
          itself, which is why a cluster built any other way routed nowhere.

          Null means the provisioner does not put a reachable node on the lab
          network, so the proxy skips it rather than emitting a backend that
          cannot resolve.
        '';
      };

      publishesGatewayPorts = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this provisioner makes the cluster's gateway answer on 80
          and 443 of `ingressBackend` without anything else being arranged.

          k3s's bundled ServiceLB does: it schedules a pod that binds those
          ports on the node container, so a LoadBalancer Service is reachable
          at the node's name. Nothing else here does, and the lab quietly
          assumed all of them did, because k3d was the only one that had ever
          been stood up. On Talos the gateway's Service stays Pending and
          port 80 of the node answers nothing.

          False means the gateway has to be reached by a port the lab pins
          itself, which is what `cluster.ingress` carries.
        '';
      };
    };

    ingress = {
      httpPort = mkOption {
        type = types.port;
        default = 80;
        description = ''
          Port on `provisionerOut.ingressBackend` carrying this cluster's
          plaintext ingress, as the lab's proxy should dial it.

          Defaults to the port a provisioner that publishes the gateway's own
          ports would answer on. A gateway reached by NodePort overrides it,
          because 80 there belongs to nothing.
        '';
      };

      httpsPort = mkOption {
        type = types.port;
        default = 443;
        description = "As `httpPort`, for the TLS listener.";
      };

      passthroughPort = mkOption {
        type = types.port;
        default = 8444;
        description = ''
          As `httpPort`, for the listener that hands TLS to the backend
          without terminating it.

          Separate from `httpsPort` because it is a separate listener on the
          controller, and it moves for the same reason the others do: on a
          gateway reached by NodePort the controller's own port is not the
          port anything outside the cluster can dial.
        '';
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
          example = lib.literalExpression ''
            {
              harbor = "baseline";
            }
          '';
          description = ''
            Per-namespace PSA level overrides.

            Only namespaces this cluster creates are labelled, so a key
            outside that set does nothing and is refused. In particular a
            pre-existing namespace such as `kube-system` cannot be relabelled
            from here.
          '';
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
