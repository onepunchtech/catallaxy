{ config, lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    ;
  cfg = config.lab.registry;

  upstreamType = types.submodule {
    options = {
      host = mkOption {
        type = types.str;
        description = ''
          Bare upstream registry hostname (no scheme). This is the
          name containerd uses to look up its mirror; must exactly
          match the prefix in image references (`docker.io/foo/bar`,
          `codeberg.org/forgejo/forgejo`).
        '';
      };

      url = mkOption {
        type = types.str;
        description = ''
          Upstream registry URL (scheme + host + optional path) that
          zot will sync from. For most registries this is just
          `https://<host>`; the only oddity is the Docker Hub
          alias `docker.io` whose actual endpoint is
          `https://registry-1.docker.io`.
        '';
      };

      tlsVerify = mkOption {
        type = types.bool;
        default = true;
        description = "Whether zot validates the upstream's TLS cert.";
      };

      prefixes = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "forgejo/**" ];
        description = ''
          Repository prefixes (glob patterns) this upstream is
          responsible for. When set, zot's sync only consults this
          upstream for repos matching at least one prefix; other
          requests skip it entirely. When empty, the upstream is
          treated as an unfiltered catch-all (current behavior).

          Without this, zot iterates every configured upstream in
          declared order on every cold pull, regardless of
          containerd's `?ns=<host>` hint. Setting prefixes for
          single-tenant registries (e.g. codeberg.org → forgejo/**)
          eliminates the dead-end iteration that dominates cold-pull
          latency.
        '';
      };
    };
  };

  zotConfig = builtins.toJSON {
    distSpecVersion = "1.1.0";
    storage = {
      rootDirectory = "/var/lib/zot";
      dedupe = true;
    };
    http = {
      address = "0.0.0.0";
      port = "5000";

      compat = [ "docker2s2" ];
    };
    extensions.sync = {
      enable = true;
      registries = map (
        u:
        {
          urls = [ u.url ];
          onDemand = true;
          tlsVerify = u.tlsVerify;
        }
        // lib.optionalAttrs (u.prefixes != [ ]) {
          content = map (p: { prefix = p; }) u.prefixes;
        }
      ) cfg.upstreams;
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

      default = "ghcr.io/project-zot/zot-linux-amd64:v2.1.17";
      description = "Zot registry container image";
    };

    containerName = mkOption {
      type = types.str;
      default = "catallaxy-registry";
      description = "Docker container name for the registry";
    };

    warmCache = mkOption {
      type = types.bool;
      default = true;
      description = ''
        When enabled, `cata lab up` runs a `warm-cache` step right
        after `setup-services` that walks the lab's `images.txt`
        (one entry per container image referenced by any rendered
        manifest) and `crane copy`s each into the lab registry.

        This guarantees every cluster Deployment hits a warm cache
        instead of triggering zot's on-demand sync at kapp-apply
        time: where the kubelet's image-pull-progress-deadline
        and kapp's ProgressDeadlineExceeded would otherwise race
        against a cold upstream pull. crane bypasses zot's sync
        extension (direct push), so this step is robust against
        zot config quirks.

        Set `false` only if you're iterating on a cluster apply
        and want to skip the up-front warm time.
      '';
    };

    upstreams = mkOption {
      type = types.listOf upstreamType;

      default = [
        {
          host = "codeberg.org";
          url = "https://codeberg.org";
          prefixes = [ "forgejo/**" ];
        }
        {
          host = "registry.k8s.io";
          url = "https://registry.k8s.io";
        }
        {
          host = "ghcr.io";
          url = "https://ghcr.io";
        }
        {
          host = "quay.io";
          url = "https://quay.io";
        }
        {
          host = "docker.io";
          url = "https://registry-1.docker.io";
        }
      ];
      description = ''
        Public registries that the lab's zot proxies via pull-through.
        Each entry generates:
          - a zot `extensions.sync.registries` entry (the cache
            backend), AND
          - a `/etc/containerd/certs.d/<host>/hosts.toml` mirror
            entry on every k3d node (CLI-emitted) pointing at the
            zot endpoint.

        Add a new entry when a component pulls from an upstream not
        in the default list; without the matching `host`,
        containerd will go straight to the public registry, bypass
        the cache, and depend on the node's resolver fall-through
        to public DNS.
      '';
    };

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

      readyProbe = {
        kind = "http";
        host = "127.0.0.1";
        port = cfg.port;
        path = "/v2/";
        expectedStatus = 200;
        timeout = "60s";
      };
      volumes = {
        "/etc/zot/config.json" = {
          content = zotConfig;
        };

        "/var/lib/zot" = {
          persist = "data";
        };
      };
    };
  };
}
