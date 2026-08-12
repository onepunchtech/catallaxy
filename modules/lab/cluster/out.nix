{
  config,
  lib,
  pkgs,
  lab,
  ...
}:

let
  inherit (lib) mkOption types;
  render = import ../../../lib/render/manifest.nix { inherit lib pkgs; };

  routeKinds = [
    "HTTPRoute"
    "TLSRoute"
  ];

  internalHostnames = config.floes.gateway.internalHostnames or [ ];

  routePaths =
    resource:
    lib.unique (
      lib.concatMap (
        rule:
        lib.concatMap (match: lib.optional ((match.path.value or "") != "") match.path.value) (
          rule.matches or [ ]
        )
      ) (resource.spec.rules or [ ])
    );

  routeEntries = lib.concatLists (
    lib.mapAttrsToList (
      bundleName: bundle:
      lib.concatLists (
        lib.mapAttrsToList (
          _: resource:
          lib.optionals (builtins.elem (resource.kind or "") routeKinds) (
            map (host: {
              inherit host;
              tier = if builtins.elem host internalHostnames then "internal" else "public";
              namespace = resource.metadata.namespace or "default";
              bundle = bundleName;
              paths = routePaths resource;
            }) (lib.filter (h: !(lib.hasInfix "*" h)) (resource.spec.hostnames or [ ]))
          )
        ) (bundle.resources or { })
      )
    ) config.bundles
  );

  routeHosts = map (
    entries:
    (lib.head entries)
    // {
      tier = if lib.all (e: e.tier == "internal") entries then "internal" else "public";
      paths = lib.unique (lib.concatMap (e: e.paths) entries);
    }
  ) (lib.attrValues (lib.groupBy (e: e.host) routeEntries));

  bundleViews =
    let
      allNamespaces = lib.unique (lib.concatMap (b: b.createNamespaces) (lib.attrValues config.bundles));

      psaCfg = config.cluster.security.podSecurity;
      psaLabels =
        ns:
        let
          level = psaCfg.namespaceOverrides.${ns} or psaCfg.default;
        in
        if psaCfg.enable then
          {
            "pod-security.kubernetes.io/enforce" = level;
            "pod-security.kubernetes.io/warn" = level;
          }
        else
          { };

      namespaceYamls = map (
        ns:
        let
          labels = psaLabels ns;
        in
        builtins.toJSON (
          {
            apiVersion = "v1";
            kind = "Namespace";
            metadata.name = ns;
          }
          // lib.optionalAttrs (labels != { }) {
            metadata = {
              name = ns;
              labels = labels;
            };
          }
        )
      ) allNamespaces;

      defaultOwner = lab.cd.defaultOwner;
      resolveBundleOwner = b: {
        bootstrap = if b.owner.bootstrap != null then b.owner.bootstrap else defaultOwner.bootstrap;
        steady = if b.owner.steady != null then b.owner.steady else defaultOwner.steady;
      };

      isImperativelyOwnedBundle = b: (resolveBundleOwner b).bootstrap == "install-target";

      isArgocdOwnedBundle = b: (resolveBundleOwner b).steady == "argocd";

      renderOne =
        name: b:
        if b.helmCharts != { } || b.resources != { } || b.yamls != [ ] then
          render.renderBundle name {
            inherit (b)
              helmCharts
              resources
              yamls
              awaitRollout
              ;
          }
        else
          null;

      namespacesPackage = lib.optionalAttrs (namespaceYamls != [ ]) {
        namespaces = render.renderBundle "namespaces" {
          helmCharts = { };
          resources = { };
          yamls = namespaceYamls;
        };
      };

      viewFor =
        select:
        let
          selected = lib.filterAttrs (_: select) config.bundles;
        in
        {
          bundles = selected;
          packages = lib.filterAttrs (_: v: v != null) (lib.mapAttrs renderOne selected) // namespacesPackage;
        };
    in
    {
      all = viewFor (_: true);
      imperative = viewFor isImperativelyOwnedBundle;
      argocd = viewFor isArgocdOwnedBundle;

      stage1 = viewFor (b: b.includeInBootstrap);
    };
in

{
  options.cluster.out = {
    topology = mkOption {
      type = types.attrs;
      description = "Computed topology/network map";
    };

    sbom = mkOption {
      type = types.attrs;
      description = "Software bill of materials";
    };

    bundleView = mkOption {
      type = types.raw;
      default = { };
      description = ''
        Every bundle plus its rendered package. `{ bundles; packages; }`
        where `bundles` is the authored records and `packages` is the
        subset that produced YAML, both keyed by bundle name.
      '';
    };

    stage1BundleView = mkOption {
      type = types.raw;
      default = { };
      description = ''
        Same shape as `bundleView`, restricted to bundles with
        `includeInBootstrap = true`. The lab-level `stage1Manifests`
        render intersects this with the DAG closure of
        `cluster.provisioning.rootBundles`. Bundles that should not run
        on the ephemeral k3d bootstrap (external-dns, kaniop, cnpg, ...)
        opt out via the flag.
      '';
    };

    imperativeBundleView = mkOption {
      type = types.raw;
      default = { };
      description = ''
        Same shape as `bundleView`, restricted to bundles whose
        `owner.bootstrap == "install-target"`. Consumed by the
        imperative renderer so the imperative actor (kapp / kubectl-ssa
        / helm) never touches argocd-owned bundles. Bundles that hand
        off (bootstrap="install-target", steady="argocd") appear here:
        the imperative actor is still the initial-apply owner, and
        argocd inherits via SSA on first sync.
      '';
    };

    argocdBundleView = mkOption {
      type = types.raw;
      default = { };
      description = ''
        Same shape as `bundleView`, restricted to bundles whose
        `owner.steady == "argocd"`. Consumed by the argocd renderer to
        build the per-bundle Application tree. Install-target→argocd
        bundles are included; steady="imperative" bundles are excluded.
      '';
    };

    manifestWaves = mkOption {

      type = types.listOf (types.listOf types.attrs);
      default = [ ];
      description = ''
        DAG-derived install waves. Each inner list is one topological
        equivalence class from `lib/eval/manifest-graph.nix`; bundles
        inside a class can install in parallel, wave N+1 gates on
        wave N.
      '';
    };

    exposedHosts = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            host = mkOption {
              type = types.str;
              description = "Hostname a route on this cluster answers to.";
            };
            tier = mkOption {
              type = types.enum [
                "public"
                "internal"
              ];
              description = ''
                Which gateway serves it. `internal` hosts resolve only
                from inside the lab's mesh, so a probe from the operator's
                machine is expected to fail and is skipped rather than
                run.
              '';
            };
            namespace = mkOption {
              type = types.str;
              description = "Namespace the route lives in.";
            };
            bundle = mkOption {
              type = types.str;
              description = "Bundle that declares it, for pointing at when a probe fails.";
            };
            paths = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = ''
                Path prefixes the route matches, in declaration order.
                Empty when the route matches every path, which is the
                common case.

                A probe of `/` on a host whose route only matches
                `/api/v1/write` proves nothing: the gateway is right to
                refuse it. `cata lab verify` probes the first of these
                instead, so the request goes where the route says it
                should.
              '';
            };
          };
        }
      );
      default = [ ];
      description = ''
        Every hostname this cluster serves, read off the `HTTPRoute` and
        `TLSRoute` resources its bundles declare rather than off any
        floe's own `domain` option. A floe is free to route a name it
        does not own, and `floes.custom` routes names that belong to the
        app rather than to the floe, so the routes are the only place the
        answer is complete.

        `cata lab verify` probes the public ones. Nothing else reads this.
      '';
    };
  };

  config.assertions =
    let
      defaultOwner = lab.cd.defaultOwner;
      resolve = b: {
        bootstrap = if b.owner.bootstrap != null then b.owner.bootstrap else defaultOwner.bootstrap;
        steady = if b.owner.steady != null then b.owner.steady else defaultOwner.steady;
      };
      allBundles = lib.mapAttrsToList (name: bundle: {
        inherit name bundle;
        owner = resolve bundle;
      }) config.bundles;

      invalidOwner = lib.filter (
        e: e.owner.bootstrap == "argocd" && e.owner.steady == "imperative"
      ) allBundles;

      installTargets = lib.filter (e: e.owner.bootstrap == "install-target") allBundles;
      providersOf = token: lib.filter (e: builtins.elem token (e.bundle.provides or [ ])) allBundles;
      unsatisfiable = lib.concatMap (
        e:
        lib.concatMap (
          token:
          let
            providers = providersOf token;
            imperativeProviders = lib.filter (p: p.owner.bootstrap == "install-target") providers;
          in

          if providers != [ ] && imperativeProviders == [ ] then
            [
              {
                inherit token;
                consumer = e;
                providerKeys = map (p: p.name) providers;
              }
            ]
          else
            [ ]
        ) (e.bundle.requires or [ ])
      ) installTargets;
    in
    map (e: {
      assertion = false;
      message = ''
        Bundle ${e.name} has
        owner = { bootstrap = "argocd"; steady = "imperative"; }.
        This is not a valid handoff direction; argocd can't
        bootstrap itself, so it can't be the bootstrap owner of any
        bundle. Use `bootstrap = "install-target"` and either
        `steady = "imperative"` (no handoff) or `steady = "argocd"`
        (imperative actor bootstraps, argocd takes over at steady
        state).
      '';
    }) invalidOwner
    ++ map (u: {
      assertion = false;
      message = ''
        Bundle ${u.consumer.name} is
        `owner.bootstrap = "install-target"` and requires
        '${u.token}', but every bundle providing that token is
        argocd-owned: ${builtins.concatStringsSep ", " u.providerKeys}.

        Argocd-owned bundles are not in the imperative bootstrap
        manifest set, so this dependency is never applied before the
        requiring bundle runs; the gate silently does nothing.

        Fix by giving the provider
        `owner = { bootstrap = "install-target"; steady = "argocd"; }`
        (it is part of the install target, argocd inherits it at
        steady state), or by moving the consumer to
        `owner.bootstrap = "argocd"` if it doesn't actually need to
        exist before argocd does.
      '';
    }) unsatisfiable;

  config.cluster.out = {
    topology = {
      name = config.cluster.name;
      provider = config.cluster.provider;
      nodes = {
        inherit (config.cluster.kubernetes) controlPlanes workers;
      };
      network = config.cluster.network;
      components = lib.mapAttrs (_: c: { enabled = c.enable or false; }) config.floes;
    };

    sbom = {
      components = lib.mapAttrs (_: c: {

        version = if (c.version or null) == null then "unknown" else c.version;
        enabled = c.enable or false;
      }) config.floes;
    };

    bundleView = bundleViews.all;
    stage1BundleView = bundleViews.stage1;
    imperativeBundleView = bundleViews.imperative;
    argocdBundleView = bundleViews.argocd;

    exposedHosts = routeHosts;

    manifestWaves =
      let
        manifestGraph = import ../../../lib/eval/manifest-graph.nix { inherit lib; };
        autoedges = import ../../../lib/eval/manifest-autoedges.nix { inherit lib; };
        projections = import ../../../lib/eval/manifest-projections.nix { inherit lib; };

        rawBundles = lib.mapAttrs (_: bundle: {
          after = bundle.after or [ ];
          requires = bundle.requires or [ ];
          provides = bundle.provides or [ ];

          kind = null;
          floe = null;

          resources = bundle.resources or { };
          helmCharts = lib.mapAttrs (_: h: { inherit (h) namespace; }) (bundle.helmCharts or { });
          createNamespaces = bundle.createNamespaces or [ ];

          resourceCount = builtins.length (lib.attrNames (bundle.resources or { }));
          hasReadyProbe = (bundle.readyProbe or null) != null;

          readyProbe = bundle.readyProbe or null;
        }) config.bundles;

        hasNamespaceContent = lib.any (b: (b.createNamespaces or [ ]) != [ ]) (
          lib.attrValues config.bundles
        );

        namespacesBundle = lib.optionalAttrs hasNamespaceContent {
          namespaces = {

            after = [ ];
            requires = [ ];
            provides = [ ];
            kind = null;
            floe = null;
            resources = { };
            helmCharts = { };
            createNamespaces = [ ];
            resourceCount = 0;
            hasReadyProbe = false;
            readyProbe = null;
            includeInBootstrap = true;
          };
        };

        projectionBundles = lib.mapAttrs' (projName: proj: {
          name = "projection/${projName}";
          value = {

            after = lib.optional hasNamespaceContent "bundle:namespaces";
            requires = [ ];
            provides = [ "secret:${proj.namespace}/${projName}" ];
            kind = null;
            floe = null;
            resources = { };
            helmCharts = { };
            createNamespaces = [ ];
            resourceCount = 0;
            hasReadyProbe = false;
            readyProbe = null;
            includeInBootstrap = true;
          };
        }) config.secrets.projections;

        projectionSet = lib.mapAttrs (_: proj: { inherit (proj) namespace; }) config.secrets.projections;

        rawBundlesWithProjRequires = projections.withProjectionRequires {
          bundles = rawBundles;
          inherit projectionSet;
        };

        allBundles = rawBundlesWithProjRequires // projectionBundles // namespacesBundle;

        withAutoEdges = autoedges.deriveAutoEdges {
          bundles = allBundles;

          namespaceAggregate = if hasNamespaceContent then "namespaces" else null;
        };

        stage1Roots = lib.unique (config.cluster.provisioning.rootBundles or [ ]);
        stage1BundleKeys = manifestGraph.closurePredecessors {
          bundles = withAutoEdges;
          roots = stage1Roots;
        };
        stage1BundleKeySet = lib.genAttrs stage1BundleKeys (_: true);

        withStage1 = lib.mapAttrs (
          name: b:
          b
          // {
            provides = b.provides ++ lib.optional (stage1BundleKeySet ? ${name}) "stage1";
          }
        ) withAutoEdges;

        thin = lib.mapAttrs (
          _: b:
          builtins.removeAttrs b [
            "resources"
            "helmCharts"
            "createNamespaces"
          ]
        ) withStage1;
      in
      manifestGraph.computeWaves { bundles = thin; };
  };

}
