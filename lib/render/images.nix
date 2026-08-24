{ lib, pkgs }:

let
  # The lockfile a lab commits maps a reference to its digest, because that is
  # what a human reads and reviews. The rewrite wants the finished reference,
  # so it is derived here rather than assembled in yq, which has no `if`.
  pinnedRefs = lock: lib.mapAttrs (ref: digest: "${ref}@${digest}") (lock.images or { });
in
rec {

  # Two selectors, deliberately different, and the difference is the reason
  # this file exists rather than the expressions living where they are used.
  #
  # The rewrite descends recursively, which visits only nodes that are already
  # there. An explicit path list cannot be used: `|=` against a path a
  # document does not have *creates* it, so every ConfigMap would grow an
  # empty `spec.containers`. Descending is also safe against false positives,
  # because a value only changes if it is a key in the lock, and the lock only
  # holds real references.
  applyToDir =
    {
      lock,
      registry ? null,
      overrides ? { },
      exempt ? [ ],
    }:
    dir:
    let
      refs = pinnedRefs lock;

      lockJson = pkgs.writeText "image-lock.json" (builtins.toJSON { images = refs; });

      # Table-filtered exactly as the lock is, and for the same reason: it
      # only changes a string it names, so it cannot touch anything else.
      overrideJson = pkgs.writeText "image-overrides.json" (builtins.toJSON { images = overrides; });

      patch = lib.optionalString (overrides != { }) ''
        (.. | select(has("image")).image) |= (
          . as $i | (load("${overrideJson}").images[$i] // $i)
        )
      '';

      pin = lib.optionalString (refs != { }) ''
        (.. | select(has("image")).image) |= (
          . as $i | (load("${lockJson}").images[$i] // $i)
        )
      '';

      # Retargeting has no table to filter by, which makes it the one rewrite
      # that has to say for itself what an image is. Two guards:
      #
      # ConfigMaps and Secrets are skipped, because they are where a chart
      # puts arbitrary text and an `image:` key in there is somebody's config,
      # not a workload. Every other kind is fair game, which is what lets this
      # reach an operator CR's `spec.image`.
      #
      # And the value has to carry a path or a tag. A registry serves
      # `repo:tag`, so a bare word under an `image` key is not a reference
      # anyone can pull and is left alone.
      #
      # The substitution itself: a first segment carrying a dot or a colon and
      # followed by a slash is a hostname and is replaced, anything else means
      # the registry was implicit and one is prepended. The same rule the Rust
      # parser uses, so a lab that retargets and then runs `cata images` does
      # not get two answers. An optional group rather than a branch, because
      # yq has no `if` usable here.

      # And a pin outranks the blanket registry, which it can only do if the
      # file pass knows what was pinned. By the time this runs the pinned
      # reference is already in the manifest; without this the blanket
      # rewrite would move it straight back, and `pinned` would silently do
      # nothing on any lab that also set `registry`.
      exemptJson = pkgs.writeText "image-exempt.json" (
        builtins.toJSON { refs = lib.genAttrs exempt (_: true); }
      );

      keep = lib.optionalString (exempt != [ ]) ''
        | select(. as $i | load("${exemptJson}").refs[$i] != true)
      '';

      retarget = lib.optionalString (registry != null) ''
        (select(.kind != "ConfigMap" and .kind != "Secret")
          | .. | select(has("image")).image | select(test("[/:]"))${keep}
        ) |= sub("^([^/]*[.:][^/]*/)?", "${registry}/")
      '';

      # Order matters: a pin names the reference the floe declared, so it has
      # to be applied while that string is still in the file, before the
      # blanket registry moves everything.
      passes = lib.filter (e: e != "") [
        patch
        pin
        retarget
      ];
    in
    lib.optionalString (passes != [ ]) ''
      find -L "${dir}" -name '*.yaml' -type f | while read -r f; do
        ${lib.concatMapStringsSep "\n  " (
          expr: "${pkgs.yq-go}/bin/yq -P -i '${expr}' \"$f\" 2>/dev/null || true"
        ) passes}
      done
    '';

  # The scrape stays on an explicit path list, because what it produces feeds
  # `cata images mirror` and `prefetch`, which try to pull whatever is in it.
  # Descending would sweep up any string under an `image:` key.
  #
  # These are the paths `image-pin` lints, so everything the lint can flag is
  # something the lock can carry. A kind outside them, such as an operator CR
  # with its own `spec.image`, is invisible to both.
  scrapePaths = [
    ".spec.containers"
    ".spec.initContainers"
    ".spec.template.spec.containers"
    ".spec.template.spec.initContainers"
    ".spec.jobTemplate.spec.template.spec.containers"
    ".spec.jobTemplate.spec.template.spec.initContainers"
  ];

  # `select(. != null)` belongs here rather than in each caller's pipeline. A
  # container with no `image` yields null, and both callers used to let that
  # null through and then strip it with `grep -v '^null$'` — which also
  # deletes a real image legitimately named `null`, and which had to be
  # repeated identically everywhere the scrape was used.
  scrapeExpr = "(${
    lib.concatMapStringsSep ", " (p: "${p}[]?.image") scrapePaths
  }) | select(. != null)";
}
