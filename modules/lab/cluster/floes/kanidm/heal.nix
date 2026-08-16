{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkOption mkIf types;

  inherit ((import ../../../../../lib/floe { inherit lib; })) refs;
  waitLib = import ../../../../../lib/util/wait.nix { inherit lib; };
  kanidmCfg = config.floes.kanidm;
  cfg = kanidmCfg.heal;

  secretName = "${kanidmCfg.instanceName}-admin-passwords";
  kanidmSvc = "${kanidmCfg.instanceName}.${kanidmCfg.namespace}.svc.cluster.local";

  script = ''
    set -eu
    log() { echo "[kanidm-admin-heal] $*"; }
    trap 'log "ERROR at line $LINENO"' ERR

    NS='${kanidmCfg.namespace}'
    SECRET='${secretName}'
    URL='https://${kanidmSvc}:8443/v1/auth'

    fetch_pass() {
      kubectl -n "$NS" get secret "$SECRET" \
        -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true
    }

    test_auth() {
      curl -sk -X POST "$URL" \
        -H 'Content-Type: application/json' \
        -d '{"step":{"init":"admin"}}' \
        | grep -q '"denied"' && return 1 || return 0
    }

    for round in 1 2 3; do
      ADMIN_PASS=$(fetch_pass)
      if [ -z "$ADMIN_PASS" ]; then
        log "round $round: Secret empty, sleeping"
        sleep 10
        continue
      fi

      if test_auth; then
        log "round $round: auth healthy; no action needed"
        exit 0
      fi

      log "round $round: kanidm rejects the Secret's password; deleting so kaniop resyncs"
      kubectl -n "$NS" delete secret "$SECRET"

      for i in $(seq 1 60); do
        sleep 5
        NEW_PASS=$(fetch_pass)
        if [ -n "$NEW_PASS" ] && [ "$NEW_PASS" != "$ADMIN_PASS" ]; then
          log "round $round: kaniop regenerated after $((i * 5))s"
          break
        fi
      done
    done

    if test_auth; then
      log "auth healthy after healing"
      exit 0
    fi
    log "auth still failing after 3 rounds; giving up"
    exit 1
  '';

  rbac = {
    kanidm-admin-heal-sa = {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = {
        name = "kanidm-admin-heal";
        namespace = kanidmCfg.namespace;
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };
    };
    kanidm-admin-heal-role = {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = {
        name = "kanidm-admin-heal";
        namespace = kanidmCfg.namespace;
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };
      rules = [
        {
          apiGroups = [ "" ];
          resources = [ "secrets" ];
          resourceNames = [ secretName ];
          verbs = [
            "get"
            "delete"
          ];
        }

        {
          apiGroups = [ "apps" ];
          resources = [ "statefulsets" ];
          resourceNames = [ "${kanidmCfg.instanceName}-default" ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
      ];
    };
    kanidm-admin-heal-rb = {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = {
        name = "kanidm-admin-heal";
        namespace = kanidmCfg.namespace;
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "kanidm-admin-heal";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "kanidm-admin-heal";
          namespace = kanidmCfg.namespace;
        }
      ];
    };
  };

  waitForKanidm = waitLib.mkWaitInitContainer {
    name = "wait-for-kanidm";
    probe = {

      kind = "jsonpath";
      resource = "statefulset/${kanidmCfg.instanceName}-default";
      namespace = kanidmCfg.namespace;
      jsonpath = "{.status.readyReplicas}";
      value = 1;
      timeout = "15m";
    };
  };

  waitForSecret = waitLib.mkWaitInitContainer {
    name = "wait-for-admin-passwords";
    probe = {
      kind = "exists";
      resource = "secret/${secretName}";
      namespace = kanidmCfg.namespace;
      timeout = "15m";
    };
  };

  podSpec = {
    serviceAccountName = "kanidm-admin-heal";
    restartPolicy = "OnFailure";
    initContainers = [
      waitForKanidm
      waitForSecret
    ];
    containers = [
      {
        name = "heal";
        image = kanidmCfg.images.heal.ref;
        command = [
          "bash"
          "-c"
          script
        ];
      }
    ];
  };

  bootstrapJob =
    let
      idem = import ../../../../../lib/util/idempotent-job.nix { inherit lib; };
    in
    idem.mkIdempotentJob {
      name = "kanidm-admin-heal-bootstrap";
      namespace = kanidmCfg.namespace;
      contentInputs = {
        inherit script;
        image = kanidmCfg.images.heal.ref;
        secretName = secretName;
        kanidmSvc = kanidmSvc;
      };
      podSpec = podSpec // {

        restartPolicy = "OnFailure";
      };
    };
  bootstrapJobResource = bootstrapJob.resources;

  cronJobResource = {
    kanidm-admin-heal = {
      apiVersion = "batch/v1";
      kind = "CronJob";
      metadata = {
        name = "kanidm-admin-heal";
        namespace = kanidmCfg.namespace;
        labels = {
          "app.kubernetes.io/managed-by" = "catallaxy";
          "app.kubernetes.io/component" = "kanidm-admin-heal";
        };
      };
      spec = {
        schedule = cfg.schedule;

        concurrencyPolicy = "Forbid";
        successfulJobsHistoryLimit = 1;
        failedJobsHistoryLimit = 3;

        startingDeadlineSeconds = 60;
        jobTemplate = {
          spec = {
            backoffLimit = 2;
            template = {
              metadata.labels = {
                "app.kubernetes.io/managed-by" = "catallaxy";
                "app.kubernetes.io/component" = "kanidm-admin-heal";
              };
              spec = podSpec;
            };
          };
        };
      };
    };
  };
in
{

  options.floes.kanidm.heal = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Emit a self-healing CronJob that corrects the kaniop admin-
        credential drift: kaniop 0.11.x periodically ends up with
        an admin-passwords Secret whose values kanidm's DB no longer
        recognises. The Job detects that state via an auth probe
        and deletes the Secret so kaniop regenerates it against a
        running kanidm. Set to false when supplying admin passwords
        through a different mechanism.
      '';
    };
    schedule = mkOption {
      type = types.str;
      default = "*/2 * * * *";
      description = ''
        CronJob schedule (kubernetes spec). Default: every 2 minutes
          bootstrap synchronization is handled by the
        `kanidm-admin-heal-bootstrap` one-shot Job in the same
        phase (blocks kapp on Complete), so this CronJob is purely
        for POST-bootstrap drift detection. 2m keeps the drift
        window narrow without meaningful churn (the script
        short-circuits on healthy auth). Extend to `*/10 * * * *`
        for large labs where drift is rare and node load matters.
      '';
    };
  };

  config = mkIf (kanidmCfg.enable && cfg.enable) {
    floes.kanidm.images.heal = {
      repository = "alpine/k8s";
      tag = "1.32.4";
    };

    bundles.kanidm-admin-heal = {
      resources = rbac // bootstrapJobResource // cronJobResource;

      requires = [
        "kanidm/instance/ready"
      ]
      ++ refs.needs (config.floes.kaniop.exports.operator or null) "ready";
    };
  };
}
