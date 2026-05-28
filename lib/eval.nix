{ lib, pkgs }:

let
  # Base modules that every cluster gets
  baseModules = [
    ../modules
  ];

  evalCluster =
    {
      modules ? [ ],
      extraArgs ? { },
    }:
    lib.evalModules {
      modules = baseModules ++ modules;
      specialArgs = {
        inherit lib pkgs;
      }
      // extraArgs;
    };

  # Convenience wrapper: evaluate and return just the config, checking assertions
  evalClusterConfig =
    args:
    let
      config = (evalCluster args).config;
      failedAssertions = builtins.filter (a: !a.assertion) config.assertions;
    in
    if failedAssertions != [ ] then
      throw (lib.concatStringsSep "\n" (map (a: "Assertion failed: ${a.message}") failedAssertions))
    else
      config;

  # Convert an already-evaluated cluster config to JSON-friendly format.
  # Separated from evalClusterJSON so it can be reused by lab evaluation.
  clusterConfigToJSON = config: {
    inherit (config.cluster) name provider provisioner;
    kubernetes = config.cluster.kubernetes;
    talos = config.cluster.talos;
    network = config.cluster.network;
    components = lib.mapAttrs (
      name: component:
      if name == "cluster-api" then
        {
          enable = component.enable or false;
          version = component.version or null;
          isManagementCluster = component.isManagementCluster or false;
          namespace = component.namespace or "capi-system";
          infrastructureProviders = component.infrastructureProviders or [ ];
          bootstrapProviders = component.bootstrapProviders or [ "talos" ];
          controlPlaneProviders = component.controlPlaneProviders or [ "talos" ];
          providerVersions = component.providerVersions or { };
          clusters = lib.mapAttrs (clusterName: cluster: {
            enable = cluster.enable or true;
            infrastructureProvider = cluster.infrastructureProvider or null;
            kubernetes = {
              version = cluster.kubernetes.version or "v1.31.0";
              controlPlane.replicas = cluster.kubernetes.controlPlane.replicas or 3;
              workers = map (w: {
                name = w.name;
                replicas = w.replicas or 3;
              }) (cluster.kubernetes.workers or [ ]);
            };
            talos = {
              enable = cluster.talos.enable or true;
              version = cluster.talos.version or "v1.8.0";
            };
            network = {
              podCIDR = cluster.network.podCIDR or "10.244.0.0/16";
              serviceCIDR = cluster.network.serviceCIDR or "10.96.0.0/12";
            };
            apiServerExtraArgs = cluster.apiServerExtraArgs or { };
          }) (component.clusters or { });
        }
      else if name == "velero" then
        {
          enable = component.enable or false;
          version = component.version or null;
          namespace = component.namespace or "velero";
          local = {
            enable = component.local.enable or false;
          };
          backupStorageLocation = {
            provider = component.backupStorageLocation.provider or "seaweedfs";
            bucket = component.backupStorageLocation.bucket or "velero-backups";
          };
          fileSystemBackup = {
            enable = component.fileSystemBackup.enable or true;
          };
        }
      else if name == "pki-auth" then
        {
          enable = component.enable or false;
          ca = component.ca or { };
          defaults = component.defaults or { };
          users = lib.mapAttrs (uname: user: {
            commonName = user.commonName or "";
            organizations = user.organizations or [ ];
            validity = user.validity or null;
            keyAlgorithm = user.keyAlgorithm or null;
            yubikey = {
              serialNumber = user.yubikey.serialNumber or null;
              slot = user.yubikey.slot or "9a";
              touchPolicy = user.yubikey.touchPolicy or "always";
              pinPolicy = user.yubikey.pinPolicy or "once";
            };
          }) (component.users or { });
          rbac = component.rbac or { };
          ref = component.ref or { };
        }
      else
        {
          enable = component.enable or false;
          version = component.version or null;
        }
    ) config.components;
    provisionerConfig = {
      docker = {
        clusterName = config.provisioner.docker.clusterName or "";
        waitTimeout = config.provisioner.docker.waitTimeout or "10m";
        colima = config.provisioner.docker.colima or { };
      };
      k3d = {
        clusterName = config.provisioner.k3d.clusterName or "";
        image = config.provisioner.k3d.image or null;
        noTraefik = config.provisioner.k3d.noTraefik or true;
        noServiceLB = config.provisioner.k3d.noServiceLB or true;
        noFlannel = config.provisioner.k3d.noFlannel or true;
        network = config.provisioner.k3d.network or null;
        extraApiServerArgs = config.provisioner.k3d.extraApiServerArgs or [ ];
        extraVolumes = config.provisioner.k3d.extraVolumes or [ ];
        autoDeployManifests = map (m: {
          name = m.name;
          path = toString m.content;
        }) (config.provisioner.k3d.autoDeployManifests or [ ]);
      };
    };
    deploy =
      if config ? deploy then
        {
          inherit (config.deploy) strategy;
          kapp = config.deploy.kapp;
          argocd = config.deploy.argocd;
          fleet = config.deploy.fleet;
        }
      else
        {
          strategy = "kapp";
          kapp = { };
          argocd = { };
          fleet = { };
        };
    phases =
      let
        deployPhases = (config.deploy or { }).phases or { };

        # Collect enabled components and their phase assignments
        componentPhases = lib.concatLists (
          lib.mapAttrsToList (
            name: component:
            if (component.enable or false) then
              [
                {
                  inherit name;
                  phase = component.phase or "workloads";
                }
              ]
            else
              [ ]
          ) config.components
        );

        # Provisioners with phase support (crossplane)
        provisionerPhases = lib.optional (config.cluster.provisioner == "crossplane") {
          name = "crossplane";
          phase = config.provisioner.crossplane.phase or "infrastructure";
        };

        # Resource sets
        resourcePhases = lib.mapAttrsToList (name: rset: {
          name = "resources-${name}";
          phase = rset.phase;
        }) (config.resources or { });

        # CRDs are all applied in the dedicated `crds` phase — not per-phase apps

        composePhases = lib.mapAttrsToList (name: svc: {
          inherit name;
          phase = svc.phase;
        }) (config.compose or { });

        secretPhases = lib.mapAttrsToList (name: sec: {
          name = "secrets-${name}";
          phase = sec.phase;
        }) ((config.secrets or { }).managed or { });

        pgPhases = lib.mapAttrsToList (name: pg: {
          name = "pg-${name}";
          phase = pg.phase;
        }) ((config.databases or { }).postgres or { });
        redisPhases = lib.mapAttrsToList (name: redis: {
          name = "redis-${name}";
          phase = redis.phase;
        }) ((config.databases or { }).redis or { });

        allComponentPhases =
          componentPhases
          ++ provisionerPhases
          ++ resourcePhases
          ++ composePhases
          ++ secretPhases
          ++ pgPhases
          ++ redisPhases;
      in
      lib.mapAttrs (
        phaseName: phaseCfg:
        let
          autoApps = map (c: c.name) (builtins.filter (c: c.phase == phaseName) allComponentPhases);
          allApps = lib.unique (autoApps ++ (phaseCfg.components or [ ]));
        in
        {
          order = phaseCfg.order or 0;
          dependsOn = phaseCfg.dependsOn or [ ];
          keepResources = phaseCfg.keepResources or false;
          pruneStrategy = phaseCfg.pruneStrategy or "default";
          waitForCRDs = phaseCfg.waitForCRDs or false;
          waitForReady = phaseCfg.waitForReady or true;
          timeout = phaseCfg.timeout or "10m";
          crdNames = phaseCfg.crdNames or [ ];
          apps = allApps;
        }
      ) deployPhases;
    resources = lib.mapAttrs (name: rset: {
      inherit (rset) phase namespace;
      appName = "resources-${name}";
    }) (config.resources or { });
    crds = lib.mapAttrs (name: crd: {
      inherit (crd) waitForEstablished crdNames;
      paths = map toString crd.source.paths;
    }) (lib.filterAttrs (_: crd: crd.enable) (config.crds or { }));
    compose = lib.mapAttrs (name: svc: {
      inherit (svc)
        phase
        namespace
        image
        replicas
        ;
      ref = svc.ref;
    }) (config.compose or { });
    # Projections: how managed secrets map to K8s Secrets in this cluster
    projections = lib.mapAttrs (name: proj: {
      inherit (proj) source namespace phase;
      keys = lib.mapAttrs (kname: key: {
        inherit (key) from transform;
        jsonKey = key.jsonKey or null;
      }) proj.keys;
    }) ((config.secrets or { }).projections or { });
    # Legacy: keep old secrets field for backward compat
    secrets = lib.mapAttrs (name: sec: {
      namespace = sec.namespace or "default";
      phase = sec.phase or "secrets";
      backend = sec.backend or "sops";
    }) ((config.secrets or { }).managed or { });
    databases = {
      postgres = lib.mapAttrs (name: pg: {
        inherit (pg)
          phase
          namespace
          instances
          database
          ;
        ref = pg.ref;
      }) ((config.databases or { }).postgres or { });
      redis = lib.mapAttrs (name: redis: {
        inherit (redis)
          phase
          namespace
          mode
          replicas
          auth
          ;
        ref = redis.ref;
      }) ((config.databases or { }).redis or { });
    };
    storage = {
      s3Buckets = lib.mapAttrs (name: bucket: {
        inherit (bucket) provider phase acl;
        ref = bucket.ref;
      }) ((config.storage or { }).s3Buckets or { });
    };
    outputs = config.cluster.out;
    lifecycle = {
      teardown = map (step: {
        inherit (step) name description order waitTimeout;
        bin = "${step.package}/bin/${step.name}";
      }) (lib.sort (a: b: a.order < b.order) (config.lifecycle.teardown or [ ]));
    };
  };

  # Evaluate cluster and convert to JSON-friendly format
  # Used by the CLI to get cluster configuration and interpreter outputs
  evalClusterJSON = args: clusterConfigToJSON (evalClusterConfig args);

in
{
  inherit
    evalCluster
    evalClusterConfig
    evalClusterJSON
    clusterConfigToJSON
    ;
  inherit baseModules;
}
