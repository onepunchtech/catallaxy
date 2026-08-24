{
  lib,
  pkgs,
}:

pkgs.writeShellApplication {
  name = "cata-refresh-digests";

  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnused
    pkgs.jq
  ];

  text = ''
    set -uo pipefail

    flake="''${CATA_FLAKE:-.}"
    outdir="''${1:-examples/labs/tests/manifest-digests}"

    if [ "''${1:-}" = "--help" ]; then
      echo "usage: cata-refresh-digests [outdir]" >&2
      echo "" >&2
      echo "Rewrites the committed record of what every lab renders, file by" >&2
      echo "file. Run it when a diff from manifest-digest-<lab> is intended," >&2
      echo "and read the diff before committing: it is the whole evidence" >&2
      echo "that a refactor changed what it meant to." >&2
      exit 64
    fi

    mkdir -p "$outdir"

    labs=$(nix eval --json "$flake#legacyPackages.${pkgs.stdenv.hostPlatform.system}.digestLabs" | jq -r '.[]')

    for lab in $labs; do
      pkg=$(nix build --no-link --print-out-paths \
        "$flake#legacyPackages.${pkgs.stdenv.hostPlatform.system}.labPackages.\"$lab\"")

      (
        cd "$pkg"
        find -L . -type f | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do
          hash=$(sed 's|/nix/store/[a-z0-9]\{32\}-|/nix/store/HASH-|g' "$f" \
            | sha256sum | cut -d' ' -f1)
          printf '%s  %s\n' "$hash" "$f"
        done
      ) > "$outdir/$lab.digest.txt"

      echo "  $lab" >&2
    done

    echo "refreshed $(printf '%s\n' "$labs" | wc -l) digests in $outdir" >&2
  '';
}
