{ lib }:

let
  inherit (lib) optionalAttrs;

  nsLabel = "kubernetes.io/metadata.name";
  ciliumNsLabel = "k8s:io.kubernetes.pod.namespace";

  plainPorts = ports: optionalAttrs (ports != [ ]) { inherit ports; };

  ciliumPorts =
    ports:
    optionalAttrs (ports != [ ]) {
      toPorts = [
        {
          ports = map (p: {
            port = toString p.port;
            inherit (p) protocol;
          }) ports;
        }
      ];
    };

  named =
    what: xs:
    if xs == [ ] then throw "netpol: a rule names no ${what}, which permits every destination" else xs;

  plainPeer =
    { apiServerCidrs, clusterCidrs }:
    peer:
    if peer == "anywhere" then
      null
    else if peer == "sameNamespace" then
      [ { podSelector = { }; } ]
    else if peer == "apiServer" then
      map (cidr: { ipBlock = { inherit cidr; }; }) (named "API server address range" apiServerCidrs)
    else if peer == "world" then
      [
        {
          ipBlock = {
            cidr = "0.0.0.0/0";
            except = clusterCidrs;
          };
        }
      ]
    else if peer ? namespaces then
      map (ns: { namespaceSelector.matchLabels.${nsLabel} = ns; }) (named "namespace" peer.namespaces)
    else if peer ? cidr then
      [
        {
          ipBlock = {
            inherit (peer) cidr;
          }
          // optionalAttrs ((peer.except or [ ]) != [ ]) { inherit (peer) except; };
        }
      ]
    else
      throw "netpol: unknown peer ${builtins.toJSON peer}";

  ciliumPeer =
    peer:
    if peer == "anywhere" then
      { toEntities = [ "all" ]; }
    else if peer == "sameNamespace" then
      { toEndpoints = [ { } ]; }
    else if peer == "apiServer" then
      { toEntities = [ "kube-apiserver" ]; }
    else if peer == "world" then
      { toEntities = [ "world" ]; }
    else if peer ? namespaces then
      {
        toEndpoints = map (ns: { matchLabels.${ciliumNsLabel} = ns; }) (named "namespace" peer.namespaces);
      }
    else if peer ? cidr then
      {
        toCIDRSet = [
          ({ inherit (peer) cidr; } // optionalAttrs ((peer.except or [ ]) != [ ]) { inherit (peer) except; })
        ];
      }
    else
      throw "netpol: unknown peer ${builtins.toJSON peer}";

  mkPlain =
    {
      name,
      namespace,
      egress ? [ ],
      ingress ? [ ],
      apiServerCidrs ? [ ],
      clusterCidrs ? [ ],
      ...
    }:
    let
      toPeer = plainPeer { inherit apiServerCidrs clusterCidrs; };

      egressRule =
        r:
        let
          peers = toPeer r.to;
        in
        optionalAttrs (peers != null) { to = peers; } // plainPorts (r.ports or [ ]);

      ingressRule =
        r:
        let
          peers = toPeer r.from;
        in
        optionalAttrs (peers != null) { from = peers; } // plainPorts (r.ports or [ ]);
    in
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "NetworkPolicy";
      metadata = {
        inherit name namespace;
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };
      spec = {
        podSelector = { };
        policyTypes = [
          "Ingress"
          "Egress"
        ];
      }
      // optionalAttrs (ingress != [ ]) { ingress = map ingressRule ingress; }
      // optionalAttrs (egress != [ ]) { egress = map egressRule egress; };
    };

  mkCilium =
    {
      name,
      namespace,
      egress ? [ ],
      ingress ? [ ],
      ...
    }:
    let
      egressRule = r: ciliumPeer r.to // ciliumPorts (r.ports or [ ]);

      ingressRule =
        r:
        let
          peer = ciliumPeer r.from;
          renamed = lib.mapAttrs' (
            k: v:
            lib.nameValuePair (
              {
                toEntities = "fromEntities";
                toEndpoints = "fromEndpoints";
                toCIDRSet = "fromCIDRSet";
              }
              .${k} or k
            ) v
          ) peer;
        in
        renamed // ciliumPorts (r.ports or [ ]);
    in
    {
      apiVersion = "cilium.io/v2";
      kind = "CiliumNetworkPolicy";
      metadata = {
        inherit name namespace;
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };
      spec = {
        endpointSelector = { };
        enableDefaultDeny = {
          ingress = true;
          egress = true;
        };
      }
      // optionalAttrs (ingress != [ ]) { ingress = map ingressRule ingress; }
      // optionalAttrs (egress != [ ]) { egress = map egressRule egress; };
    };

  mkPolicy = args: if args.cilium or false then mkCilium args else mkPlain args;
in
{
  inherit mkPlain mkCilium mkPolicy;
}
