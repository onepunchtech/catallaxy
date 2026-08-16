{ config, lab, ... }:
{
  imports = [
    ../aspects/identity.nix
    ../aspects/mesh.nix
  ];

  cluster.kubernetes = {
    distribution = "k3s";
    controlPlanes = 1;
    workers = 0;
  };

  floes.external-secrets.enable = true;

  # The lab's runtime store. Exposed because apps reads it, not for humans.
  floes.openbao = {
    enable = true;
    domain = "bao.${lab.dns.zone}";
    tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
  };

  secrets.projections.openbao-root-token = {
    source = "openbao-root-token";
    namespace = "openbao";
    keys.token.from = "token";
  };

  secrets.projections.vault-token = {
    source = "openbao-root-token";
    namespace = "external-secrets";
    keys.token.from = "token";
  };

  # The netbird operator mints this after it comes up, so nothing could have
  # authored it. Publishing is how it reaches the cluster that needs it.
  secrets.publish.setup-key-cluster-router-apps = {
    namespace = "netbird";
  };

  floes.cert-manager = {
    enable = true;
    selfSignedCA.enable = true;
  };
  floes.trust-manager.enable = true;
  floes.reloader.enable = true;

  floes.gateway = {
    enable = true;

    internal = {
      enable = true;
      exposureMode = "netbird";
      clusterIPAddress = "10.96.100.100";
    };
  };

  floes.custom.enable = true;
  floes.custom.apps.ops = {
    namespace = "ops";
    gateway = {
      enable = true;
      tier = "internal";
      domain = "ops.${lab.dns.internalZone}";
      serviceName = "ops";
      servicePort = 80;
    };
    resources = import ../lib/demo-site.nix {
      name = "ops";
      namespace = "ops";
      domain = "ops.${lab.dns.internalZone}";
      cluster = "management cluster";
      accent = "#a78bfa";
      gatewayIP = config.floes.gateway.internal.clusterIPAddress;
    };
  };
}
