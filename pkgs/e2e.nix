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

    # Everything this lab owns, and nothing another one does. Host services
    # are `catallaxy-<lab>-<svc>`; k3d nodes are `k3d-<prefix>-...` and Talos
    # nodes `<prefix>-...`, where the prefix is the lab name with separators
    # flattened, the same way `lab.contextPrefix` derives it.
    #
    # This used to be every container matching `^catallaxy-`, which is how the
    # script came to refuse to run at all beside another lab: it could not tell
    # whose leftovers it was looking at.
    prefix=$(printf '%s' "$lab" | tr './_ ' '----')
    ours="^(catallaxy-$lab|k3d-$prefix|$prefix)-"

    our_containers() {
      docker ps -a --format '{{.Names}} {{.ID}} {{.CreatedAt}}' \
        | grep -E "$ours" | sort || true
    }

    if [ -n "$(our_containers)" ]; then
      echo "cata-e2e: '$lab' already has containers on this machine." >&2
      echo "  This asserts that nothing survives its own teardown, so it has to" >&2
      echo "  start from nothing. Other labs may be up; only this one is in the" >&2
      echo "  way." >&2
      echo "" >&2
      our_containers >&2
      echo "" >&2
      echo "  Remove them with:" >&2
      echo "    cata lab cleanup $lab --yes" >&2
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
    cata --flake "$flake#$lab" lab up --infra
    up_seconds=$((SECONDS - started))

    step "lab verify"
    cata --flake "$flake#$lab" lab verify

    step "lab up again, which must change nothing"
    our_containers > "$workdir/containers.before"
    cata --flake "$flake#$lab" lab up --infra 2>&1 | tee "$workdir/second-up.log"
    our_containers > "$workdir/containers.after"

    if ! diff -u "$workdir/containers.before" "$workdir/containers.after"; then
      echo "" >&2
      echo "the second 'lab up' created, destroyed or replaced a container." >&2
      echo "  Running it against a lab that already matches the declaration" >&2
      echo "  must be a no-op. A container whose ID or creation time moved was" >&2
      echo "  rebuilt, which means something read as drifted when it was not." >&2
      exit 1
    fi

    if grep -qE 'no longer matches|will be destroyed and rebuilt' "$workdir/second-up.log"; then
      echo "" >&2
      echo "the second 'lab up' reported drift against an unchanged declaration:" >&2
      grep -E 'no longer matches|will be destroyed and rebuilt' "$workdir/second-up.log" >&2
      echo "" >&2
      echo "  Either the shape record does not round-trip what was built, or a" >&2
      echo "  field is being compared that the cluster never had." >&2
      exit 1
    fi

    if grep -qE 'no longer declares' "$workdir/second-up.log"; then
      echo "" >&2
      echo "the second 'lab up' pruned resources from an unchanged declaration:" >&2
      grep -E 'no longer declares' "$workdir/second-up.log" >&2
      echo "" >&2
      echo "  Pruning compares what the cluster is labelled with against what" >&2
      echo "  the declaration names. Deleting anything here means the two" >&2
      echo "  disagree about a resource nobody changed, and the next lab to" >&2
      echo "  run loses it. A synthetic bundle missing from .declared-bundles" >&2
      echo "  did exactly this to the lab's own namespaces." >&2
      exit 1
    fi

    step "lab destroy"
    cata --flake "$flake#$lab" lab destroy --infra

    step "nothing of this lab survived the teardown"
    if [ -n "$(our_containers)" ]; then
      echo "teardown left containers behind:" >&2
      our_containers >&2
      exit 1
    fi

    cata --flake "$flake#$lab" lab status --json > "$workdir/after.json"
    jq -e '[.services[] | select(.running)] == [] and [.clusters[] | select(.reachable)] == []' \
      "$workdir/after.json" > /dev/null \
      || { echo "teardown left services or clusters running:" >&2; jq . "$workdir/after.json" >&2; exit 1; }

    if docker network ls --format '{{.Name}}' | grep -qx "$lab"; then
      echo "docker network '$lab' survived the teardown" >&2
      exit 1
    fi

    # A stack's state is the only record of what it made. Teardown claiming
    # the lab is gone while state still lists resources would be a claim
    # about a cloud account nobody checked.
    infra_dir="$HOME/.local/share/catallaxy/infra/$lab"
    if [ -d "$infra_dir" ]; then
      for state in "$infra_dir"/*/*.tfstate; do
        [ -e "$state" ] || continue
        left=$(jq '[.resources[]?] | length' "$state")
        if [ "$left" != "0" ]; then
          echo "teardown left $left resource(s) in $state" >&2
          jq '[.resources[]? | .type + "." + .name]' "$state" >&2
          exit 1
        fi
      done
    fi

    echo "" >&2
    echo "$lab: up in ''${up_seconds}s, verified, idempotent, destroyed clean" >&2
  '';
}
