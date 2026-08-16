{
  lib,
  pkgs,
  self,
}:

let
  imageUtil = import ../../lib/render/images.nix { inherit lib pkgs; };

  # `.spec.jobTemplate.spec.template.spec.containers` as the Rust source
  # spells it, whitespace removed so rustfmt's line wrapping does not matter.
  asRustSegments =
    path:
    let
      segments = lib.filter (s: s != "") (lib.splitString "." path);
    in
    lib.concatMapStringsSep "," (s: "\"${s}\"") segments;
in
{
  # The scrape that feeds `cata images lock` and the image-pin lint read the
  # same container paths from two lists in two languages. They drifted: the
  # lint was missing a CronJob's init containers, so those images were
  # lockable and unlintable, and the lock rewrote a digest into something
  # requireDigest could not have flagged. A comment claimed the lists matched.
  image-paths-agree-across-languages =
    pkgs.runCommand "image-paths-agree-across-languages"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        src=${self}/cli/src/lint/rules/image_pin.rs
        flat=$(tr -d ' \n' < "$src")

        missing=""
        ${lib.concatMapStringsSep "\n" (path: ''
          case "$flat" in
            *'${asRustSegments path}'*) ;;
            *) missing="$missing  ${path}"$'\n' ;;
          esac
        '') imageUtil.scrapePaths}

        if [ -n "$missing" ]; then
          echo "the image-pin lint does not read paths the scrape does:" >&2
          printf '%s' "$missing" >&2
          echo "" >&2
          echo "An image the scrape finds is one the lock can pin, so a path" >&2
          echo "only the scrape has is rewritten without ever being linted." >&2
          exit 1
        fi

        # And the reverse: a path only the lint has flags images the lock can
        # never carry, so requireDigest becomes unsatisfiable.
        declared=$(rg --count-matches '&\[$|&\["spec"' "$src" || true)
        want=${toString (builtins.length imageUtil.scrapePaths)}
        got=$(awk '/let containers_paths/,/^    \];/' "$src" | grep -c '"containers"\|"initContainers"')
        if [ "$got" != "$want" ]; then
          echo "the lint reads $got container paths and the scrape has $want" >&2
          exit 1
        fi

        touch $out
      '';
}
