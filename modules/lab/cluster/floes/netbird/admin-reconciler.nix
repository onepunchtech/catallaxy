{ config, lib, ... }:
let
  cfg = config.floes.netbird;
  nb = import ./lib.nix { inherit lib cfg; };

  inherit (nb)
    apiTokenSecretName
    jwtGroupUuidsSecretName
    adminGroupsJson
    owner
    managedBy
    ;

  catalLib = import ../../../../../lib/util/idempotent-job.nix { inherit lib; };

  netbirdAdminReconcilerScript = builtins.readFile ./scripts/admin-reconciler.sh;

  netbirdAdminReconcilerContainer = {
    name = "reconciler";
    image = cfg.images.bootstrap.ref;
    env = [
      {
        name = "NB_NS";
        value = cfg.namespace;
      }
      {
        name = "NB_URL";
        value = "http://netbird-management.${cfg.namespace}.svc.cluster.local";
      }
      {
        name = "PAT_SECRET";
        value = apiTokenSecretName;
      }
      {
        name = "PAT_KEY";
        value = cfg.operator.apiTokenSecretKey;
      }
      {
        name = "NB_ADMIN_GROUPS_JSON";
        value = adminGroupsJson;
      }
      {
        name = "JWT_GROUP_UUIDS_SECRET";
        value = jwtGroupUuidsSecretName;
      }
    ];
    command = [
      "bash"
      "-c"
    ];
    args = [ netbirdAdminReconcilerScript ];
  };

  netbirdAdminReconcilerPodSpec = {
    serviceAccountName = "netbird-bootstrap";
    restartPolicy = "OnFailure";
    containers = [ netbirdAdminReconcilerContainer ];
  };

  netbirdAdminReconcilerCronJob = {
    netbird-admin-reconciler-cron = {
      apiVersion = "batch/v1";
      kind = "CronJob";
      metadata = {
        name = "netbird-admin-reconciler";
        namespace = cfg.namespace;
        labels = managedBy // {
          "app.kubernetes.io/component" = "netbird-admin-reconciler";
        };
      };
      spec = {
        schedule = "*/2 * * * *";
        concurrencyPolicy = "Forbid";
        successfulJobsHistoryLimit = 1;
        failedJobsHistoryLimit = 3;
        startingDeadlineSeconds = 60;
        jobTemplate = {
          spec = {
            backoffLimit = 2;
            template = {
              metadata.labels = managedBy // {
                "app.kubernetes.io/component" = "netbird-admin-reconciler";
              };
              spec = netbirdAdminReconcilerPodSpec // {

                restartPolicy = "Never";
              };
            };
          };
        };
      };
    };
  };

  netbirdAdminReconcilerJobResources =
    if cfg.operator.enable then
      (catalLib.mkIdempotentJob {
        name = "netbird-admin-reconciler";
        namespace = cfg.namespace;
        contentInputs = {
          adminGroups = adminGroupsJson;
        };
        behaviourVersion = 1;
        podSpec = netbirdAdminReconcilerPodSpec;
      }).resources
      // netbirdAdminReconcilerCronJob
    else
      { };
in
{
  config = lib.mkIf (cfg.enable && cfg.operator.enable) {
    floes.netbird.bundles.netbird-admin-reconciler = {
      inherit owner;
      resources = netbirdAdminReconcilerJobResources;

      requires = [
        "netbird/prechart/ready"
        "netbird/management/ready"
        "netbird/api-key/ready"
      ];
    };
  };
}
