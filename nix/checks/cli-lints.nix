{ pkgs, self }:

# What used to live here: twelve architecture lints over the CLI's own source,
# written as awk range matches and ripgrep patterns. A struct's fields came
# from `awk "/pub struct $s \{/{f=1;next} f&&/^\}/{exit}"`, a function's body
# from a similar range, a match arm from a third that ended at a closing brace
# *at one specific indent*. Each was a hand-rolled parser for a language with a
# real grammar, and each got the grammar slightly wrong — a nested brace, a `}`
# in a string, an attribute between the pattern and the item. When an extractor
# like that stops matching it does not fail; it returns nothing, and a lint
# over nothing passes.
#
# They are now `cli/tests/architecture.rs` and `cli/tests/io_boundary.rs`,
# which ask `syn` the same questions and get exact answers. They run under
# `cargo test`, so the `cli` check covers them, and `syn` is a dev-dependency
# so nothing reaches the shipped binary. Moving them also found a real one the
# text version could not see: `LabSpec.environment` was parsed and never read,
# and `rg '\benvironment\b'` had been counting the word in prose.
#
# This one stays, because it is the only lint here that spans two languages
# and so has no home inside the crate.

{
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
}
