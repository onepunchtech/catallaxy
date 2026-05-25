{ config, lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    ;
  cfg = config.lab.registry;

  # Generate Zot config as JSON
  zotConfig = builtins.toJSON {
    distSpecVersion = "1.1.0";
    storage = {
      rootDirectory = "/var/lib/zot";
      dedupe = true;
    };
    http = {
      address = "0.0.0.0";
      port = "5000";
    };
    extensions.sync = {
      enable = true;
      registries = [
        {
          urls = [ "https://registry-1.docker.io" ];
          onDemand = true;
          tlsVerify = true;
        }
        {
          urls = [ "https://quay.io" ];
          onDemand = true;
          tlsVerify = true;
        }
        {
          urls = [ "https://ghcr.io" ];
          onDemand = true;
          tlsVerify = true;
        }
        {
          urls = [ "https://registry.k8s.io" ];
          onDemand = true;
          tlsVerify = true;
        }
      ];
    };
  };
in
{
  options.lab.registry = {
    enable = mkEnableOption "Lab registry for image caching (Zot OCI registry as pull-through cache)";

    port = mkOption {
      type = types.port;
      default = 5050;
      description = "Host port for the registry";
    };

    image = mkOption {
      type = types.str;
      default = "ghcr.io/project-zot/zot-linux-amd64:v2.1.1";
      description = "Zot registry container image";
    };

    containerName = mkOption {
      type = types.str;
      default = "catallaxy-registry";
      description = "Docker container name for the registry";
    };

    # Computed: the service definition consumed by evalLabJSON/CLI
    service = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed container service definition for the lab registry";
    };
  };

  config.lab.registry = mkIf cfg.enable {
    service = {
      description = "Zot OCI registry (image cache)";
      container = cfg.containerName;
      image = cfg.image;
      ports = [ "${toString cfg.port}:5000" ];
      volumes = {
        "/etc/zot/config.json" = {
          content = zotConfig;
        };
      };
    };
  };
}
