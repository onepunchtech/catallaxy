{
  lib,
  cfg,
  nb,
  k8sHelpers,
  sectionName,
  gatewayName,
  gatewayNamespace,
}:
let
  inherit (lib) optionalAttrs;
  inherit (nb) signalDomain signalPort managedBy;

  gatewayParent = k8sHelpers.mkGatewayParent {
    name = gatewayName;
    namespace = gatewayNamespace;
    inherit sectionName;
  };

  mkRoute =
    {
      name,
      hostname,
      backendPort,
      pathPrefix ? "/",
    }:
    k8sHelpers.mkHttpRoute {
      inherit
        name
        hostname
        pathPrefix
        gatewayParent
        ;
      namespace = cfg.namespace;
      labels = managedBy;
      backend = {
        inherit name;
        port = backendPort;
      };
    };
in
{
  routes = {
    netbird-management-route = mkRoute {
      name = "netbird-management";
      hostname = cfg.domain;
      backendPort = 80;
    };

    netbird-relay-route = mkRoute {
      name = "netbird-relay";
      hostname = cfg.domain;
      pathPrefix = "/relay";
      backendPort = 33080;
    };

    netbird-signal-route = mkRoute {
      name = "netbird-signal";
      hostname = signalDomain;
      backendPort = signalPort;
    };
  };

  cert = optionalAttrs (cfg.tls.issuerRef != null) {
    netbird-management-tls = k8sHelpers.mkCertificate {
      name = cfg.tls.secretName;
      namespace = cfg.namespace;
      secretName = cfg.tls.secretName;
      issuerRef = {
        inherit (cfg.tls.issuerRef) name kind;
      };
      dnsNames = [
        cfg.domain
        signalDomain
      ];
      labels = managedBy;
    };
  };
}
