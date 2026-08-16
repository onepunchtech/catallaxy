{ pkgs, self }:

{
  cli-no-lint-suppressions =
    pkgs.runCommand "cli-no-lint-suppressions"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        found=$(rg --line-number '#!?\[(allow|expect)\(' ${self}/cli/src ${self}/cli/tests || true)

        if [ -n "$found" ]; then
          echo "cli carries lint suppressions:" >&2
          echo "$found" >&2
          echo "" >&2
          echo "A suppression hides the warning from `cargo clippy -- -D warnings` too," >&2
          echo "so the cli-clippy check cannot see what it covers. Fix the code the lint" >&2
          echo "points at. If a suppression is genuinely right, delete this check in the" >&2
          echo "same commit and say why in the message." >&2
          exit 1
        fi

        touch $out
      '';

  kubectl-is-spawned-one-way =
    pkgs.runCommand "kubectl-is-spawned-one-way"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        found=$(rg --line-number 'Command::new\("kubectl"\)' ${self}/cli/src || true)
        count=$(printf '%s' "$found" | grep -c . || true)

        if [ "$count" != "1" ]; then
          echo "kubectl is spawned $count different ways:" >&2
          echo "$found" >&2
          echo "" >&2
          echo "It used to be two, and the difference was whether the subprocess got" >&2
          echo "the lab's merged CA bundle. Which callers had it was historical. Every" >&2
          echo "kubectl goes through io::kubectl::command(), which is the one site this" >&2
          echo "check expects to find." >&2
          exit 1
        fi

        touch $out
      '';

  cli-parses-nothing-it-ignores =
    pkgs.runCommand "cli-parses-nothing-it-ignores"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        orphaned=""

        for file in cluster.rs lab.rs; do
          src=${self}/cli/src/domain/$file

          # A serde(flatten) catch-all exists to round-trip unknown keys, so it
          # has no reader by design.
          flattened=$(grep -A 1 'serde(flatten)' "$src" \
            | rg --only-matching '^    pub ([a-z][a-z0-9_]+):' \
            | sed 's/^    pub //; s/:$//' | sort -u)

          fields=$(rg --only-matching '^    pub ([a-z][a-z0-9_]+):' "$src" \
            | sed 's/^    pub //; s/:$//' | sort -u)

          if [ -n "$flattened" ]; then
            fields=$(comm -23 <(echo "$fields") <(echo "$flattened"))
          fi

          for field in $fields; do
            declarations=$(rg --count-matches "^    pub $field:" ${self}/cli/src --glob '*.rs' \
              | awk -F: '{ total += $NF } END { print total + 0 }')
            references=$(rg --count-matches "\b$field\b" ${self}/cli/src --glob '*.rs' \
              | awk -F: '{ total += $NF } END { print total + 0 }')

            if [ "$references" -le "$declarations" ]; then
              orphaned="$orphaned  domain/$file: $field"$'\n'
            fi
          done
        done

        if [ -n "$orphaned" ]; then
          echo "the CLI parses fields out of the lab config and then never reads them:" >&2
          echo "$orphaned" >&2
          echo "Nix computes and documents these, so an operator who sets the option" >&2
          echo "gets a green run and none of the behaviour. Either consume the field" >&2
          echo "or stop emitting it from the module that produces it." >&2
          exit 1
        fi

        touch $out
      '';

  cli-trust-goes-through-the-process-seam =
    pkgs.runCommand "cli-trust-goes-through-the-process-seam"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        found=$(rg --line-number 'trust::apply' ${self}/cli/src \
          --glob '!process.rs' || true)

        if [ -n "$found" ]; then
          echo "the lab CA is applied outside io/process.rs:" >&2
          echo "$found" >&2
          echo "" >&2
          echo "io::process::{run_capture,run_streaming,run_interactive,run_output,run_status}" >&2
          echo "apply the CA and honour --verbose. A call to trust::apply anywhere else is a" >&2
          echo "subprocess that went around them, and the next one like it will forget." >&2
          exit 1
        fi

        touch $out
      '';

  cli-io-stays-in-io =
    pkgs.runCommand "cli-io-stays-in-io"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        found=""
        for file in $(find ${self}/cli/src -name '*.rs' -not -path '*/io/*'); do
          # Everything before the file's own test module: tests are allowed to
          # reach for the real filesystem, product code is not.
          body=$(awk '/^#\[cfg\(test\)\]/ { exit } { print FILENAME ":" FNR ":" $0 }' "$file")
          hits=$(printf '%s\n' "$body" | rg \
            -e 'std::process::Command' \
            -e 'use std::process::\{?Command' \
            -e 'std::fs::[a-z_]+\(' \
            -e '^[^:]*:[0-9]+:use std::fs;' \
            -e 'std::env::var\(' || true)
          if [ -n "$hits" ]; then
            found="$found$hits"$'\n'
          fi
        done

        if [ -n "$(printf '%s' "$found" | tr -d '[:space:]')" ]; then
          echo "the CLI spawns a process, touches the filesystem or reads the" >&2
          echo "environment outside cli/src/io:" >&2
          printf '%s' "$found" >&2
          echo "" >&2
          echo "io/ owns every one of these, so the rest of the tree stays testable" >&2
          echo "without a cluster, a daemon or a home directory. Add or reuse an" >&2
          echo "adapter there and call it by name." >&2
          exit 1
        fi

        touch $out
      '';
}
