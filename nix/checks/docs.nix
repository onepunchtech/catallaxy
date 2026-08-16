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

  docs-summary-resolves = pkgs.runCommand "docs-summary-resolves" { } ''
    missing=""
    while read -r page; do
      # step-kinds.md and changelog.md are copied in by the docs derivation
      # rather than living in the book source.
      case "$page" in
        reference/step-kinds.md | changelog.md) continue ;;
      esac

      # optionDocs is rooted at reference/, the same mapping the docs
      # derivation uses when it copies the generated pages in.
      generated="${optionDocs}/''${page#reference/}"

      if [ -f "${../../docs/book/src}/$page" ] || [ -f "$generated" ]; then
        continue
      fi
      missing="$missing $page"
    done < <(grep -oE '\]\(\./[^)]+\.md\)' ${optionDocs}/SUMMARY.md \
             | sed 's|](\./||; s|)||')

    if [ -n "$missing" ]; then
      echo "SUMMARY.md links pages that do not exist, so mdBook emits them blank:" >&2
      for p in $missing; do echo "  $p" >&2; done
      echo "" >&2
      echo "Either write the page, copy it in from pkgs/default.nix as the" >&2
      echo "changelog and step-kind reference are, or drop the nav entry." >&2
      exit 1
    fi
    echo "every SUMMARY.md entry resolves to real content" > $out
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

  option-descriptions = pkgs.runCommand "option-descriptions" { } ''
        count=$(grep -c . ${optionDocs}/undescribed.txt || true)

        if [ "$count" -ne 0 ]; then
          cat >&2 <<'EOF'

        These options have no `description`:

    EOF
          cat ${optionDocs}/undescribed.txt >&2
          cat >&2 <<'EOF'

        A description is the API's documentation. It renders into the options
        book, and an option nobody can explain is one nobody can use. Say what
        the option does and, where it is not obvious, what happens if you leave
        it alone.

    EOF
          exit 1
        fi
        echo "every option has a description" > $out
  '';
}
