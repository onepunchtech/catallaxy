{ config, lib, ... }:

let
  cfg = config.services.catallaxy.hostDns;

  dropIn = zone: settings: {
    name = "systemd/resolved.conf.d/catallaxy-${lib.replaceStrings [ "." ] [ "-" ] zone}.conf";
    value.text = ''
      [Resolve]
      DNS=${settings.host}:${toString settings.port}
      Domains=~${zone}
    '';
  };
in
{
  options.services.catallaxy.hostDns = {
    enable = lib.mkEnableOption "resolving catallaxy lab zones through each lab's DNS container";

    zones = lib.mkOption {
      default = { };
      example = lib.literalExpression ''
        {
          "minimal.test" = { port = 5354; };
          "mesh.test".port = 5355;
        }
      '';
      description = ''
        Lab DNS zones to resolve through a lab's resolver, keyed by zone.
        The values are what `cata lab dns` prints for a lab: its
        `lab.dns.zone`, and the host and port its DNS container listens on.

        This is the declarative half of `cata lab dns --setup`. That command
        writes the same drop-ins with sudo, which a `nixos-rebuild` then
        reverts, so pick one: the command for a machine NixOS does not
        manage, this for one it does.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            host = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1";
              description = "Address the lab's DNS container listens on.";
            };

            port = lib.mkOption {
              type = lib.types.port;
              description = "Port the lab's DNS container listens on.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.enable && cfg.zones != { }) {
    assertions = [
      {
        assertion = config.services.resolved.enable;
        message = ''
          services.catallaxy.hostDns writes systemd-resolved drop-ins, so it
          needs services.resolved.enable. For a resolver this host manages
          another way, take the dnsmasq line from `cata lab dns` instead.
        '';
      }
    ];

    environment.etc = lib.mapAttrs' dropIn cfg.zones;
  };
}
