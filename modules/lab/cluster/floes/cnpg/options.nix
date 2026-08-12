{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkDefault types;
in
{

  config.floes.cnpg.namespace = mkDefault "cnpg-system";

  options.floes.cnpg = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.cnpg.chart;
      description = "Custom chart derivation. When null, uses nixhelm default.";
    };

    clusters = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, config, ... }:
          {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Enable this PostgreSQL cluster";
              };

              namespace = mkOption {
                type = types.str;
                default = "databases";
                description = "Namespace for this cluster";
              };

              createNamespace = mkOption {
                type = types.bool;
                default = true;
                description = "Whether to create the namespace (set to false if another app manages it)";
              };

              instances = mkOption {
                type = types.ints.positive;
                default = 1;
                description = "Number of PostgreSQL instances (replicas)";
              };

              storage = {
                size = mkOption {
                  type = types.str;
                  default = "10Gi";
                  description = "PVC size for each instance";
                };

                storageClass = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Storage class for PVCs. Null uses the cluster default.";
                };
              };

              postgresql = {
                version = mkOption {
                  type = types.str;
                  default = "16";
                  description = "PostgreSQL major version";
                };

                parameters = mkOption {
                  type = types.attrsOf types.str;
                  default = { };
                  description = "PostgreSQL configuration parameters";
                };
              };

              superuserPasswordSecretRef = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      name = mkOption {
                        type = types.str;
                        description = "Secret name containing superuser password";
                      };
                      key = mkOption {
                        type = types.str;
                        default = "password";
                        description = "Key within the secret";
                      };
                    };
                  }
                );
                default = null;
                description = "Reference to Secret containing superuser password for bootstrap";
              };

              databases = mkOption {
                type = types.attrsOf (
                  types.submodule {
                    options = {
                      owner = mkOption {
                        type = types.str;
                        description = "Database owner username";
                      };

                      userPasswordSecretRef = mkOption {
                        type = types.nullOr (
                          types.submodule {
                            options = {
                              name = mkOption {
                                type = types.str;
                                description = "Secret containing user password";
                              };
                              key = mkOption {
                                type = types.str;
                                default = "password";
                                description = "Key within the secret";
                              };
                            };
                          }
                        );
                        default = null;
                        description = "Reference to Secret containing the database user's password";
                      };

                      extensions = mkOption {
                        type = types.listOf types.str;
                        default = [ ];
                        description = "PostgreSQL extensions to enable for this database";
                      };

                      schema = mkOption {
                        type = types.nullOr (
                          types.submodule {
                            options = {
                              image = mkOption {
                                type = types.str;
                                description = ''
                                  Image bundling `pg-schema-diff`, the desired
                                  schema file, and a loop entrypoint that
                                  exits cleanly on failure (the Deployment
                                  restarts). Expected env vars consumed by
                                  the entrypoint: DATABASE_URL,
                                  RECONCILE_INTERVAL, ALLOW_HAZARDS.
                                '';
                              };

                              reconcileInterval = mkOption {
                                type = types.int;
                                default = 86400;
                                description = ''
                                  Seconds between reconciliations. Default is
                                  one day: schema applies are idempotent
                                  no-ops at steady state, so the loop exists
                                  primarily for drift healing; frequent ticks
                                  are wasteful. New schema versions land via
                                  Deployment rollout, not the timer.
                                '';
                              };

                              allowHazards = mkOption {
                                type = types.listOf types.str;
                                default = [ ];
                                example = [
                                  "ACQUIRES_ACCESS_EXCLUSIVE_LOCK"
                                  "INDEX_DROPPED"
                                ];
                                description = ''
                                  pg-schema-diff hazard names to allow. Passed
                                  to the entrypoint as the comma-separated env
                                  var ALLOW_HAZARDS. Without this, the apply
                                  refuses destructive or lock-heavy migrations.
                                '';
                              };

                              imagePullSecrets = mkOption {
                                type = types.listOf types.str;
                                default = [ ];
                                description = ''
                                  Names of dockerconfigjson Secrets in the
                                  database's namespace to use for pulling
                                  the schema image. Required when the image
                                  lives in a private registry.
                                '';
                              };

                              resources = mkOption {
                                type = types.attrs;
                                default = {
                                  requests = {
                                    cpu = "10m";
                                    memory = "32Mi";
                                  };
                                  limits = {
                                    cpu = "200m";
                                    memory = "128Mi";
                                  };
                                };
                                description = "Pod resource requests/limits. Reconciler is mostly idle.";
                              };

                              extraEnv = mkOption {
                                type = types.listOf types.attrs;
                                default = [ ];
                                example = [
                                  {
                                    name = "RECONCILE_FAIL_INTERVAL_INITIAL";
                                    value = "2";
                                  }
                                  {
                                    name = "RECONCILE_FAIL_INTERVAL_MAX";
                                    value = "60";
                                  }
                                ];
                                description = ''
                                  Extra environment variables appended to the
                                  reconciler container. Pass raw EnvVar objects
                                  (with `name`, `value` or `valueFrom`). Useful
                                  for tuning loop behavior (e.g. failure backoff
                                  bounds) or wiring image-specific knobs.
                                '';
                              };
                            };
                          }
                        );
                        default = null;
                        description = ''
                          When set, declares a "poor man's operator"
                          Deployment that owns this database's schema
                          lifecycle. See option fields for details.
                        '';
                      };
                    };
                  }
                );
                default = { };
                description = "Databases to create in this cluster";
              };

              backup = {
                enable = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Enable automated backups";
                };

                schedule = mkOption {
                  type = types.str;
                  default = "0 0 * * *";
                  description = "Cron schedule for backups";
                };

                retentionPolicy = mkOption {
                  type = types.str;
                  default = "30d";
                  description = "Backup retention policy";
                };
              };

              monitoring = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable Prometheus metrics";
                };
              };

              ref = mkOption {
                readOnly = true;
                description = "Computed references for this cluster";
                type = types.submodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      default = "";
                      description = "Cluster name (echoes the attribute key).";
                    };
                    namespace = mkOption {
                      type = types.str;
                      default = "";
                      description = "Namespace the cluster runs in.";
                    };
                    host = mkOption {
                      type = types.str;
                      default = "";
                      description = "In-cluster DNS name of the read-write Service.";
                    };
                    roHost = mkOption {
                      type = types.str;
                      default = "";
                      description = "In-cluster DNS name of the read-only Service.";
                    };
                    port = mkOption {
                      type = types.port;
                      default = 5432;
                      description = "PostgreSQL port.";
                    };
                    url = mkOption {
                      type = types.str;
                      default = "";
                      description = "postgres:// URL pointing at the read-write Service.";
                    };
                    roUrl = mkOption {
                      type = types.str;
                      default = "";
                      description = "postgres:// URL pointing at the read-only Service.";
                    };
                    secretName = mkOption {
                      type = types.str;
                      default = "";
                      description = ''
                        Name of the app-role Secret CNPG generates
                        (contains `uri`, `username`, `password`, `host`,
                        `port`, `dbname`).
                      '';
                    };
                    superuserSecretName = mkOption {
                      type = types.str;
                      default = "";
                      description = "Name of the superuser Secret CNPG generates.";
                    };
                  };
                };
              };
            };

            config.ref =
              let
                clusterName = name;
                clusterNamespace = config.namespace;
                host = "${clusterName}-rw.${clusterNamespace}.svc.cluster.local";
                roHost = "${clusterName}-ro.${clusterNamespace}.svc.cluster.local";
              in
              {
                inherit host roHost;
                name = clusterName;
                namespace = clusterNamespace;
                port = 5432;
                url = "postgresql://${host}:5432";
                roUrl = "postgresql://${roHost}:5432";
                secretName = "${clusterName}-app";
                superuserSecretName = "${clusterName}-superuser";
              };
          }
        )
      );
      default = { };
      description = "Declarative PostgreSQL clusters managed by CNPG";
    };
  };
}
