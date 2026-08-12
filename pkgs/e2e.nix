{
  lib,
  pkgs,
  cataWrapped,
}:

pkgs.writeShellApplication {
  name = "cata-e2e";

  runtimeInputs = [
    cataWrapped
    pkgs.jq
    pkgs.docker-client
    pkgs.gnugrep
  ];

  text = ''
    set -euo pipefail

    lab="''${1:-}"
    flake="''${CATA_E2E_FLAKE:-.}"

    labs=$(nix eval --json "$flake#legacyPackages.${pkgs.stdenv.hostPlatform.system}.e2eLabs")

    if [ -z "$lab" ]; then
      echo "usage: cata-e2e <lab>" >&2
      echo "" >&2
      echo "labs this can stand up:" >&2
      jq -r 'to_entries[] | select(.value.eligible) | "  " + .key' <<< "$labs" >&2
      echo "" >&2
      echo "and the ones it cannot, with the reason:" >&2
      jq -r 'to_entries[] | select(.value.eligible | not) | "  \(.key): \(.value.reasons | join("; "))"' <<< "$labs" >&2
      exit 64
    fi

    eligible=$(jq -r --arg lab "$lab" '.[$lab].eligible // false' <<< "$labs")
    if [ "$eligible" != "true" ]; then
      echo "cata-e2e: '$lab' cannot be stood up here:" >&2
      jq -r --arg lab "$lab" '.[$lab].reasons[]? | "  " + .' <<< "$labs" >&2
      exit 1
    fi

    running=$(docker ps --format '{{.Names}}' | grep -c '^catallaxy-' || true)
    if [ "$running" != "0" ]; then
      echo "cata-e2e: a lab is already up on this machine." >&2
      echo "  The host services take fixed container names and ports, so two" >&2
      echo "  labs cannot run at once. Tear the other one down first." >&2
      docker ps --format '  {{.Names}}' | grep '^  catallaxy-' >&2 || true
      exit 1
    fi

    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT

    step() { echo "" >&2; echo "=== $* ===" >&2; }

    env_file=$(jq -r --arg lab "$lab" '.[$lab].envFile // ""' <<< "$labs")
    if [ -n "$env_file" ]; then
      env_path="$flake/$env_file"
      if [ ! -f "$env_path" ]; then
        echo "cata-e2e: $lab sets lab.secrets.envFile to $env_file, and $flake does not have that file." >&2
        echo "  The path is relative to the flake root. If you just wrote the file, git add it." >&2
        exit 1
      fi
      step "loading secrets from $env_file"
      set -a
      # shellcheck disable=SC1090
      . "$env_path"
      set +a
    fi

    started=$SECONDS
    step "lab up"
    cata --flake "$flake#$lab" lab up
    up_seconds=$((SECONDS - started))

    step "lab verify"
    cata --flake "$flake#$lab" lab verify

    step "lab up again, which must change nothing"
    cata --flake "$flake#$lab" lab up

    step "lab destroy"
    cata --flake "$flake#$lab" lab destroy

    step "nothing survived the teardown"
    cata --flake "$flake#$lab" lab status --json > "$workdir/after.json"
    jq -e '[.services[] | select(.running)] == [] and [.clusters[] | select(.reachable)] == []' \
      "$workdir/after.json" > /dev/null \
      || { echo "teardown left services or clusters running:" >&2; jq . "$workdir/after.json" >&2; exit 1; }

    if docker network ls --format '{{.Name}}' | grep -qx "$lab"; then
      echo "docker network '$lab' survived the teardown" >&2
      exit 1
    fi

    echo "" >&2
    echo "$lab: up in ''${up_seconds}s, verified, idempotent, destroyed clean" >&2
  '';
}
