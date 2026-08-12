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

  backendOf = storeName: config.lab.secrets.stores.${storeName}.backend or "sops";

  storedOutsideEnv = lib.mapAttrsToList (
    secretName: secret: "${secretName} in store ${secret.store}, backend ${backendOf secret.store}"
  ) (lib.filterAttrs (_: secret: backendOf secret.store != "env") config.lab.secrets.managed);

  envSecretsWithNoFile = lib.optionals (config.lab.secrets.envFile == null) (
    lib.attrNames (
      lib.filterAttrs (_: secret: backendOf secret.store == "env") config.lab.secrets.managed
    )
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
    ++ lib.optional (storedOutsideEnv != [ ]) (
      "these live in a store nothing here can open: ${quote storedOutsideEnv}, and a store only opens with no credentials on the machine when its backend is \"env\""
    )
    ++ lib.optional (envSecretsWithNoFile != [ ]) (
      "${quote envSecretsWithNoFile} take their values from the environment, and the lab names no file that sets them, so point lab.secrets.envFile at one, as a path relative to the flake root"
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
        envFile = mkOption {
          type = types.nullOr types.str;
          description = "File the runner loads before the lab starts, from `lab.secrets.envFile`, relative to the flake root. Null when the lab needs nothing from the environment.";
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
    inherit (config.lab.secrets) envFile;
  };
}
