{
  config,
  lib,
  lab,
  ...
}:

let
  inherit (lib) mkIf concatStringsSep;

  gw = config.floes.gateway.exports or { };
  hostnames = gw.internalHostnames or [ ];
  internalClusterIP = gw.internalGatewayClusterIP or null;

  dns = lab.dns;

  clusterGateways = map (c: c.floes.gateway.exports or { }) (lib.attrValues (lab.clusters or { }));

  internalDomain =
    let
      declared = lib.filter (d: d != "") (map (g: g.internalDomain or "") clusterGateways);
    in
    if (gw.internalDomain or "") != "" then gw.internalDomain else lib.head (declared ++ [ "" ]);

  isInternal = h: internalDomain != "" && lib.hasSuffix ".${internalDomain}" h;

  internalEntries =
    let
      entriesFor =
        g:
        let
          ip = g.internalGatewayClusterIP or null;
        in
        if ip == null then
          [ ]
        else
          map (h: "${ip} ${h}") (lib.filter isInternal (g.internalHostnames or [ ]));
    in
    lib.unique (lib.sort lib.lessThan (lib.concatMap entriesFor clusterGateways));

  publicEntries =
    if internalClusterIP == null then
      [ ]
    else
      map (h: "${internalClusterIP} ${h}") (lib.filter (h: !(isInternal h)) hostnames);

  mkHostsBlock =
    entries:
    if entries == [ ] then
      ""
    else
      ''
            hosts {
        ${concatStringsSep "\n" (map (e: "      ${e}") entries)}
              fallthrough
            }
      '';

  forwardLine =
    if dns.enable then
      "  forward . ${dns.server}:${toString dns.port}"
    else
      "  forward . /etc/resolv.conf";

  mkZoneServer = zone: entries: ''
    ${zone}:53 {
      errors
      cache 30
    ${mkHostsBlock entries}${forwardLine}
    }
  '';

  serverFiles = {
    "lab.server" = mkZoneServer dns.zone publicEntries;
  }
  // lib.optionalAttrs (internalEntries != [ ]) {
    "lab-internal.server" = mkZoneServer internalDomain internalEntries;
  }
  // (lib.mapAttrs' (
    name: content: lib.nameValuePair "${name}.server" content
  ) dns.coredns.extraServers);
in
{

  config = mkIf dns.coredns.enable {
    bundles.coredns-lab-dns = {
      declaredBy = "cluster";

      owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };

      provides = [ "coredns/lab-dns/ready" ];
      resources.coredns-custom = {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = {
          name = "coredns-custom";
          namespace = "kube-system";
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        data = serverFiles;
      };
    };
  };
}
