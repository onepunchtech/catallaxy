{ lib }:

let
  inherit (lib)
    concatMap
    filter
    mapAttrs'
    mapAttrsToList
    mergeAttrsList
    nameValuePair
    optional
    optionalAttrs
    optionals
    unique
    ;
  tokens = import ../plan-tokens.nix { inherit lib; };
  inherit (tokens) needs wants wantsKind;
in
{
  mkSteps =
    {
      cfg,
      config,
      graph,
    }:
    let
      inherit (graph)
        allClusters
        localClusters
        provisionerGraph
        syncedContextClusterNames
        syncedContextFor
        ;

      labProxyTls = (cfg.out.cliConfig.services ? proxy) && (cfg.proxy.tls.enable or true);

      isSelfProvisioning =
        let
          names = map (e: e.source.name) (filter (e: e.isSelfProvisioning) provisionerGraph);
        in
        c: builtins.elem c.name names;

      runtimeCtxOf =
        c:
        let
          synced = syncedContextFor c.name;
        in
        if synced != null then synced else c.config.cluster.ref.kubeContext;

      gatewayOf =
        subnet:
        let
          base = lib.head (lib.splitString "/" subnet);
          parts = lib.splitString "." base;
        in
        if lib.length parts != 4 then
          throw ''
            lab.network.dockerSubnet = '${subnet}' is not a dotted-quad CIDR.
            The docker bridge gateway is the address after the subnet's first,
            so there is nothing to derive it from.
          ''
        else
          "${lib.elemAt parts 0}.${lib.elemAt parts 1}.${lib.elemAt parts 2}.${
            builtins.toString (lib.toInt (lib.elemAt parts 3) + 1)
          }";

      labScopeSteps = mergeAttrsList [

        (optionalAttrs (localClusters != [ ]) (
          {
            docker-network-create = {
              kind = "docker-network-create";
              provides = [ tokens.lab.network ];

              after = [ (wants tokens.lab.preflightOk) ];
              before = [
                (wants tokens.lab.services)
              ]
              ++ (map (c: wants (tokens.cluster c.name).created) localClusters);
              params = {
                name = cfg.name;
                subnet = cfg.network.dockerSubnet or "172.19.0.0/16";
                gateway = gatewayOf (cfg.network.dockerSubnet or "172.19.0.0/16");
              };
              description = "Create docker bridge network '${cfg.name}'";
            };
          }
          // optionalAttrs cfg.network.configureHostRoute {
            colima-network-route = {
              kind = "colima-network-route";
              provides = [ tokens.lab.hostNetwork ];
              after = [ (needs tokens.lab.network) ];

              before = [ (wants tokens.lab.services) ];
              params = {
                subnet = cfg.network.dockerSubnet or "172.19.0.0/16";
                profile =
                  let
                    first = builtins.head localClusters;
                  in
                  first.config.cluster.provisionerConfig.docker.colima.profile or "catallaxy";
              };
              description = "Route lab subnet through Colima VM (macOS only)";
            };
          }
        ))

        (optionalAttrs (labProxyTls) {
          cert-generate = {
            kind = "cert-generate";
            provides = [ tokens.lab.ingressCa ];
            after = [ (wants tokens.lab.preflightOk) ];

            before = [
              (wants tokens.lab.services)
              (wants tokens.lab.hostTrust)
            ]
            ++ (map (c: wants (tokens.cluster c.name).created) localClusters);
            params.zone = cfg.dns.zone or "lab.test";
            description = "Mint ingress TLS keypair for '*.${cfg.dns.zone or "lab.test"}'";
          };
        })

        (optionalAttrs
          (
            labProxyTls || (lib.filterAttrs (_: ms: ms.kind or "" == "ca") (cfg.secrets.managed or { })) != { }
          )
          (
            {
              trust-bundle = {
                kind = "trust-bundle";
                requires = lib.optional labProxyTls tokens.lab.ingressCa;
                provides = [ tokens.lab.hostTrust ];

                before = [
                  (wants tokens.lab.services)
                  (wantsKind "publish-images")
                  (wantsKind "publish-manifests")
                ];
                description = "Build the lab CA trust bundle for spawned tools";
              };
            }

            // lib.optionalAttrs (cfg.trust.installIntoHostStore or false) {
              host-trust-install = {
                kind = "host-trust-install";
                requires = [ tokens.lab.hostTrust ];
                provides = [ tokens.lab.hostTrustOs ];
                before = [
                  (wantsKind "publish-images")
                  (wantsKind "publish-manifests")
                ];
                description = "Install the lab CA into the host OS trust store";
              };
            }
          )
        )

        (optionalAttrs (cfg.dns.configureHost && cfg.out.cliConfig.dnsInfo != null) {
          dns-setup = {
            kind = "dns-setup";
            provides = [ tokens.lab.hostDns ];
            after = [ (wants tokens.lab.services) ];
            before = [
              (wantsKind "publish-images")
              (wantsKind "publish-manifests")
            ];
            params = {
              host = cfg.out.cliConfig.dnsInfo.host;
              port = cfg.out.cliConfig.dnsInfo.port;
              zone = cfg.dns.zone;
            };
            description = "Point host DNS for '${cfg.dns.zone}' at lab coredns";
          };
        })

        (optionalAttrs (cfg.registry.enable && (cfg.dns.zone or null) != null) {
          registry-setup = {
            kind = "registry-setup";
            provides = [ tokens.lab.registryConfig ];
            after = [
              (needs tokens.lab.services)
              (wants tokens.lab.ingressCa)
            ];

            before = map (c: wants (tokens.cluster c.name).created) localClusters;
            params = {
              port = cfg.registry.port;
              upstreams = map (u: u.host) cfg.registry.upstreams;
              zone = cfg.dns.zone;
            };
            description = "Write registries.yaml + certs.d + lab-resolv.conf";
          };
        })

        (optionalAttrs ((cfg.secrets.managed or { }) != { }) {

          ensure-secrets = {
            kind = "ensure-secrets";
            provides = [ tokens.lab.secrets ];
            # Authored stores only. A runtime store holds values the lab
            # mints and is read by external-secrets from inside the cluster,
            # so there is nothing for the CLI to check here and asking it to
            # would fail on a backend it deliberately cannot open.
            params.stores = lib.attrNames (
              lib.filterAttrs (_: st: st.direction == "authored") (cfg.secrets.stores or { })
            );
            description = "Ensure lab secrets are generated and available";
          };
        })

        (optionalAttrs (cfg.out.cliConfig.services != { }) {
          setup-services = {
            kind = "setup-services";
            provides = [ tokens.lab.services ];
            description = "Start lab infrastructure services";
          };
        })

        (optionalAttrs (cfg.registry.enable && cfg.registry.warmCache) {

          warm-cache = {
            kind = "warm-cache";
            after = [ (needs tokens.lab.services) ];
            before = map (c: wants (tokens.cluster c.name).created) localClusters;
            provides = [ tokens.lab.warmCache ];
            description = "Pre-warm lab registry cache with declared images";
          };
        })
      ];

      deployManifestsStep =
        c:
        optionalAttrs (cfg.cd.strategy == "kapp" && !(isSelfProvisioning c)) {
          "deploy-manifests-${c.name}" = {
            kind = "deploy-manifests";
            after = [ (needs (tokens.cluster c.name).created) ];
            requires = optional (cfg.secrets.managed != { }) tokens.lab.secrets;
            provides = [ (tokens.cluster c.name).deployed ];
            params = {
              target = c.name;
              bootstrap = false;
              kubeContext = runtimeCtxOf c;
            };
            description = "Deploy manifests to '${c.name}'";
          };
        };

      createClusterStep =
        c:
        let
          isSelf = builtins.elem c.name syncedContextClusterNames;
        in
        {
          "create-cluster-${c.name}" = {
            kind = "create-cluster";
            after = [ (wants tokens.lab.services) ];
            requires = optional (cfg.secrets.managed != { }) tokens.lab.secrets;
            policy.skipIfClusterReachable = if isSelf then c.name else null;
            provides = [
              (tokens.cluster c.name).created
              (tokens.cluster c.name).reachable
            ];
            params = {
              name = c.name;
              inherit (c) provisioner;
            };
            description = "Create ${c.provisioner} cluster '${c.name}'";
          };
        };

      selfProvisioningSteps =
        c:
        let
          bootstrapCtx = c.config.cluster.ref.kubeContext;
          targetCtx = c.name;

          entry = lib.findFirst (e: e.source.name == c.name) null provisionerGraph;
        in
        optionalAttrs (isSelfProvisioning c) {

          "deploy-manifests-${c.name}-stage1" = {
            kind = "deploy-manifests";
            after = [ (needs (tokens.cluster c.name).created) ];
            policy.skipIfClusterReachable = c.name;
            provides = [ (tokens.cluster c.name).bootstrapDeployed ];
            params = {
              target = c.name;
              bootstrap = true;
              kubeContext = bootstrapCtx;
            };
            description = "Deploy bootstrap-stage manifests to '${c.name}'";
          };

          "wait-cluster-${c.name}" = {
            kind = "wait-for-resources";
            after = [ (needs (tokens.cluster c.name).bootstrapDeployed) ];
            policy.skipIfClusterReachable = c.name;
            provides = [ (tokens.cluster c.name).provisionerDone ];
            params = {
              target = c.name;
              kubeContext = bootstrapCtx;
              resources = map (name: { inherit name; }) (entry.targets or [ ]);
              waitTimeoutSeconds = cfg.timeouts.waitForResources;
            };
            description = "Wait for ${c.provisioner} to provision cluster(s) from '${c.name}'";
          };

          "sync-kubeconfig-${c.name}" = {
            kind = "sync-kubeconfig";
            after = [ (needs (tokens.cluster c.name).provisionerDone) ];
            policy.skipIfClusterReachable = c.name;
            provides = [ (tokens.cluster c.name).kubeconfigSynced ];
            params = {
              target = c.name;
              kubeContext = bootstrapCtx;
              clusters = entry.targets or [ ];
            };
            description = "Sync kubeconfigs for clusters provisioned by '${c.name}'";
          };

          "pivot-${c.name}" = {
            kind = "pivot";
            after = [ (needs (tokens.cluster c.name).kubeconfigSynced) ];
            policy.skipIfClusterReachable = c.name;
            provides = [
              (tokens.cluster c.name).pivoted
              (tokens.cluster c.name).reachable
            ];
            params = {
              cluster = c.name;
              bootstrapContext = bootstrapCtx;
              targetContext = targetCtx;
              inherit (c) provisioner;
            };
            description = "Migrate '${c.name}' from bootstrap to cloud";
          };
        };

      publishImageEntries = cfg.out.publishImages or [ ];

      clusterHostsRegistry =
        cluster: registry: builtins.elem registry cluster.config.cluster.registryDomains;

      resolveSourceCluster =
        img:
        if img.dependsOn != [ ] then
          builtins.head img.dependsOn
        else
          let
            matches = filter (c: clusterHostsRegistry c img.destinationRegistry) allClusters;
          in
          if matches != [ ] then (builtins.head matches).name else null;

      imagesBySrc = clusterName: filter (i: (resolveSourceCluster i) == clusterName) publishImageEntries;

      publishImageSteps = mergeAttrsList (
        map (
          c:
          let
            imgs = imagesBySrc c.name;
          in
          optionalAttrs (imgs != [ ]) {
            "publish-images-${c.name}" = {
              kind = "publish-images";
              after = [ (wants (tokens.cluster c.name).gitopsStarted) ];
              params = {
                sourceCluster = c.name;
                images = imgs;
              };
              description = "Publish ${toString (builtins.length imgs)} image(s) to '${c.name}'";
            };
          }
        ) allClusters
      );

      publishManifestsStep = optionalAttrs ((cfg.cd.git.repo or "") != "") {
        publish-manifests = {
          kind = "publish-manifests";

          after = [ (wants tokens.lab.gitReady) ];
          provides = [ tokens.lab.manifestsPushed ];
          description = "Push rendered manifests to '${cfg.cd.git.repo}'";
        };
      };

      perClusterSteps = mergeAttrsList (
        map (
          c:
          mergeAttrsList [
            (createClusterStep c)
            (deployManifestsStep c)
            (selfProvisioningSteps c)
          ]
        ) allClusters
      );

    in
    mergeAttrsList [
      labScopeSteps
      perClusterSteps
      publishManifestsStep
      publishImageSteps
    ];
}
