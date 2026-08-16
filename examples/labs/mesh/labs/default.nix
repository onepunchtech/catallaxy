{
  config,
  pkgs,
  lib,
  ...
}:
{
  lab.name = lib.mkDefault "mesh";
  lab.dns.zone = lib.mkDefault "mesh.test";

  lab.policy.exposure.defaultTier = "public";

  lab.clusters = {
    mgmt = { ... }: { imports = [ ../clusters/mgmt.nix ]; };
    apps = { ... }: { imports = [ ../clusters/apps.nix ]; };
  };

  lab.secrets.stores.trust.backend = "sops";

  # The netbird setup key for the apps router is minted by the netbird
  # operator on mgmt, so it cannot be authored. mgmt publishes it and apps
  # subscribes; see the README.
  lab.secrets.stores.runtime = {
    backend = "vault";
    vault.server = config.lab.clusters.mgmt.floes.openbao.exports.externalAddress;
  };

  # OpenBao's own root token is a value we write, so it is authored.
  lab.secrets.stores.bootstrap.backend = "env";
  lab.secrets.envFile = "examples/labs/mesh/envs/ci.env";
  lab.secrets.managed.openbao-root-token = {
    store = "bootstrap";
    keys.token = { };
  };

  lab.secrets.managed.lab-ca = {
    store = "trust";
    kind = "ca";
    hostPaths = {
      "ca.crt" = "$LAB_STATE_DIR/proxy/ca.crt";
      "ca.key" = "$LAB_STATE_DIR/proxy/ca.key";
    };
  };

}
