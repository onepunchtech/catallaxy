{
  config,
  pkgs,
  lib,
  ...
}:
let
  planTokens = import ../../../../lib/plan-tokens.nix { inherit lib; };
in
{
  lab.name = lib.mkDefault "mesh";
  lab.dns.zone = lib.mkDefault "mesh.test";

  lab.policy.exposure.defaultTier = "public";

  lab.clusters = {
    mgmt = { ... }: { imports = [ ../clusters/mgmt.nix ]; };
    apps = { ... }: { imports = [ ../clusters/apps.nix ]; };
  };

  lab.secrets.stores.trust.backend = "sops";
  lab.secrets.managed.lab-ca = {
    store = "trust";
    kind = "ca";
    hostPaths = {
      "ca.crt" = "$LAB_STATE_DIR/proxy/ca.crt";
      "ca.key" = "$LAB_STATE_DIR/proxy/ca.key";
    };
  };

  lab.steps.xcs-netbird-router-key = {
    kind = "cross-cluster-secret-copy";
    description = "Copy the netbird cluster-router setup key from mgmt to apps";

    after = map (c: planTokens.needs (planTokens.cluster c).reachable) [
      "mgmt"
      "apps"
    ];
    params = {
      name = "netbird-cluster-router-key";
      sourceCluster = "mgmt";
      sourceNamespace = "netbird";
      sourceSecret = "setup-key-cluster-router-apps";
      targetCluster = "apps";
      targetNamespace = "netbird";
      targetSecret = "setup-key-cluster-router-apps";
    };
  };
}
