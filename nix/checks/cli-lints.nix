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
}
