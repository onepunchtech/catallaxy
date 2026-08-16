{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
in
(mkFloe {
  name = "cnpg";
  exports =
    { lib, ... }:
    {
      operator = lib.mkOption {
        type = refs.mkCapability {
          ready = refs.tokenOption ''"The CloudNativePG operator is running and will reconcile Cluster CRs."'';
        };
        default = null;
        description = ''
          Postgres cluster reconciliation, or null when this floe is
          off. Consumers whose database is a cnpg `Cluster` gate on
          this rather than naming `cnpg/operator/ready`.
        '';
      };
    };
  version = "0.22.0";
  imports = [ ./options.nix ];
  module =
    {
      lib,
      cfg,
      ...
    }:
    let
      inherit (lib)
        mapAttrs
        mapAttrsToList
        filterAttrs
        concatLists
        optionalAttrs
        optionalString
        unique
        ;

      enabledClusters = filterAttrs (_: c: c.enable) cfg.clusters;
      hasClusters = enabledClusters != { };

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
          }
          // optionalAttrs (cluster.storage.storageClass != null) {
            storageClass = cluster.storage.storageClass;
          };

          bootstrap = {
            initdb =
              let
                dbNames = lib.attrNames cluster.databases;
                firstName = if dbNames != [ ] then lib.head dbNames else null;
                firstDb = if firstName != null then cluster.databases.${firstName} else null;
              in
              (
                if firstDb != null then
                  {
                    database = firstName;
                    owner = firstDb.owner;
                  }
                else
                  {
                    database = "app";
                    owner = "app";
                  }
              )
              // optionalAttrs (cluster.superuserPasswordSecretRef != null) {
                secret = {
                  name = cluster.superuserPasswordSecretRef.name;
                };
              };
          };

          postgresql = {
            parameters = cluster.postgresql.parameters;
          };

          monitoring = {
            enablePodMonitor = cluster.monitoring.enable;
          };
        }
        // optionalAttrs cluster.backup.enable {
          backup = {
            retentionPolicy = cluster.backup.retentionPolicy;
          };
        }
        // (

          let
            schemaOwners = unique (
              mapAttrsToList (_: db: db.owner) (filterAttrs (_: db: db.schema != null) cluster.databases)
            );
          in
          optionalAttrs (schemaOwners != [ ]) {
            managed.roles = map (owner: {
              name = owner;
              ensure = "present";
              login = true;
              createdb = true;
            }) schemaOwners;
          }
        );
      }) enabledClusters;

      clusterNamespaces = unique (
        mapAttrsToList (_: c: c.namespace) (filterAttrs (_: c: c.createNamespace) enabledClusters)
      );
      namespaceResources = lib.genAttrs clusterNamespaces (ns: {
        apiVersion = "v1";
        kind = "Namespace";
        metadata.name = ns;
      });

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

      schemaReconcilerResources = lib.listToAttrs (
        concatLists (
          mapAttrsToList (
            clusterName: cluster:
            let
              dbsWithSchema = filterAttrs (_: db: db.schema != null) cluster.databases;
            in
            mapAttrsToList (
              dbName: db:
              let
                name = "${clusterName}-${dbName}-schema";
              in
              {
                inherit name;
                value = {
                  apiVersion = "apps/v1";
                  kind = "Deployment";
                  metadata = {
                    inherit name;
                    namespace = cluster.namespace;
                    labels = {
                      "app.kubernetes.io/managed-by" = "catallaxy";
                      "app.kubernetes.io/name" = name;
                      "app.kubernetes.io/component" = "schema-reconciler";
                    };
                  };
                  spec = {
                    replicas = 1;
                    strategy.type = "Recreate";
                    selector.matchLabels."app.kubernetes.io/name" = name;
                    template = {
                      metadata.labels."app.kubernetes.io/name" = name;
                      spec = {
                        restartPolicy = "Always";
                        imagePullSecrets = map (n: { name = n; }) db.schema.imagePullSecrets;
                        containers = [
                          {
                            name = "reconcile";
                            image = db.schema.image;
                            imagePullPolicy = "IfNotPresent";
                            env = [
                              {
                                name = "DATABASE_URL";
                                valueFrom.secretKeyRef = {
                                  name = "${clusterName}-app";
                                  key = "uri";
                                };
                              }
                              {
                                name = "RECONCILE_INTERVAL";
                                value = toString db.schema.reconcileInterval;
                              }
                              {
                                name = "ALLOW_HAZARDS";
                                value = lib.concatStringsSep "," db.schema.allowHazards;
                              }
                            ]
                            ++ db.schema.extraEnv;
                            resources = db.schema.resources;
                          }
                        ];
                      };
                    };
                  };
                };
              }
            ) dbsWithSchema
          ) enabledClusters
        )
      );
    in
    {
      floes.cnpg.exports.operator.ready = "cnpg/operator/ready";

      floes.cnpg.network = {

        declared = true;

        serves.webhook = {

          port = 443;

          fromApiServer = true;

        };

      };

      floes.cnpg.imagesComplete = true;

      floes.cnpg.images.operator = {

        registry = "ghcr.io";

        repository = "cloudnative-pg/cloudnative-pg";

        tag = "1.25.0";

      };

      bundles.cnpg = {

        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        includeInBootstrap = false;
        helmCharts.cnpg = {
          chart = cfg.chart;
          releaseName = "cnpg";
          namespace = cfg.namespace;
          createNamespace = true;
          values = { };
        };
        createNamespaces = [ cfg.namespace ];

        provides = [ "cnpg/operator/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/cnpg-cloudnative-pg";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };

      bundles.cnpg-clusters.owner = {

        bootstrap = "install-target";
        steady = "argocd";
      };
      bundles.cnpg-clusters.resources =
        if hasClusters then clusterResources // initSqlResources // schemaReconcilerResources else { };

      bundles.cnpg-clusters.createNamespaces = if hasClusters then clusterNamespaces else [ ];

      bundles.cnpg-clusters.requires = [
        "cnpg/operator/ready"
      ];
    };
})
  __floeModuleArgs
