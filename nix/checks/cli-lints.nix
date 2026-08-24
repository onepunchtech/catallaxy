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

  kube-contexts-are-checked-before-use =
    pkgs.runCommand "kube-contexts-are-checked-before-use"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        outside=$(rg --files-with-matches '"--context"' ${self}/cli/src \
          --glob '!**/kube_context.rs' \
          --glob '!**/io/kubectl/run.rs' || true)

        unguarded=""
        for f in $outside; do
          if ! rg --quiet 'require_named' "$f"; then
            unguarded="$unguarded$f"$'\n'
          fi
        done

        if [ -n "$(printf '%s' "$unguarded" | grep -c . || true)" ] && [ -n "$unguarded" ]; then
          echo "these files build a --context argument and never check one:" >&2
          printf '%s' "$unguarded" >&2
          echo "" >&2
          echo "kubectl reads an empty --context as unset and falls back to the" >&2
          echo "kubeconfig's current-context, so an unresolved lab context runs" >&2
          echo "against whatever cluster the operator is pointed at rather than" >&2
          echo "failing. 'lab status' reported such a lab as reachable because an" >&2
          echo "unrelated live cluster answered." >&2
          echo "" >&2
          echo "Build the command through io::kubectl::run's contextual(), or pass" >&2
          echo "the name through io::kube_context::require_named() at the entry" >&2
          echo "point the module funnels through." >&2
          exit 1
        fi

        found_erased=$(rg --line-number 'kube_context\([^)]*\)\s*\.\s*(unwrap_or_default|unwrap_or\(""\))' ${self}/cli/src || true)
        if [ -n "$found_erased" ]; then
          echo "a kube context lookup was collapsed to an empty string:" >&2
          echo "$found_erased" >&2
          echo "" >&2
          echo "An empty context is not 'no context in particular'; it is the" >&2
          echo "operator's current one. Handle the error instead." >&2
          exit 1
        fi

        touch $out
      '';

  cluster-drift-sees-every-declared-field =
    pkgs.runCommand "cluster-drift-sees-every-declared-field"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        shape=${self}/cli/src/domain/cluster_shape.rs
        declared=${self}/cli/src/domain/cluster.rs
        missing=""

        for struct in K3dConfig ClusterNetwork KubernetesSpec; do
          fields=$(awk "/pub struct $struct \{/{f=1;next} f&&/^\}/{exit} f" "$declared" \
            | grep -oE '^[[:space:]]+pub [a-z][a-z0-9_]*:' \
            | sed 's/.*pub //; s/://')

          for field in $fields; do
            # A different k3d cluster name is a different cluster, so
            # cluster_exists never matches one and there is nothing to drift.
            if [ "$field" = "cluster_name" ]; then
              continue
            fi
            if ! rg --quiet "\b$field\b" "$shape"; then
              missing="$missing  $struct.$field"$'\n'
            fi
          done
        done

        if [ -n "$missing" ]; then
          echo "these declared cluster fields are not in the recorded shape:" >&2
          printf '%s' "$missing" >&2
          echo "" >&2
          echo "lab up refuses a cluster whose declaration no longer matches the" >&2
          echo "shape it was built from, and the comparison is over ClusterShape." >&2
          echo "A field missing from it is one an operator can change and have" >&2
          echo "silently ignored, which is what this exists to stop coming back:" >&2
          echo "drift used to compare two fields of twelve." >&2
          echo "" >&2
          echo "Add it to ClusterShape::of and compare_shapes, or if it genuinely" >&2
          echo "cannot drift, name it here with a reason." >&2
          exit 1
        fi

        # The loop above walks the fields of one provisioner's config. It
        # cannot see a provisioner that is never compared at all, which is how
        # Talos went without a drift check while its `cluster_create` read
        # controlPlanes and workers from the declaration.
        # Scoped to the function that builds clusters: `stop_cluster` and
        # `deprovision_cluster` match on the same enum and must not converge.
        provisioning=$(awk '/^pub fn provision_cluster_with_registry/{f=1} f{print} f&&/^\}/{exit}' \
          ${self}/cli/src/provision/mod.rs)

        arm() {
          printf '%s' "$provisioning" | awk "/ProvisionerKind::$1 =>/{f=1} f{print} f&&/^        \}\$/{exit}"
        }

        for kind in K3d Talos; do
          if ! arm "$kind" | rg --quiet 'converge_existing_cluster|provision_k3d'; then
            echo "ProvisionerKind::$kind provisions a cluster without ever" >&2
            echo "comparing it to what the lab declares." >&2
            echo "" >&2
            echo "An existing cluster that short-circuits on 'already running'" >&2
            echo "reports a green run for a declaration it ignored. Either" >&2
            echo "route it through converge_existing_cluster, or say here why" >&2
            echo "this provisioner converges some other way -- Crossplane does," >&2
            echo "through the manifest apply, and External is not ours to change." >&2
            exit 1
          fi
        done

        touch $out
      '';

  every-container-carries-provenance =
    pkgs.runCommand "every-container-carries-provenance"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        found=$(rg --line-number --multiline 'args\(\["run", "-d"' ${self}/cli/src || true)
        count=$(printf '%s' "$found" | grep -c . || true)

        if [ "$count" != "1" ]; then
          echo "a container is started $count different ways:" >&2
          echo "$found" >&2
          echo "" >&2
          echo "There were two, and only one of them could have carried labels." >&2
          echo "A container without catallaxy.io/lab cannot be attributed to a" >&2
          echo "lab, which is what made an orphaned lab impossible to find or" >&2
          echo "remove. Every container goes through io::docker::RunContainer." >&2
          exit 1
        fi

        if ! rg --quiet --multiline --multiline-dotall \
             'args\(\["run", "-d".{0,400}label_args' ${self}/cli/src/io/docker.rs; then
          echo "the container that gets started does not apply its labels." >&2
          echo "" >&2
          echo "catallaxy.io/lab is how `lab list` finds a lab that is running" >&2
          echo "and how `lab cleanup` removes one the flake no longer defines." >&2
          exit 1
        fi

        touch $out
      '';

  a-ready-probe-never-replaces-the-rollout-wait =
    pkgs.runCommand "a-ready-probe-never-replaces-the-rollout-wait"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        body=$(awk '/^fn await_wave_bundles/{f=1} f{print} f&&/^}/{exit}' \
          ${self}/cli/src/io/ssa/mod.rs)

        for call in wait_workloads_ready run_ready_probe; do
          if ! printf '%s' "$body" | rg --quiet "$call"; then
            echo "await_wave_bundles no longer calls $call." >&2
            exit 1
          fi
        done

        if printf '%s' "$body" | rg --quiet 'match &bundle\.ready_probe'; then
          echo "awaiting a bundle branches on whether it declares a probe." >&2
          echo "" >&2
          echo "It used to, and the branch meant a bundle with a probe never" >&2
          echo "waited for its own Deployments. A probe answers a narrower" >&2
          echo "question than the rollout: cert-manager's checks an Issuer," >&2
          echo "not the webhook serving it, so the next wave started against" >&2
          echo "pods that were still coming up." >&2
          echo "" >&2
          echo "Wait for the workloads, then run the probe. A bundle with no" >&2
          echo "workloads makes the wait a no-op, so nothing is paid for it." >&2
          exit 1
        fi

        touch $out
      '';

  cleanup-never-reaches-for-a-flake =
    pkgs.runCommand "cleanup-never-reaches-for-a-flake"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        found=$(rg --line-number 'get_lab_spec|get_lab_config|nix::' \
          ${self}/cli/src/commands/lab/cleanup.rs \
          ${self}/cli/src/domain/inventory.rs \
          ${self}/cli/src/io/host_inventory.rs || true)

        if [ -n "$found" ]; then
          echo "the orphan path evaluates a flake:" >&2
          echo "$found" >&2
          echo "" >&2
          echo "`lab cleanup` exists for the case the flake cannot answer: the lab" >&2
          echo "was deleted from it, renamed, built from another checkout, or the" >&2
          echo "flake no longer evaluates. Reaching for it here would fail in" >&2
          echo "exactly the situation the command is for." >&2
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

  state-layout-agrees-with-nix =
    pkgs.runCommand "state-layout-agrees-with-nix"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        state=${self}/cli/src/host/state.rs
        trust=${self}/modules/lab/trust/default.nix

        labs=$(rg --only-matching --replace '$1' \
          'pub const LABS_DIR: &str = "([^"]+)"' "$state")
        service=$(rg --only-matching --replace '$1' \
          'pub const PROXY_SERVICE: &str = "([^"]+)"' "$state")
        cert=$(rg --only-matching --replace '$1' \
          'pub const CA_CERT: &str = "([^"]+)"' "$state")

        expected="\$HOME/$labs/\''${labName}/$service/$cert"

        if ! rg --quiet --fixed-strings "$expected" "$trust"; then
          echo "the Nix side and the CLI disagree about where the lab CA is." >&2
          echo "" >&2
          echo "  the CLI builds:  $expected" >&2
          echo "  and this is what modules/lab/trust/default.nix says:" >&2
          rg --line-number 'catallaxy/labs' "$trust" >&2 || true
          echo "" >&2
          echo "The Nix side spells the path to tell an operator where their" >&2
          echo "CA is; the CLI spells it to write the file. Nothing made them" >&2
          echo "agree, so moving the state directory would have left the" >&2
          echo "instructions pointing at nothing." >&2
          exit 1
        fi

        touch $out
      '';

  docker-is-spawned-one-way =
    pkgs.runCommand "docker-is-spawned-one-way"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        found=$(rg --line-number 'Command::new\("docker"\)' ${self}/cli/src || true)
        count=$(printf '%s' "$found" | grep -c . || true)

        if [ "$count" != "1" ]; then
          echo "docker is spawned $count different ways:" >&2
          echo "$found" >&2
          echo "" >&2
          echo "It used to be thirty, across six files, so what a docker" >&2
          echo "subprocess inherits was thirty decisions that were never made." >&2
          echo "Every docker goes through io::docker::command(), which is the" >&2
          echo "one site this check expects to find. It adds nothing today, and" >&2
          echo "that is the point: the next thing docker should or should not" >&2
          echo "inherit is decided once, there." >&2
          exit 1
        fi

        env_sites=$(rg --line-number 'env\("DOCKER_HOST"' ${self}/cli/src || true)
        env_count=$(printf '%s' "$env_sites" | grep -c . || true)

        if [ "$env_count" != "1" ]; then
          echo "DOCKER_HOST is set in $env_count places:" >&2
          echo "$env_sites" >&2
          echo "" >&2
          echo "k3d, talosctl and docker all read it, and each had its own" >&2
          echo "copy. io::docker::apply_host is the one that stays." >&2
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

  cli-io-scan-detects-its-fixture =
    pkgs.runCommand "cli-io-scan-detects-its-fixture"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        raw=$(python3 ${self}/nix/checks/cli-io-scan.py ${self}/nix/checks/cli-io-scan-fixture 2>&1 || true)
        got=$(printf '%s\n' "$raw" | grep -oE '^  [a-z][^:]*\.rs:[0-9]+' | sed 's/^  //' | sort | tr '\n' ' ')
        want="tricky.rs:15 tricky.rs:30 tricky.rs:6 "

        if [ "$got" != "$want" ]; then
          echo "the I/O scanner does not read its own fixture correctly." >&2
          echo "  want: $want" >&2
          echo "  got:  $got" >&2
          echo "" >&2
          echo "The fixture carries a #[cfg(test)] on a use rather than a module," >&2
          echo "two separate test modules with product code between them, a brace" >&2
          echo "inside a raw string and one inside a comment. A scanner that gets" >&2
          echo "any of those wrong reports a clean tree for the wrong reason, which" >&2
          echo "is what the awk extractor this replaced did for 422 lines of" >&2
          echo "host/services.rs." >&2
          exit 1
        fi

        touch $out
      '';

  cli-io-stays-in-io =
    pkgs.runCommand "cli-io-stays-in-io"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${self}/nix/checks/cli-io-scan.py \
          ${self}/cli/src \
          ${self}/nix/checks/cli-io-baseline.txt >&2

        touch $out
      '';
}
