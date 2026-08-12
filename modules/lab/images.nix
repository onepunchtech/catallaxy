{ config, lib, ... }:

let
  inherit (lib)
    mkOption
    types
    mapAttrs
    mapAttrsToList
    ;

  pinType = types.submodule (
    { config, ... }:
    {
      options = {
        image = mkOption {
          type = types.str;
          description = "Full image path (e.g., docker.io/grafana/grafana)";
        };

        tag = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Image tag (e.g., 11.4.0). Mutable; use digest for reproducibility.";
        };

        digest = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Image digest (e.g., sha256:abc123...). Immutable; ensures reproducibility.";
        };

        ref = mkOption {
          type = types.str;
          readOnly = true;
          description = "Computed full image reference (image:tag@digest)";
        };
      };

      config.ref =
        let
          base = config.image;
          withTag = if config.tag != null then "${base}:${config.tag}" else base;
          withDigest =
            if config.digest != null then
              if config.tag != null then "${base}:${config.tag}@${config.digest}" else "${base}@${config.digest}"
            else
              withTag;
        in
        withDigest;
    }
  );
in
{
  options.lab.images = {
    requireDigest = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When true, the lint check errors on container images without digest pins.
        Use this to enforce reproducible deployments.
      '';
    };

    allowedRegistries = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        When non-empty, the lint check warns about images from registries not in this list.
        Example: ["ghcr.io" "registry.k8s.io" "docker.io"]
      '';
    };

    pins = mkOption {
      type = types.attrsOf pinType;
      default = { };
      description = ''
        Pinned container images. Each pin declares an image with optional tag and digest.
        Components can reference pins via `lab.images.pins.<name>.ref` to get
        the full image reference string.

        Example:
          lab.images.pins.grafana = {
            image = "docker.io/grafana/grafana";
            tag = "11.4.0";
            digest = "sha256:abc123...";
          };
      '';
    };

    publish = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, config, ... }:
          {
            options = {
              source = mkOption {
                type = types.either types.path types.str;
                description = ''
                  Flake reference (path like `../elitemoneyranger` or URI
                  like `git+https://...`). Must expose
                  `packages.<system>.<attr>` producing a docker-archive
                  derivation (e.g. dockerTools.buildLayeredImage).
                '';
              };

              attr = mkOption {
                type = types.str;
                example = "schema-image";
                description = "Flake output attribute under packages.<system>.";
              };

              tag = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Explicit tag. When null, the CLI evaluates
                  `<source>#versions-json` and reads the value at
                  `tagFrom`. Lets each project keep one source of truth
                  for its version (Cargo.toml, package.json, etc.).
                '';
              };

              tagFrom = mkOption {
                type = types.nullOr types.str;
                default = name;
                description = ''
                  When `tag` is null, the JSON key to read from
                  `<source>#versions-json`. Defaults to the image name.
                '';
              };

              alsoLatest = mkOption {
                type = types.bool;
                default = true;
                description = "Also push the image as `:latest`.";
              };

              destination = mkOption {
                type = types.submodule {
                  options = {
                    registry = mkOption {
                      type = types.str;
                      example = "registry.lab.test";
                      description = "OCI registry hostname (no scheme).";
                    };
                    repository = mkOption {
                      type = types.str;
                      example = "internal/emr-schema";
                      description = "Repository path within the registry.";
                    };
                  };
                };
              };

              credentialsRef = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      cluster = mkOption {
                        type = types.str;
                        description = "Cluster hosting the dockerconfigjson Secret.";
                      };
                      namespace = mkOption {
                        type = types.str;
                        default = "harbor";
                      };
                      secretName = mkOption {
                        type = types.str;
                        description = "Secret of type kubernetes.io/dockerconfigjson.";
                      };
                    };
                  }
                );
                default = null;
                description = ''
                  Cross-cluster reference to a dockerconfigjson Secret.
                  The CLI fetches it with kubectl, decodes the auth blob,
                  and passes --dest-creds to skopeo. Null = anonymous push.
                '';
              };

              dependsOn = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = ''
                  Cluster names that must finish `deploy-manifests` before
                  this image is pushed. When empty, the planner auto-derives
                  by matching `destination.registry` against any cluster's
                  `floes.harbor.domain`.
                '';
              };

              waitFor = mkOption {
                type = types.listOf (
                  types.submodule {
                    options = {
                      cluster = mkOption {
                        type = types.str;
                        description = "Cluster context to wait in.";
                      };
                      kind = mkOption {
                        type = types.str;
                        description = ''Kubernetes Kind (e.g. "Job", "Deployment", "Pod"). Passed to kubectl wait.'';
                      };
                      name = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = ''
                          Resource name. Mutually exclusive with
                          `labelSelector`. Catallaxy-emitted Jobs from
                          `mkIdempotentJob` have hashed names, so prefer
                          `labelSelector` for those.
                        '';
                      };
                      labelSelector = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = ''
                          Label selector (e.g.
                          `app.kubernetes.io/component=netbird-routing`).
                          Mutually exclusive with `name`. Durable across
                          mkIdempotentJob's content-hash rotations.
                        '';
                      };
                      namespace = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Resource namespace (null for cluster-scoped).";
                      };
                      condition = mkOption {
                        type = types.str;
                        default = "Ready";
                        description = ''
                          Condition to wait for. Passed verbatim as
                          `kubectl wait --for=condition=<this>`. Common
                          values: `Ready` (Pods), `Available`
                          (Deployments), `Complete` (Jobs).
                        '';
                      };
                      timeout = mkOption {
                        type = types.str;
                        default = "10m";
                        description = "kubectl wait --timeout value.";
                      };
                    };
                  }
                );
                default = [ ];
                description = ''
                  Kubernetes resources that must reach `condition` before
                  this image is pushed. Useful when the destination
                  registry is mesh-only and the mesh comes up via an
                  in-cluster Job, or any case where image push depends on
                  runtime state rather than just `deploy-manifests`
                  completion. Distinct from `dependsOn`, which orders
                  cross-cluster deploys.
                '';
              };

              ref = mkOption {
                type = types.str;
                readOnly = true;
                description = ''
                  Computed reference `<registry>/<repository>:<tag>` for
                  consumers (e.g. `lab.images.publish.emr-schema.ref` to
                  use in a workload's `image: ...` field). When `tag` is
                  null the placeholder `{{TAG}}` appears: consumers
                  needing the real string at eval time should set `tag`
                  explicitly.
                '';
              };
            };

            config.ref =
              let
                t = if config.tag != null then config.tag else "{{TAG}}";
              in
              "${config.destination.registry}/${config.destination.repository}:${t}";
          }
        )
      );
      default = { };
      description = ''
        Declarative image pipeline. Each entry is built via Nix and
        pushed by `cata lab up` before any consumer cluster deploys.
      '';
    };
  };

  options.lab.out.publishImages = mkOption {
    type = types.listOf types.attrs;
    readOnly = true;
    internal = true;
    description = "Computed publish-images step payloads, one entry per image.";
  };

  config.lab.out.publishImages = mapAttrsToList (name: img: {
    inherit name;
    source = toString img.source;
    attr = img.attr;
    tag = img.tag;
    tagFrom = img.tagFrom;
    alsoLatest = img.alsoLatest;
    destination = "${img.destination.registry}/${img.destination.repository}";
    destinationRegistry = img.destination.registry;
    destinationRepository = img.destination.repository;
    credentials =
      if img.credentialsRef != null then
        {
          cluster = img.credentialsRef.cluster;
          namespace = img.credentialsRef.namespace;
          secretName = img.credentialsRef.secretName;
        }
      else
        null;
    dependsOn = img.dependsOn;

    waitFor = img.waitFor;
  }) config.lab.images.publish;
}
