{
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    mapAttrs
    mapAttrsToList
    filterAttrs
    concatLists
    optionalAttrs
    optionalString
    unique
    ;
  cfg = config.components.cnpg;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # Filter enabled clusters
  enabledClusters = filterAttrs (_: c: c.enable) cfg.clusters;
  hasClusters = enabledClusters != { };

  # Generate CNPG Cluster CRD for each cluster
  clusterResources = mapAttrs (name: cluster: {
    apiVersion = "postgresql.cnpg.io/v1";
    kind = "Cluster";
    metadata = {
      inherit name;
      namespace = cluster.namespace;
    };
    spec = {
      instances = cluster.instances;
      imageName = "ghcr.io/cloudnative-pg/postgresql:${cluster.postgresql.version}";

      storage = {
        size = cluster.storage.size;
        storageClass = cluster.storage.storageClass;
      };

      # Bootstrap configuration
      bootstrap = {
        initdb = {
          database = "app";
          owner = "app";
        }
        // optionalAttrs (cluster.superuserPasswordSecretRef != null) {
          secret = {
            name = cluster.superuserPasswordSecretRef.name;
          };
        };
      };

      # PostgreSQL configuration
      postgresql = {
        parameters = cluster.postgresql.parameters;
      };

      # Monitoring
      monitoring = {
        enablePodMonitor = cluster.monitoring.enable;
      };
    }
    // optionalAttrs cluster.backup.enable {
      backup = {
        retentionPolicy = cluster.backup.retentionPolicy;
      };
    };
  }) enabledClusters;

  # Generate Namespace resources for clusters that want it
  clusterNamespaces = unique (
    mapAttrsToList (_: c: c.namespace) (filterAttrs (_: c: c.createNamespace) enabledClusters)
  );
  namespaceResources = lib.genAttrs clusterNamespaces (ns: {
    apiVersion = "v1";
    kind = "Namespace";
    metadata.name = ns;
  });

  # Generate SQL initialization ConfigMap for databases
  initSqlResources = lib.listToAttrs (
    lib.filter (x: x.value != null) (
      mapAttrsToList (
        clusterName: cluster:
        let
          dbNames = lib.attrNames cluster.databases;
          createDbSql = lib.concatMapStringsSep "\n" (
            dbName:
            let
              db = cluster.databases.${dbName};
            in
            ''
              -- Create user and database: ${dbName}
              DO $$
              BEGIN
                IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db.owner}') THEN
                  CREATE ROLE "${db.owner}" WITH LOGIN;
                END IF;
              END $$;

              SELECT 'CREATE DATABASE "${dbName}" OWNER "${db.owner}"'
              WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${dbName}')\gexec

              ${optionalString (db.extensions != [ ]) (
                lib.concatMapStringsSep "\n" (ext: ''
                  \c ${dbName}
                  CREATE EXTENSION IF NOT EXISTS "${ext}";
                '') db.extensions
              )}
            ''
          ) dbNames;
        in
        {
          name = "${clusterName}-init-sql";
          value =
            if dbNames != [ ] then
              {
                apiVersion = "v1";
                kind = "ConfigMap";
                metadata = {
                  name = "${clusterName}-init-sql";
                  namespace = cluster.namespace;
                };
                data = {
                  "init.sql" = createDbSql;
                };
              }
            else
              null;
        }
      ) enabledClusters
    )
  );

in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.cnpg = {
    enable = mkEnableOption "CloudNativePG operator";

    phase = mkOption {
      type = types.str;
      default = "operators";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "0.22.0";
      description = "CloudNativePG operator chart version";
    };

    namespace = mkOption {
      type = types.str;
      default = "cnpg-system";
      description = "Namespace for the CloudNativePG operator";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.cnpg.chart;
      description = "Custom chart derivation. When null, uses nixhelm default.";
    };

    # Declarative PostgreSQL clusters
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
                  type = types.str;
                  default = "local-path";
                  description = "Storage class for PVCs (e.g., local-path, openebs-hostpath)";
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

              # Superuser password from SOPS-backed secret
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

              # Databases to create
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
                    };
                  }
                );
                default = { };
                description = "Databases to create in this cluster";
              };

              # Backup configuration
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

              # Monitoring
              monitoring = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable Prometheus metrics";
                };
              };

              ref = mkOption {
                type = types.attrs;
                readOnly = true;
                description = "Computed references for this cluster";
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

    # Computed refs
    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for CNPG";
    };
  };

  # =========================================================================
  # PART 2: Computed refs
  # =========================================================================

  # =========================================================================
  # PART 3: Phase ordering
  # =========================================================================

  config = lib.mkMerge [
    {
      components.cnpg.ref = {
        namespace = cfg.namespace;
        # Expose cluster refs for easy access
        clusters = mapAttrs (_: c: c.ref) cfg.clusters;
      };
    }
    (mkIf cfg.enable {
      # =========================================================================
      # PART 4: Phase writer
      # =========================================================================

      phases.${cfg.phase}.bundles.cnpg = {
        # CNPG Operator helm chart
        helmCharts.cnpg = {
          chart = chartRef;
          releaseName = "cnpg";
          namespace = cfg.namespace;
          createNamespace = true;
          values = { };
        };

        # Namespace creation for operator
        createNamespaces = [ cfg.namespace ];
      };

      # CNPG Clusters (deployed in databases phase)
      phases.databases.bundles.cnpg-clusters.resources = mkIf hasClusters (
        # Namespaces for clusters
        namespaceResources
        # Cluster CRDs
        // clusterResources
        # Init SQL ConfigMaps
        // initSqlResources
      );

      # Create namespaces for database clusters
      phases.databases.bundles.cnpg-clusters.createNamespaces = mkIf hasClusters clusterNamespaces;
    })
  ];
}
