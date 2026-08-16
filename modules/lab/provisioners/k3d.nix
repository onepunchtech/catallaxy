{
  config,
  lib,
  pkgs,
  lab,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    mapAttrsToList
    ;
  oidcCfg = config.cluster.apiserver.oidc;
  pkiCfg = config.cluster.apiserver.pki;

  driftCheck = pkgs.writeShellApplication {
    name = "k3d-drift-check";
    runtimeInputs = with pkgs; [
      docker-client
      jq
    ];
    text = ''
            set -euo pipefail
            cluster_name="${config.provisioner.k3d.clusterName}"
            desired_service_cidr="${config.cluster.network.serviceSubnet}"
            desired_pod_cidr="${config.cluster.network.podSubnet}"

            container="k3d-$cluster_name-server-0"

            if ! docker inspect "$container" >/dev/null 2>&1; then
              exit 0
            fi

            args=$(docker inspect "$container" \
              | jq -r '.[0].Args | join(" ")')

            live_service_cidr=$(printf '%s\n' "$args" \
              | grep -oE -- '--service-cidr=[^@ ]+' \
              | head -1 | cut -d= -f2 || true)
            live_pod_cidr=$(printf '%s\n' "$args" \
              | grep -oE -- '--cluster-cidr=[^@ ]+' \
              | head -1 | cut -d= -f2 || true)

            drifted=0
            if [ "$live_service_cidr" != "$desired_service_cidr" ]; then drifted=1; fi
            if [ "$live_pod_cidr" != "$desired_pod_cidr" ]; then drifted=1; fi

            if [ $drifted -eq 1 ]; then
              cat >&2 <<EOF
      k3d cluster '$cluster_name' on disk has stale network config:
        live    serviceSubnet=''${live_service_cidr:-<unset>}  podSubnet=''${live_pod_cidr:-<unset>}
        desired serviceSubnet=$desired_service_cidr            podSubnet=$desired_pod_cidr

      k3s locks both CIDRs at apiserver startup; neither can change on a
      live cluster. Destroy and recreate to pick up the current nix
      config:

        k3d cluster delete $cluster_name

      Then re-run \`cata lab up\`.
      EOF
              exit 1
            fi
    '';
  };
in
{
  options.provisioner.k3d = {
    clusterName = mkOption {
      type = types.str;
      default =
        if lab.contextPrefix == "" then
          config.cluster.name
        else
          "${lab.contextPrefix}-${config.cluster.name}";
      defaultText = lib.literalExpression ''
        if lab.contextPrefix == "" then config.cluster.name
        else "''${lab.contextPrefix}-''${config.cluster.name}"
      '';
      description = ''
        Name passed to `k3d cluster create` (also the docker container
        name prefix). Defaults to `<lab.contextPrefix>-<cluster.name>`
        when a context prefix is set, so containers do not collide
        between labs that share a `cluster.name`.
      '';
    };

    image = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Custom k3s image (null = k3d default)";
    };

    noTraefik = mkOption {
      type = types.bool;
      default = true;
      description = "Disable default Traefik ingress";
    };

    noServiceLB = mkOption {
      type = types.bool;

      default = false;
      description = "Disable default ServiceLB (Klipper)";
    };

    noFlannel = mkOption {
      type = types.bool;

      default = config.floes.cilium.enable or false;
      defaultText = lib.literalExpression "config.floes.cilium.enable";
      description = ''
        Disable k3s's bundled Flannel CNI. Defaults to on exactly when
        the cilium floe is enabled to replace it.
      '';
    };

    ports = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Port mappings for k3d (passed as -p flags).
        Format: "<host>:<container>@server:0" e.g. "8080:80@server:0"
      '';
    };

    udpPorts = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            host = mkOption {
              type = types.port;
              description = "Host port published on the docker host.";
            };
            container = mkOption {
              type = types.port;
              description = "Container port inside the k3d node.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Convenience UDP port mappings. Each entry expands to a
        `<host>:<container>/udp@server:0` -p flag on k3d cluster create.
        Used for components that need direct UDP exposure (e.g.
        Netbird's TURN on 3478 and WireGuard control on 51820) since
        the lab haproxy is TCP-only.
      '';
    };

    extraApiServerArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra kube-apiserver arguments passed to k3d via
        --k3s-arg "--kube-apiserver-arg=<value>@server:*".
        Automatically populated from cluster.apiserver.{oidc,pki}.
      '';
    };

    extraVolumes = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            hostPath = mkOption {
              type = types.str;
              description = "Path on the Docker host";
            };
            containerPath = mkOption {
              type = types.str;
              description = "Path inside k3d node";
            };
          };
        }
      );
      default = [ ];
      description = "Extra volume mounts for k3d server nodes (e.g., CA certs)";
    };

    network = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Docker network to create k3d cluster on (uses --network flag). When set, all clusters share this network for cross-cluster DNS.";
    };

    autoDeployManifests = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Manifest filename (without .yaml)";
            };
            content = mkOption {
              type = types.path;
              description = "Nix store path to rendered manifest YAML";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Manifests to mount into k3s auto-deploy directory
        (/var/lib/rancher/k3s/server/manifests/). k3s applies these at boot.
        Used for pre-deploying CNI (Cilium) so nodes become Ready immediately.
      '';
    };
  };

  config.cluster.ref.kubeContext = mkIf (
    config.cluster.provisioner == "k3d"
  ) "k3d-${config.provisioner.k3d.clusterName}";

  config.assertions = lib.optional (config.cluster.provisioner == "k3d") {
    assertion = builtins.stringLength config.provisioner.k3d.clusterName <= 32;
    message =
      let
        name = config.provisioner.k3d.clusterName;
      in
      "cluster '${config.cluster.name}': k3d cluster name '${name}' is "
      + "${toString (builtins.stringLength name)} characters; k3d's limit is 32. "
      + "It defaults to `<lab.contextPrefix>-<cluster.name>`, and contextPrefix "
      + "defaults to lab.name. If your cluster names already carry the "
      + "environment (e.g. 'staging-platform-mgmt'), set `lab.contextPrefix = \"\"` "
      + "to drop the redundant prefix, or set "
      + "`provisioner.k3d.clusterName` explicitly to something shorter.";
  };

  config.lifecycle.preProvision = lib.optional (config.cluster.provisioner == "k3d") {
    name = "k3d-drift-check";
    description = "Check k3d cluster on disk for stale --service-cidr / --cluster-cidr";
    order = -10;
    package = driftCheck;
  };

  config.provisioner.k3d = mkIf (config.cluster.provisioner == "k3d") {

    ports = map (
      p: "${toString p.host}:${toString p.container}/udp@server:0"
    ) config.provisioner.k3d.udpPorts;

    extraApiServerArgs =

      (lib.optionals oidcCfg.enable (mapAttrsToList (k: v: "${k}=${v}") oidcCfg.out.apiServerArgs))

      ++ (lib.optionals pkiCfg.enable (mapAttrsToList (k: v: "${k}=${v}") pkiCfg.out.apiServerArgs))

      ++ (lib.optionals config.cluster.security.auditLogging.enable [
        "audit-policy-file=/etc/kubernetes/audit/policy.yaml"
        "audit-log-path=/var/log/kubernetes/audit.log"
        "audit-log-maxage=7"
        "audit-log-maxbackup=3"
        "audit-log-maxsize=100"
      ]);

    extraVolumes =
      lib.optionals pkiCfg.enable [
        {
          hostPath = "{{PKI_DIR}}/ca.crt";
          containerPath = pkiCfg.out.clientCaPath;
        }
      ]
      ++ lib.optionals config.cluster.security.auditLogging.enable [
        {
          hostPath = "{{STATE_DIR}}/audit/{{CLUSTER_NAME}}/policy.yaml";
          containerPath = "/etc/kubernetes/audit/policy.yaml";
        }
      ]

      ++ lib.optionals (lab.proxy.enable or false) [
        {
          hostPath = "{{STATE_DIR}}/proxy/ca.crt";
          containerPath = "/etc/ssl/certs/lab-ca.crt";
        }
      ];
  };
}
