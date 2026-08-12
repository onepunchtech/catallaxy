{
  lib,
  pkgs,
  cataWrapped,
}:

pkgs.writeShellApplication {
  name = "cata-e2e";

  runtimeInputs = [
    cataWrapped
    pkgs.age
    pkgs.jq
    pkgs.docker-client
    pkgs.gnugrep
    pkgs.gnused
  ];

  text = ''
    set -euo pipefail

    lab="''${1:-}"
    flake="''${CATA_E2E_FLAKE:-.}"

    if [ -z "$lab" ]; then
      echo "usage: cata-e2e <lab>" >&2
      echo "" >&2
      echo "labs this can stand up:" >&2
      nix eval --json "$flake#legacyPackages.${pkgs.stdenv.hostPlatform.system}.e2eLabs" \
        | jq -r 'to_entries[] | select(.value.eligible) | "  " + .key' >&2
      echo "" >&2
      echo "and the ones it cannot, with the reason:" >&2
      nix eval --json "$flake#legacyPackages.${pkgs.stdenv.hostPlatform.system}.e2eLabs" \
        | jq -r 'to_entries[] | select(.value.eligible | not) | "  \(.key): \(.value.reasons | join("; "))"' >&2
      exit 64
    fi

    eligible=$(nix eval --json "$flake#legacyPackages.${pkgs.stdenv.hostPlatform.system}.e2eLabs" \
      | jq -r --arg lab "$lab" '.[$lab].eligible // false')
    if [ "$eligible" != "true" ]; then
      echo "cata-e2e: '$lab' cannot be stood up here:" >&2
      nix eval --json "$flake#legacyPackages.${pkgs.stdenv.hostPlatform.system}.e2eLabs" \
        | jq -r --arg lab "$lab" '.[$lab].reasons[]? | "  " + .' >&2
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
    restore_sops=""
    cleanup() {
      if [ -n "$restore_sops" ] && [ -f "$restore_sops" ]; then
        cp "$restore_sops" .sops.yaml
      fi
      rm -rf "$workdir"
    }
    trap cleanup EXIT

    step() { echo "" >&2; echo "=== $* ===" >&2; }

    # A lab whose plan has ensure-secrets needs its store to exist first.
    # Every key in it is generated, which is what makes the lab eligible at
    # all, so the key is made here and thrown away on exit. The rule is
    # merged into .sops.yaml rather than prepended as a second document,
    # because two creation_rules keys is not valid YAML.
    if cata --flake "$flake#$lab" lab plan --stable | grep -q '^\[[0-9]*\] ensure-secrets'; then
      step "generating secret stores"
      age-keygen -o "$workdir/age.key" 2>/dev/null
      recipient=$(age-keygen -y "$workdir/age.key")
      restore_sops="$workdir/sops.yaml.orig"
      cp .sops.yaml "$restore_sops"
      {
        echo "creation_rules:"
        echo "  - path_regex: secrets/.*\.enc\.yaml\$"
        echo "    age: $recipient"
        sed '0,/^creation_rules:/d' .sops.yaml
      } > .sops.yaml.e2e
      mv .sops.yaml.e2e .sops.yaml
      export SOPS_AGE_KEY_FILE="$workdir/age.key"
      cata --flake "$flake#$lab" secrets generate
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
