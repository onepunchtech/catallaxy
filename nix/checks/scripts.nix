{ pkgs, self }:

{
  shell-scripts-are-clean =
    pkgs.runCommand "shell-scripts-are-clean"
      {
        nativeBuildInputs = [
          pkgs.shellcheck
          pkgs.shfmt
        ];
      }
      ''
        scripts=$(find ${self}/modules ${self}/lib -name '*.sh')

        if [ -z "$scripts" ]; then
          echo "no .sh files found, so this check is asserting nothing" >&2
          exit 1
        fi

        # Warnings and above. Style suggestions are excluded on purpose: the
        # one this would flag today wants a parameter-expansion substitution where
        # the sed it replaces reads better, and a check nobody can satisfy
        # gets disabled.
        # shellcheck disable=SC2086
        shellcheck --shell=bash --severity=warning $scripts

        # shellcheck disable=SC2086
        shfmt --diff --indent 2 $scripts

        touch $out
      '';
}
