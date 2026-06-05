# Lab-level image management — pinning, policy, and reproducibility.
#
# Declare container image pins with optional digests for reproducibility.
# Components reference pins via `lab.images.pins.<name>`. The lint system
# checks rendered manifests against the image policy.
{ config, lib, ... }:

let
  inherit (lib) mkOption types;

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
          description = "Image tag (e.g., 11.4.0). Mutable — use digest for reproducibility.";
        };

        digest = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Image digest (e.g., sha256:abc123...). Immutable — ensures reproducibility.";
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
  };
}
