{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkOption types;

  localProvisioners = [ "k3d" ];

  clusters = config.lab.out.allClusters;

  nonLocalClusters = lib.attrNames (
    lib.filterAttrs (_: c: !(builtins.elem c.cluster.provisioner localProvisioners)) clusters
  );

  provisioningClusters = lib.attrNames (lib.filterAttrs (_: c: c.cluster.provisions != { }) clusters);

  sopsStores = lib.attrNames (
    lib.filterAttrs (_: store: store.backend == "sops") config.lab.secrets.stores
  );

  inSopsStore = secret: builtins.elem secret.store sopsStores;

  handWrittenKeys = lib.concatLists (
    lib.mapAttrsToList (
      secretName: secret:
      lib.optionals (inSopsStore secret) (
        lib.optional (secret.kind == "ca") "${secretName} is a CA, which an ops command mints"
        ++ map (keyName: "${secretName}.${keyName} has no generator, so somebody types it in") (
          lib.attrNames (lib.filterAttrs (_: key: key.generator == null) secret.keys)
        )
      )
    ) config.lab.secrets.managed
  );

  interactiveSteps = map (s: s.name) (
    lib.filter (s: s.policy.interactive) config.lab.out.deploymentPlan
  );

  quote = names: lib.concatStringsSep ", " names;

  reasons =
    lib.optional (clusters == { }) "the lab declares no clusters"
    ++ lib.optional (nonLocalClusters != [ ]) (
      "${quote nonLocalClusters} is not provisioned by k3d, so standing it up needs an account somewhere"
    )
    ++ lib.optional (provisioningClusters != [ ]) (
      "${quote provisioningClusters} provisions further clusters, which happens off this machine"
    )
    ++ lib.optional (handWrittenKeys != [ ]) (
      "these hold material nothing can generate: ${quote handWrittenKeys}"
    )
    ++ lib.optional (interactiveSteps != [ ]) (
      "step ${quote interactiveSteps} cannot finish without a human"
    );
in
{
  options.lab.out.selfContained = mkOption {
    readOnly = true;
    internal = true;
    type = types.submodule {
      options = {
        eligible = mkOption {
          type = types.bool;
          description = "True when nothing stands between this lab and a machine with docker on it.";
        };
        reasons = mkOption {
          type = types.listOf types.str;
          description = "What does stand in the way, one sentence each. Empty exactly when `eligible`.";
        };
      };
    };
    description = ''
      Whether this lab can be stood up start to finish on one machine
      with nothing but docker, and if not, why. Derived rather than
      declared, so a lab that grows a cloud cluster or a sops store
      leaves the CI matrix on its own and one that loses them rejoins it.

      `reasons` is empty exactly when `eligible` is true, and is what CI
      prints for a lab it skipped.
    '';
  };

  config.lab.out.selfContained = {
    eligible = reasons == [ ];
    inherit reasons;
  };
}
