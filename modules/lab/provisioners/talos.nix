{
  config,
  lib,
  lab,
  ...
}:

let
  inherit (lib)
    mkOption
    types
    mkIf
    ;
  cfg = config.provisioner.talos;
  isTalos = config.cluster.provisioner == "talos";
in
{
  options.provisioner.talos = {
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
        Name passed to `talosctl cluster create docker`, which is also the
        prefix of the node container names and of the docker network it
        creates.

        Prefixed with the lab's context prefix for the same reason the k3d
        name is: two labs that share a `cluster.name` would otherwise collide
        on container names. `provisioner.docker.clusterName`, which Talos used
        to borrow, has no such prefixing.
      '';
    };

    image = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "ghcr.io/siderolabs/talos:v1.12.6";
      description = ''
        Talos image the nodes run. Null takes talosctl's own default for the
        version it was built from.

        This pins the operating system, not Kubernetes. `--kubernetes-version`
        is separate, which is the honest split k3d does not have: there a
        single node image decides both.
      '';
    };

    kubernetesVersion = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "1.32.5";
      description = ''
        Kubernetes version the cluster runs, as a full `major.minor.patch`.
        Null takes talosctl's default for its own version.

        Deliberately not derived from `cluster.kubernetes.version`, which is
        the schema set the manifests are typed against and is written
        `major.minor`. Passing that here asks Talos for a kubelet image tagged
        `v1.31`, which does not exist, and the cluster fails to come up. The
        same conflation on the k3d side made a node replacement run with an
        unchanged image and report success.
      '';
    };

    subnet = mkOption {
      type = types.str;
      default = "10.5.0.0/24";
      description = ''
        CIDR for the docker network talosctl creates for this cluster.

        Talos will not join an existing network, so unlike k3d the cluster
        does not sit on the lab's bridge. The nodes reach the lab's services
        through this network's gateway, which is the docker host, the same way
        k3d nodes reach it through `host.k3d.internal`.

        Must not overlap another lab's `lab.network.dockerSubnet` or another
        Talos cluster's subnet.
      '';
    };

    exposedPorts = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "8080:80/tcp" ];
      description = ''
        Ports published from the first control plane node to the docker host,
        as `<host>:<container>/<tcp|udp>`.
      '';
    };

    mounts = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "type=bind,source=/host/path,destination=/var/lib/thing" ];
      description = "Extra mounts on the node containers, in docker --mount syntax.";
    };

    memory = mkOption {
      type = types.str;
      default = "2.0GiB";
      description = "Memory limit per node. Talos needs considerably more than a k3s container.";
    };

    cpus = mkOption {
      type = types.str;
      default = "2.0";
      description = "CPU share per node, as a fraction.";
    };

    reachableFrom = mkOption {
      type = types.listOf types.str;
      default = lib.optional (lab.proxy.enable or false) (lab.proxy.containerName or "");
      defaultText = lib.literalExpression "[ lab.proxy.containerName ]";
      description = ''
        Containers attached to this cluster's docker network once it exists,
        so they can reach its nodes.

        talosctl will not join an existing network, and the cluster's traffic
        is only served on the one it makes: kube-proxy runs in nftables mode
        and will not answer a NodePort on an interface added afterwards, so
        putting the nodes on the lab's bridge as well looks right and still
        refuses every connection. Reaching in is the direction that works.

        The lab's proxy is here by default because it is the thing that has to
        route to the cluster at all. k3d needs none of this: it takes
        `--network` and is on the lab's bridge from the start.
      '';
    };

    configPatches = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Machine config patches applied to every node, each a JSON or YAML
        document.

        This is how Talos is configured at all: registry mirrors, CA trust,
        nameservers, API server arguments and the CNI choice are all machine
        config rather than command line flags. Where k3d takes a bind mount or
        a `--k3s-arg`, Talos takes a patch.
      '';
    };
  };

  config = mkIf isTalos {
    # What talosctl actually writes into the kubeconfig. The generic default
    # is `<contextPrefix>-<cluster>`, which matches nothing, and every step
    # after cluster creation addresses the cluster through this string.
    cluster.ref.kubeContext = "admin@${cfg.clusterName}";

    cluster.provisionerOut.ingressBackend = "${cfg.clusterName}-controlplane-1";

    cluster.capabilities.provides = lib.optionalAttrs (!config.cluster.talos.cniNone) {
      cni = {
        exclusive = true;
        provider = "the CNI Talos installs";
        disableWith = "cluster.talos.cniNone = true";
      };
    };

    provisioner.talos.configPatches =
      # Talos installs its own CNI unless told otherwise. Defaulted from the
      # cilium floe exactly as k3d's `noFlannel` is, so a lab that replaces
      # the CNI does not have to say so twice, and one that does not keeps a
      # working cluster.
      lib.optional (config.cluster.talos.cniNone) (
        builtins.toJSON {
          cluster.network.cni.name = "none";
        }
      )

      # Cilium's kube-proxy replacement wants Talos to not install one.
      ++ lib.optional config.cluster.talos.kubeProxyDisabled (
        builtins.toJSON {
          cluster.proxy.disabled = true;
        }
      )

      # Whatever the cluster declares as bootstrap manifests has to arrive as
      # an inline manifest in machine config rather than as a file on a node
      # that cannot schedule yet, which is the state a CNI-less cluster is in.
      ++ lib.optional (config.cluster.bootstrapManifests != [ ]) (
        builtins.toJSON {
          cluster.inlineManifests = map (m: {
            name = m.name;
            contents = builtins.readFile m.content;
          }) config.cluster.bootstrapManifests;
        }
      );

    assertions = [
      {
        # talosctl's docker provisioner has no --controlplanes flag: the whole
        # flag set is config-patch, cpus, memory, exposed-ports, host-ip,
        # image, kubernetes-version, mount, subnet and workers. Silently
        # building one control plane while the lab declares three, and then
        # recording three, is what it did before.
        assertion = config.cluster.kubernetes.controlPlanes == 1;
        message =
          "cluster '${config.cluster.name}' declares "
          + "${toString config.cluster.kubernetes.controlPlanes} control planes, but "
          + "Talos in Docker builds exactly one. talosctl's docker provisioner has no "
          + "flag for the count. Set cluster.kubernetes.controlPlanes = 1, or use a "
          + "provisioner that can build a multi-control-plane cluster.";
      }
      {
        # The control plane carries the standard taint, unlike a k3d server
        # node which is schedulable. A lab with no workers has nowhere to run.
        assertion = config.cluster.kubernetes.workers >= 1;
        message =
          "cluster '${config.cluster.name}' declares no workers. A Talos control "
          + "plane keeps the standard NoSchedule taint, so a cluster without workers "
          + "has nowhere to run the lab. Set cluster.kubernetes.workers to at least 1.";
      }
    ];
  };
}
