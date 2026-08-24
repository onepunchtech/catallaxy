{
  config,
  lib,
  lab,
  ...
}:

let
  inherit (lib) mkIf;
  cfg = config.cluster.security.networkPolicies;

  netpol = import ../../../lib/util/netpol.nix { inherit lib; };
  k8sFields = import ../../../lib/util/k8s-fields.nix { inherit lib; };

  policyBundle = "default-network-policies";

  cilium = config.floes.cilium.enable or false;

  clusterCidrs = [
    config.cluster.network.podSubnet
    config.cluster.network.serviceSubnet
  ];

  apiServerCidrs =
    if cfg.apiServerCidrs != [ ] then cfg.apiServerCidrs else [ lab.network.dockerSubnet ];

  allNamespaces = lib.unique (
    lib.concatMap (b: b.createNamespaces or [ ]) (lib.attrValues config.bundles)
  );

  enabledFloes = lib.filterAttrs (_: f: f.enable or false) config.floes;

  createdNamespacesOf =
    floeName:
    lib.unique (
      lib.concatMap (b: b.createNamespaces or [ ]) (
        lib.attrValues (lib.filterAttrs (_: b: (b.declaredBy or null) == floeName) config.bundles)
      )
    );

  namespaceOf =
    floeName: lib.optional (enabledFloes ? ${floeName}) enabledFloes.${floeName}.namespace;

  namespacesOf = floeName: lib.unique (namespaceOf floeName ++ createdNamespacesOf floeName);

  ownNamespacesOf = floeName: lib.filter (ns: builtins.elem ns allNamespaces) (namespaceOf floeName);

  networkOf = floeName: (enabledFloes.${floeName} or { }).network or { };

  parseReach =
    fromFloe: ref:
    let
      parts = lib.splitString "/" ref;
      target = builtins.head parts;
      label = if builtins.length parts == 2 then builtins.elemAt parts 1 else null;
      served = (networkOf target).serves or { };
    in
    {
      inherit ref target label;
      from = fromFloe;
      exists = config.floes ? ${target};
      known = enabledFloes ? ${target};
      wellFormed = label != null;
      serves = label != null && served ? ${label};
      port = if label == null then null else served.${label} or null;
    };

  allParsed = lib.concatMap (
    floeName: map (parseReach floeName) ((networkOf floeName).reaches or [ ])
  ) (lib.attrNames enabledFloes);

  unknownReaches = lib.filter (r: !r.exists) allParsed;

  strayOverrides =
    what: overrides:
    map (ns: { inherit what ns; }) (
      lib.filter (ns: !(builtins.elem ns allNamespaces)) (lib.attrNames overrides)
    );

  overrideTypos =
    strayOverrides "cluster.security.networkPolicies.namespaceOverrides" cfg.namespaceOverrides
    ++ strayOverrides "cluster.security.podSecurity.namespaceOverrides" config.cluster.security.podSecurity.namespaceOverrides;

  badReaches = lib.filter (r: r.known && !r.serves) allParsed;

  allReaches = lib.filter (r: r.known && r.serves) allParsed;

  reachesOf = floeName: lib.filter (r: r.from == floeName) allReaches;

  portRule = p: [
    {
      inherit (p) port protocol;
    }
  ];

  extraEgress =
    egress:
    lib.optional ((egress.internet.ports or [ ]) != [ ]) {
      to = "world";
      inherit (egress.internet) ports;
    }
    ++ map (c: {
      to = { inherit (c) cidr except; };
      inherit (c) ports;
    }) (lib.filter (c: c.ports != [ ]) (egress.cidrs or [ ]));

  egressFor =
    floeName:
    map (r: {
      to.namespaces = namespacesOf r.target;
      ports = portRule r.port;
    }) (reachesOf floeName)
    ++ extraEgress ((networkOf floeName).egress or { });

  ingressFor =
    floeName:
    let
      served = (networkOf floeName).serves or { };

      fromClients = map (r: {
        from.namespaces = namespacesOf r.from;
        ports = portRule r.port;
      }) (lib.filter (r: r.target == floeName) allReaches);

      external = map (s: {
        from = "world";
        ports = portRule s;
      }) (lib.attrValues (lib.filterAttrs (_: s: s.fromExternal) served));

      fromApiServer = map (s: {
        from = "apiServer";
        ports = portRule s;
      }) (lib.attrValues (lib.filterAttrs (_: s: s.fromApiServer) served));
    in
    fromClients ++ external ++ fromApiServer;

  gatewayNamespaces = namespacesOf "gateway";

  routeBackends =
    let
      others = lib.filterAttrs (n: _: n != policyBundle) config.bundles;
      resources = lib.concatMap (b: lib.attrValues (b.resources or { })) (lib.attrValues others);
      routes = lib.filter (r: (r.kind or "") == "HTTPRoute") resources;
    in
    lib.concatMap (
      route:
      let
        ns = route.metadata.namespace or null;
        refs = lib.concatMap (k8sFields.listOrEmpty [ "backendRefs" ]) (
          k8sFields.listOrEmpty [ "spec" "rules" ] route
        );
      in
      lib.optionals (ns != null) (
        map (ref: {
          namespace = k8sFields.valueOr [ "namespace" ] ns ref;
          port = k8sFields.valueAt [ "port" ] ref;
        }) (lib.filter (ref: k8sFields.valueAt [ "port" ] ref != null) refs)
      )
    ) routes;

  routeFlows = lib.mapAttrsToList (namespace: entries: {
    inherit namespace;
    ports = lib.unique (
      map (e: {
        inherit (e) port;
        protocol = "TCP";
      }) entries
    );
  }) (lib.groupBy (e: e.namespace) routeBackends);

  gatewayEgressFor =
    ns:
    lib.optionals (builtins.elem ns gatewayNamespaces) (
      map (f: {
        to.namespaces = [ f.namespace ];
        inherit (f) ports;
      }) routeFlows
    );

  gatewayIngressFor =
    ns:
    map (f: {
      from.namespaces = gatewayNamespaces;
      inherit (f) ports;
    }) (lib.optionals (gatewayNamespaces != [ ]) (lib.filter (f: f.namespace == ns) routeFlows));

  policyFor = ns: cfg.namespaceOverrides.${ns} or cfg.default;

  baseFor =
    ns:
    let
      p = policyFor ns;
    in
    {
      egress =
        lib.optional p.dns {
          to = "anywhere";
          ports = [
            {
              port = 53;
              protocol = "UDP";
            }
            {
              port = 53;
              protocol = "TCP";
            }
          ];
        }
        ++ lib.optional p.sameNamespace { to = "sameNamespace"; }
        ++ lib.optional p.apiServer {
          to = "apiServer";
          ports = [
            {
              port = 443;
              protocol = "TCP";
            }
            {
              port = 6443;
              protocol = "TCP";
            }
          ];
        }
        ++ extraEgress p.egress;

      ingress =
        lib.optional p.sameNamespace { from = "sameNamespace"; }
        ++ map (c: {
          from = { inherit (c) cidr except; };
          inherit (c) ports;
        }) (p.ingress.cidrs or [ ]);
    };

  defaultDenyResources = lib.listToAttrs (
    map (
      ns:
      lib.nameValuePair "netpol-default-deny-${ns}" (
        netpol.mkPolicy (
          {
            inherit cilium apiServerCidrs clusterCidrs;
            name = "default-deny";
            namespace = ns;
          }
          // baseFor ns
        )
      )
    ) allNamespaces
  );

  floePolicies = lib.listToAttrs (
    lib.concatMap (
      floeName:
      lib.concatMap (
        ns:
        let
          egress = egressFor floeName ++ gatewayEgressFor ns;
          ingress = ingressFor floeName ++ gatewayIngressFor ns;
        in
        lib.optional (egress != [ ] || ingress != [ ]) (
          lib.nameValuePair "netpol-${floeName}-${ns}" (
            netpol.mkPolicy {
              inherit
                cilium
                apiServerCidrs
                clusterCidrs
                egress
                ingress
                ;
              name = "allow-${floeName}";
              namespace = ns;
            }
          )
        )
      ) (ownNamespacesOf floeName)
    ) (lib.attrNames enabledFloes)
  );
in
{
  options.cluster.out.networkDeclarations = lib.mkOption {
    type = lib.types.raw;
    internal = true;
    readOnly = true;
    description = "Per-floe served ports and their namespaces, for the lint.";
  };

  config = lib.mkMerge [
    {
      assertions =
        lib.optional (overrideTypos != [ ]) {
          assertion = false;
          message = ''
            On cluster ${config.cluster.name}, a per-namespace override names a
            namespace this cluster does not create:

            ${lib.concatMapStringsSep "\n" (o: "  ${o.what}.${o.ns}") overrideTypos}

            The namespaces it creates are:

            ${
              if allNamespaces == [ ] then
                "none"
              else
                lib.concatStringsSep ", " (lib.sort (a: b: a < b) allNamespaces)
            }

            Both overrides are read only while rendering the namespaces the
            cluster creates, so a key outside that set is applied to nothing.
            It reads as a policy decision and is not one.
          '';
        }
        ++ lib.optional (unknownReaches != [ ]) {
          assertion = false;
          message = ''
            On cluster ${config.cluster.name}, a floe reaches something that is
            not a floe:

            ${lib.concatMapStringsSep "\n" (r: "  ${r.from} -> ${r.ref}") unknownReaches}

            A `reaches` entry names `<floe>/<label>`. The floes this repo
            defines are:

            ${lib.concatStringsSep ", " (lib.attrNames config.floes)}

            A name that is not one of those is a typo, and a typo is silent in
            both directions: no egress rule is written for the floe that
            declared it, no ingress rule for the floe it meant, and the default
            deny still applies. The pod ends up refused the traffic it asked
            for. Naming a floe that exists but is off on this cluster is fine
            and stays quiet.
          '';
        }
        ++ lib.optional (badReaches != [ ]) {
          assertion = false;
          message = ''
            On cluster ${config.cluster.name}, a floe reaches something no floe
            serves:

            ${lib.concatMapStringsSep "\n" (
              r:
              "  ${r.from} -> ${r.ref}"
              + (
                if !r.wellFormed then
                  " (not of the form <floe>/<label>)"
                else
                  " (${r.target} publishes: ${
                     let
                       served = lib.attrNames ((networkOf r.target).serves or { });
                     in
                     if served == [ ] then "nothing" else lib.concatStringsSep ", " served
                   })"
              )
            ) badReaches}

            A `reaches` entry names a label the other floe published in
            `serves`. Rendering nothing for one that does not exist is how a
            rule silently fails to apply.
          '';
        };

      cluster.out.networkDeclarations = {
        enabled = cfg.enable;
        floes = lib.mapAttrs (floeName: floeCfg: {
          namespaces = namespacesOf floeName;
          serves = lib.mapAttrs (_: s: {
            inherit (s) port protocol;
          }) (floeCfg.network.serves or { });
        }) (lib.filterAttrs (n: _: ((networkOf n).serves or { }) != { }) enabledFloes);
      };
    }

    (mkIf cfg.enable {
      bundles.${policyBundle} = {
        declaredBy = "cluster";
        resources = defaultDenyResources // floePolicies;
      };
    })
  ];
}
