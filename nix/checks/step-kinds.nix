{
  lib,
  pkgs,
  system,
}:

let
  schema = import ../../lib/eval/step-kind-schema.nix { inherit lib; };
  emitted = pkgs.writeText "step-kinds.json" (builtins.toJSON schema);
in
{
  step-kinds-conformance =
    pkgs.runCommand "step-kinds-conformance"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.diffutils
        ];
      }
      ''
        python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open("expected.json","w"), indent=2, sort_keys=True); open("expected.json","a").write("\n")' ${emitted}
        if ! diff -u ${../../cli/tests/fixtures/step-kinds.json} expected.json; then
          cat >&2 <<EOF

        cli/tests/fixtures/step-kinds.json no longer matches
        modules/lab/planner/kinds/. The Rust conformance tests read
        that fixture, so a stale one lets the two sides drift.
        Refresh it:

          nix build .#checks.${system}.step-kinds-conformance
        EOF
          exit 1
        fi
        cp expected.json $out
      '';
}
