{
  lib,
  pkgs,
  labName,
  zone,
  caPathExpr,
}:

let

  nssTrustFlags = "CT,,";

  nssHelpers = ''
    nss_import() {
      certutil -D -d "$1" -n "catallaxy-${labName}" 2>/dev/null || true
      if certutil -A -d "$1" -n "catallaxy-${labName}" -t "${nssTrustFlags}" -i "$ca"; then
        echo "    trusted in $2"
      else
        echo "    FAILED for $2" >&2
        return 1
      fi
    }

    nss_forget() {
      certutil -D -d "$1" -n "catallaxy-${labName}" 2>/dev/null \
        && echo "    removed from $2" || true
    }

    firefox_profiles() {
      for root in \
        "$HOME/.mozilla/firefox" \
        "$HOME/snap/firefox/common/.mozilla/firefox" \
        "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" \
        "$HOME/Library/Application Support/Firefox/Profiles"; do
        [ -d "$root" ] || continue
        for profile in "$root"/*/; do
          [ -f "$profile/cert9.db" ] && printf '%s\n' "''${profile%/}"
        done
      done
      return 0
    }
  '';

  caHeader = ''
    set -eu
    ca=${caPathExpr}
    if [ ! -f "$ca" ]; then
      echo "lab CA not found at $ca: run \`cata lab up\` first." >&2
      exit 1
    fi
  '';

  osBranchHeader = ''
    ${caHeader}
    nixos=false
    if [ -e /etc/NIXOS ] || (grep -qi '^ID=nixos' /etc/os-release 2>/dev/null); then
      nixos=true
    fi
  '';
in
{
  setupScript = pkgs.writeShellApplication {
    name = "setup";

    runtimeInputs = with pkgs; [ nss.tools ];
    text = ''
      ${osBranchHeader}
      ${nssHelpers}
      case "$(uname)" in
        Darwin)
          sudo security add-trusted-cert -d -r trustRoot \
            -k /Library/Keychains/System.keychain "$ca"
          ;;
        Linux)
          if [ "$nixos" = true ]; then
            cat >&2 <<EOF
      >>> NixOS detected. The system trust store is declarative;
      >>> the ops command can't write to it. Add to your NixOS
      >>> configuration (typically /etc/nixos/configuration.nix or
      >>> a per-host module) and \`sudo nixos-rebuild switch\`:
      >>>
      >>>     security.pki.certificateFiles = [
      >>>       "$ca"
      >>>     ];
      >>>
      >>> User-level browser trust (NSS DB) we can still set:
      EOF
          fi

          mkdir -p "$HOME/.pki/nssdb"
          if [ ! -f "$HOME/.pki/nssdb/cert9.db" ]; then
            certutil -N -d "sql:$HOME/.pki/nssdb" --empty-password
          fi
          nss_import "sql:$HOME/.pki/nssdb" "Chromium family (~/.pki/nssdb)"

          if [ "$nixos" = false ]; then
            if command -v update-ca-certificates >/dev/null 2>&1; then
              echo ">>> Installing into /usr/local/share/ca-certificates (sudo required)"
              sudo install -m 0644 "$ca" \
                "/usr/local/share/ca-certificates/catallaxy-${labName}.crt"
              sudo update-ca-certificates
            fi
            # shellcheck disable=SC2157
            if [ "''${OPT_docker:-false}" = "true" ] && [ -n "${zone}" ]; then
              echo ">>> Installing into /etc/docker/certs.d (sudo required)"
              sudo install -d "/etc/docker/certs.d/registry.${zone}"
              sudo install -m 0644 "$ca" \
                "/etc/docker/certs.d/registry.${zone}/ca.crt"
            fi
          else
            echo "Browser NSS DB install OK. System trust still needs nixos-rebuild: see message above." >&2
            exit 1
          fi
          ;;
        *)
          echo "Unsupported OS: $(uname). Manual trust install required." >&2
          exit 1
          ;;
      esac
      echo "Lab CA installed for ${labName}."
    '';
  };

  browserScript = pkgs.writeShellApplication {
    name = "browser";
    runtimeInputs = with pkgs; [ nss.tools ];
    text = ''
      ${caHeader}
      ${nssHelpers}

      only_profile="''${OPT_firefox_profile:-}"
      touched=0

      echo ">>> Trusting the '${labName}' CA in browsers (no sudo)"

      if [ "$(uname)" = "Linux" ] && [ -z "$only_profile" ]; then
        mkdir -p "$HOME/.pki/nssdb"
        if [ ! -f "$HOME/.pki/nssdb/cert9.db" ]; then
          certutil -N -d "sql:$HOME/.pki/nssdb" --empty-password
        fi
        nss_import "sql:$HOME/.pki/nssdb" "Chromium family (~/.pki/nssdb)"
        touched=$((touched + 1))
      fi

      if [ "$(uname)" = "Darwin" ] && [ -z "$only_profile" ]; then
        if security add-trusted-cert -r trustRoot \
             -k "$HOME/Library/Keychains/login.keychain-db" "$ca" 2>/dev/null; then
          echo "    trusted in the login keychain (Safari, Chrome)"
          touched=$((touched + 1))
        else
          echo "    could not write the login keychain; open Keychain Access and" >&2
          echo "    import $ca manually, or run 'trust setup' for the System keychain." >&2
        fi
      fi

      if [ -n "$only_profile" ]; then
        if [ ! -f "$only_profile/cert9.db" ]; then
          mkdir -p "$only_profile"
          certutil -N -d "sql:$only_profile" --empty-password
        fi
        nss_import "sql:$only_profile" "Firefox profile $only_profile"
        touched=$((touched + 1))
      else
        while IFS= read -r profile; do
          [ -n "$profile" ] || continue
          nss_import "sql:$profile" "Firefox profile $(basename "$profile")"
          touched=$((touched + 1))
        done <<EOF
      $(firefox_profiles)
      EOF
      fi

      if [ "$touched" -eq 0 ]; then
        echo "    no browser certificate stores found." >&2
        echo "    Firefox creates one on first run; Chromium's lives at ~/.pki/nssdb." >&2
        exit 1
      fi

      echo ">>> Done. Restart the browser for it to re-read the store."
      echo "    Undo with: cata lab ops -- trust teardown"
    '';
  };

  teardownScript = pkgs.writeShellApplication {
    name = "teardown";

    runtimeInputs = with pkgs; [ nss.tools ];
    text = ''
      ${osBranchHeader}
      ${nssHelpers}
      case "$(uname)" in
        Darwin)
          security delete-certificate -t -c "Catallaxy Lab CA" 2>/dev/null || true
          security delete-certificate -t -c "Catallaxy Lab CA (${labName})" 2>/dev/null || true
          ;;
        Linux)
          nss_forget "sql:$HOME/.pki/nssdb" "Chromium family"

          if [ "$nixos" = true ]; then
            cat >&2 <<EOF
      >>> NixOS: remove from your config and \`sudo nixos-rebuild switch\`:
      >>>
      >>>     security.pki.certificateFiles =
      >>>       lib.lists.remove "$ca" config.security.pki.certificateFiles;
      EOF
          else
            if [ -f "/usr/local/share/ca-certificates/catallaxy-${labName}.crt" ]; then
              echo ">>> Removing from /usr/local/share/ca-certificates (sudo required)"
              sudo rm -f "/usr/local/share/ca-certificates/catallaxy-${labName}.crt"
              command -v update-ca-certificates >/dev/null 2>&1 \
                && sudo update-ca-certificates
            fi
            if [ -d "/etc/docker/certs.d/registry.${zone}" ]; then
              echo ">>> Removing /etc/docker/certs.d/registry.${zone} (sudo required)"
              sudo rm -rf "/etc/docker/certs.d/registry.${zone}"
            fi
          fi
          ;;
      esac

      while IFS= read -r profile; do
        [ -n "$profile" ] || continue
        nss_forget "sql:$profile" "Firefox profile $(basename "$profile")"
      done <<EOF
      $(firefox_profiles)
      EOF

      echo "Lab CA removed for ${labName}."
    '';
  };

  exportScript = pkgs.writeShellApplication {
    name = "export";
    text = ''
      set -eu
      ca=${caPathExpr}
      if [ ! -f "$ca" ]; then
        echo "lab CA not found at $ca" >&2
        exit 1
      fi
      cat "$ca"
    '';
  };
}
