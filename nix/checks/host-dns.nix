{
  lib,
  pkgs,
  self,
}:

let
  evalHost =
    module:
    (lib.evalModules {
      modules = [
        { options._module.args = lib.mkOption { type = lib.types.raw; }; }
        (
          { lib, ... }:
          {
            options = {
              assertions = lib.mkOption {
                type = lib.types.listOf lib.types.unspecified;
                default = [ ];
              };
              environment.etc = lib.mkOption {
                type = lib.types.attrsOf (
                  lib.types.submodule { options.text = lib.mkOption { type = lib.types.str; }; }
                );
                default = { };
              };
              services.resolved.enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };
            };
          }
        )
        (self + "/nix/nixos/host-dns.nix")
        module
      ];
    }).config;

  configured = evalHost {
    services.resolved.enable = true;
    services.catallaxy.hostDns = {
      enable = true;
      zones."minimal.test".port = 5354;
      zones."mesh.test" = {
        host = "127.0.0.1";
        port = 5355;
      };
    };
  };

  off = evalHost { services.catallaxy.hostDns.zones."minimal.test".port = 5354; };

  withoutResolved = evalHost {
    services.catallaxy.hostDns = {
      enable = true;
      zones."minimal.test".port = 5354;
    };
  };

  expected = {
    "systemd/resolved.conf.d/catallaxy-minimal-test.conf" =
      "[Resolve]\nDNS=127.0.0.1:5354\nDomains=~minimal.test\n";
    "systemd/resolved.conf.d/catallaxy-mesh-test.conf" =
      "[Resolve]\nDNS=127.0.0.1:5355\nDomains=~mesh.test\n";
  };

  actual = lib.mapAttrs (_: v: v.text) configured.environment.etc;

  failures =
    lib.optional (
      actual != expected
    ) "drop-ins are ${builtins.toJSON actual}, expected ${builtins.toJSON expected}"
    ++
      lib.optional (off.environment.etc != { })
        "a zone declared without enable still wrote ${builtins.toJSON (builtins.attrNames off.environment.etc)}"
    ++ lib.optional (lib.all (
      a: a.assertion
    ) withoutResolved.assertions) "enabling without services.resolved should assert, and did not";
in
{
  host-dns =
    if failures == [ ] then
      pkgs.runCommand "host-dns" { } "touch $out"
    else
      throw ("services.catallaxy.hostDns is wrong:\n  " + lib.concatStringsSep "\n  " failures);
}
