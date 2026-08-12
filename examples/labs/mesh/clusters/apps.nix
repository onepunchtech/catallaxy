{ config, lab, ... }:
{
  cluster.kubernetes = {
    distribution = "k3s";
    controlPlanes = 1;
    workers = 0;
  };

  cluster.network.serviceSubnet = "10.112.0.0/12";

  floes.cert-manager = {
    enable = true;
    selfSignedCA.enable = true;
  };
  floes.trust-manager.enable = true;

  floes.gateway = {
    enable = true;
    internal = {
      enable = true;
      exposureMode = "netbird";
      clusterIPAddress = "10.112.0.250";
    };
  };

  floes.netbird = {
    enable = true;
    management.enable = false;
    domain = "nb.${lab.dns.zone}";
    agent = {
      enable = true;
      managementUrl = "https://nb.${lab.dns.zone}";
      hostname = "apps-router";
      setupKeyRef.name = "setup-key-cluster-router-apps";
      advertisedRoutes = [ config.cluster.network.serviceSubnet ];
    };
  };

  floes.custom.enable = true;
  floes.custom.apps.hello = {
    namespace = "hello";
    gateway = {
      enable = true;
      tier = "internal";
      domain = "hello.${lab.dns.internalZone}";
      serviceName = "hello";
      servicePort = 80;
    };
    resources = import ../lib/demo-site.nix {
      name = "hello";
      namespace = "hello";
      domain = "hello.${lab.dns.internalZone}";
      cluster = "apps cluster";
      accent = "#5eead4";
      gatewayIP = config.floes.gateway.internal.clusterIPAddress;
    };
  };

  floes.custom.apps.welcome = {
    namespace = "welcome";
    gateway = {
      enable = true;
      tier = "public";
      domain = "welcome.${lab.dns.zone}";
      serviceName = "welcome";
      servicePort = 80;
    };
    resources = import ../lib/demo-site.nix {
      name = "welcome";
      namespace = "welcome";
      domain = "welcome.${lab.dns.zone}";
      cluster = "apps cluster";
      accent = "#fbbf24";
      gatewayIP = lab.dns.server;
      reach = "public";
    };
  };
}
