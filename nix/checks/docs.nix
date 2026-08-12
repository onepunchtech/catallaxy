{
  pkgs,
  optionDocs,
  stepKindDocs,
}:

{
  docs-options-nav = pkgs.runCommand "docs-options-nav" { } ''
    missing=""
    while read -r page; do
      [ -f "${optionDocs}/$page" ] || missing="$missing $page"
    done < <(grep -oE '\]\(\./reference/(options|cli)/[^)]+\)' \
               ${optionDocs}/SUMMARY.md \
             | sed 's|](\./reference/||; s|)||')

    if [ -n "$missing" ]; then
      echo "SUMMARY.md links option pages the generator did not emit:" >&2
      for p in $missing; do echo "  $p" >&2; done
      exit 1
    fi
    echo "every generated option page linked from SUMMARY.md exists" > $out
  '';

  docs-option-links = pkgs.runCommand "docs-option-links" { } ''
    broken=""
    while read -r link; do
      page="''${link%%#*}"
      id="''${link##*#}"
      target="${optionDocs}/options/$page"
      if [ ! -f "$target" ] || ! grep -qF "{#$id}" "$target"; then
        broken="$broken $link"
      fi
    done < <(grep -rhoE '\./options/[a-z/]+\.md#[a-z0-9-]+' \
               ${../../docs/book/src} ${stepKindDocs} --include='*.md' \
             | sed 's|\./options/||' | sort -u)

    if [ -n "$broken" ]; then
      echo "prose links to option anchors that do not exist:" >&2
      for l in $broken; do echo "  ./options/$l" >&2; done
      echo "" >&2
      echo "Anchors come from cli/src/docs/options.rs::anchor." >&2
      echo "Check the real one with:" >&2
      echo "  nix build .#option-docs && grep -oE '\\{#[a-z0-9-]+\\}' result/<page>.md" >&2
      exit 1
    fi
    echo "every option deep link resolves" > $out
  '';

  option-descriptions =
    pkgs.runCommand "option-descriptions" { nativeBuildInputs = [ pkgs.diffutils ]; }
      ''
        if ! diff -u ${../../docs/book/undescribed-options.txt} \
                ${optionDocs}/undescribed.txt > drift.txt; then
          cat >&2 <<'EOF'

        Options without a `description` changed.

        Lines prefixed `+` are options you added or renamed that have no
        description. Give them one: the description is the API's
        documentation and renders into the options book.

        Lines prefixed `-` are options that gained a description or went
        away. Refresh the baseline so it can only ever shrink:

          nix build .#option-docs
          install -m 644 result/undescribed.txt docs/book/undescribed-options.txt

        EOF
          cat drift.txt >&2
          exit 1
        fi
        echo "undescribed options match the baseline" > $out
      '';
}
