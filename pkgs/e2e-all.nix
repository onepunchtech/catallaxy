{
  lib,
  pkgs,
  e2e,
}:

pkgs.writeShellApplication {
  name = "cata-e2e-all";

  runtimeInputs = [
    e2e
    pkgs.jq
    pkgs.coreutils
  ];

  text = ''
    set -uo pipefail

    flake="''${CATA_E2E_FLAKE:-.}"
    jobs="''${CATA_E2E_JOBS:-2}"

    if [ "''${1:-}" = "--help" ]; then
      echo "usage: cata-e2e-all [--jobs N]" >&2
      echo "" >&2
      echo "Runs every lab e2e can stand up, N at a time. Each lab is a" >&2
      echo "separate cata-e2e run that asserts its own teardown, so a" >&2
      echo "failure names one lab and the others still finish." >&2
      echo "" >&2
      echo "  --jobs N   labs at once (default $jobs, or CATA_E2E_JOBS)" >&2
      exit 64
    fi

    if [ "''${1:-}" = "--jobs" ]; then
      jobs="''${2:?--jobs needs a number}"
    fi

    labs=$(nix eval --json "$flake#legacyPackages.${pkgs.stdenv.hostPlatform.system}.e2eLabs" \
      | jq -r 'to_entries[] | select(.value.eligible) | .key')

    if [ -z "$labs" ]; then
      echo "cata-e2e-all: no lab is eligible" >&2
      exit 1
    fi

    outdir=$(mktemp -d)
    trap 'rm -rf "$outdir"' EXIT

    count=$(printf '%s\n' "$labs" | wc -l)
    echo "running $count labs, $jobs at a time" >&2
    echo "" >&2

    # Each lab's output goes to its own file rather than the terminal.
    # Interleaved logs from labs running at once are unreadable, and the one
    # that failed is the one worth printing.
    run_one() {
      lab="$1"
      if cata-e2e "$lab" > "$outdir/$lab.log" 2>&1; then
        echo "  PASS $lab" >&2
        tail -1 "$outdir/$lab.log" >&2
      else
        echo "  FAIL $lab" >&2
        echo "$lab" >> "$outdir/failed"
      fi
    }
    export -f run_one
    export outdir

    printf '%s\n' "$labs" \
      | xargs -P "$jobs" -I{} bash -c 'run_one "$@"' _ {}

    echo "" >&2
    if [ -s "$outdir/failed" ]; then
      while read -r lab; do
        echo "=== $lab ===" >&2
        cat "$outdir/$lab.log" >&2
        echo "" >&2
      done < "$outdir/failed"
      failed=$(wc -l < "$outdir/failed")
      echo "$failed of $count labs failed" >&2
      exit 1
    fi

    echo "all $count labs passed" >&2
  '';
}
