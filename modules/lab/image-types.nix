{ lib }:

let
  inherit (lib) mkOption types;

  # `docker.io` is left off, because that is what every manifest in the tree
  # writes today and emitting it would change every rendered image without
  # changing what any of them resolve to. A retarget sets the registry to
  # something else, so it appears exactly when it matters.
  mkRef =
    image:
    let
      host = lib.optionalString (image.registry != "docker.io") "${image.registry}/";
      tagged = host + image.repository + lib.optionalString (image.tag != null) ":${image.tag}";
    in
    tagged + lib.optionalString (image.digest != null) "@${image.digest}";
in
{
  inherit mkRef;

  # A partial image: every field optional, because a pin says what to change
  # rather than restating an image the floe already declared. Pinning a digest
  # without repeating the repository is the common case.
  pinType = types.submodule {
    options = {
      registry = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Registry to take this image from instead.";
      };
      repository = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Repository to use instead. Rarely needed; a mirror usually keeps the path.";
      };
      tag = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Tag to use instead.";
      };
      digest = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Digest to pin to. Set alongside the floe's tag rather than instead of it.";
      };
    };
  };

  # What a lab said about a floe's images, folded into what the floe declared.
  #
  # A pin wins over the blanket registry, which wins over the floe, so a lab
  # can point everything at a mirror and still say that one image comes from
  # somewhere else. `ref` is recomputed because a retargeted image whose
  # reference still named the old registry would be worse than no retarget.
  retarget =
    {
      registry ? null,
      pinned ? { },
    }:
    lib.mapAttrs (
      label: image:
      let
        pin = pinned.${label} or { };
        set = field: if (pin.${field} or null) != null then pin.${field} else image.${field};
        merged = {
          registry =
            if (pin.registry or null) != null then
              pin.registry
            else if registry != null then
              registry
            else
              image.registry;
          repository = set "repository";
          tag = set "tag";
          digest = set "digest";
        };
      in
      merged
      // {
        ref = mkRef merged;

        # What the floe itself said, kept because most declared images are a
        # chart's and reach the manifest as the chart's own default rather
        # than through anything the floe wrote. Rewriting that needs to know
        # the string to look for, and after the fold it is otherwise gone.
        declaredRef = mkRef image;
      }
    );
  # An image a floe needs, taken apart so it can be retargeted without anyone
  # parsing a string back out. `lab.images.pins` is the near-miss this
  # replaces: it holds the registry and the repository as one field, which is
  # exactly what makes pointing a lab at a mirror need a parser.
  imageType = types.submodule (
    { config, ... }:
    {
      options = {
        registry = mkOption {
          type = types.str;
          default = "docker.io";
          description = ''
            Host the image comes from. Replacing this is how a lab is pointed
            at a mirror, which is why it is separate from `repository`.
          '';
        };

        repository = mkOption {
          type = types.str;
          example = "grafana/grafana";
          description = "Path within the registry, with no host and no tag.";
        };

        tag = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Mutable. Carry a `digest` as well for a reference that cannot move.";
        };

        digest = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Immutable, as `sha256:…`. Written alongside the tag rather than instead of it.";
        };

        ref = mkOption {
          type = types.str;
          readOnly = true;
          description = "The assembled reference. Read this rather than rebuilding it.";
        };
      };

      config.ref = mkRef config;
    }
  );
}
