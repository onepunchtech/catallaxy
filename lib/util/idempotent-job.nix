{ lib }:

rec {

  hashContent = inputs: lib.substring 0 10 (builtins.hashString "sha256" (builtins.toJSON inputs));

  mkIdempotentJob =
    {
      name,
      namespace,
      contentInputs,
      podSpec,

      extraLabels ? { },

      argoCDSyncWave ? "10",

      jobAnnotations ? { },
    }:
    let
      hash = hashContent {
        inherit contentInputs podSpec;
      };
      jobName = "${name}-${hash}";
      ownerName = "${name}-runs";

      commonLabels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
        "app.kubernetes.io/component" = name;
        "catallaxy.io/idempotent-job" = "true";
      }
      // extraLabels;

      ownerConfigMap = {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = {
          name = ownerName;
          inherit namespace;
          labels = commonLabels;
          annotations = {

            "catallaxy.io/description" = "Owns every generation of the ${name} bootstrap Job.";
          };
        };

        data."${hash}" = "applied";
      };

      job = {
        apiVersion = "batch/v1";
        kind = "Job";
        metadata = {
          name = jobName;
          inherit namespace;
          labels = commonLabels // {
            "catallaxy.io/idempotent-job-hash" = hash;
          };
          annotations = {

            "argocd.argoproj.io/sync-wave" = argoCDSyncWave;

            "kapp.k14s.io/update-strategy" = "fallback-on-replace";

          }
          // jobAnnotations;

        };
        spec = {

          backoffLimit = 20;
          template = {
            metadata.labels = commonLabels // {
              "catallaxy.io/idempotent-job-hash" = hash;
            };
            spec = podSpec;
          };
        };
      };
    in
    {
      inherit hash;
      name = jobName;
      resources = {

        "${ownerName}" = ownerConfigMap;
        "${jobName}" = job;
      };
    };
}
