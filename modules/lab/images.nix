{ config, lib, ... }:

let
  imageTypes = import ./image-types.nix { inherit lib; };

  inherit (lib)
    mkOption
    types
    literalExpression
    mapAttrsToList
    ;

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

    wait = {
      kubectl = mkOption {
        type = imageTypes.imageType;
        default = {
          repository = "alpine/k8s";
          tag = "1.32.4";
        };
        description = ''
          Image the probe containers catallaxy renders run kubectl from.

          Not any floe's software: this and the two below are what every
          waiter in every lab rides, and they were three literals in a shared
          helper that nothing could reach.
        '';
      };

      curl = mkOption {
        type = imageTypes.imageType;
        default = {
          repository = "curlimages/curl";
          tag = "8.10.1";
        };
        description = "Image for `http` probes.";
      };

      network = mkOption {
        type = imageTypes.imageType;
        default = {
          repository = "busybox";
          tag = "1.36";
        };
        description = "Image for `tcp` and `dns` probes.";
      };
    };

    lockFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = lib.literalExpression "./images.lock.json";
      description = ''
        A file mapping each image reference to its digest, written by
        `cata images lock`. Every reference in it is rewritten to carry its
        digest as the manifests are rendered, which is what makes
        `requireDigest` something a lab can turn on.

        Null rewrites nothing, and that is deliberate rather than merely a
        default: a lab has to be able to build before a lockfile exists, or
        there would be no way to generate one.

        The path is relative to the lab that sets it, not to catallaxy.
      '';
    };

    registry = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "registry.internal";
      description = ''
        Registry every floe's images are taken from, whatever each floe
        declared. This is how a lab is pointed at a mirror or an internal
        registry in one line rather than in one line per image.

        Repositories and tags are untouched, so `registry.internal` has to
        carry the same paths upstream does. A pull-through cache does; a
        hand-curated registry is what `lab.images.pinned` is for.
      '';
    };

    pinned = mkOption {
      type = types.attrsOf (types.attrsOf imageTypes.pinType);
      default = { };
      example = literalExpression ''
        {
          openbao.server = {
            registry = "registry.internal";
            digest = "sha256:abc123...";
          };
        }
      '';
      description = ''
        Per-floe image overrides, as `<floe>.<label>`, where the label is the
        one the floe declared in `floes.<floe>.images`.

        Matching is by label and nothing else: a lab names the image it means
        rather than catallaxy inferring from a repository that may appear in
        more than one floe. A pin beats `lab.images.registry`, and any field
        left unset keeps what the floe declared.
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
                description = "Where the image is pushed.";
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
                        description = "Namespace the credentials Secret lives in.";
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
