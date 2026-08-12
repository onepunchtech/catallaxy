{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkDefault;
  labName = config.lab.name;
  zone = config.lab.dns.zone or "";

  caPathExpr = ''"$HOME/.local/share/catallaxy/labs/${labName}/proxy/ca.crt"'';

  inherit
    (import ./scripts.nix {
      inherit
        lib
        pkgs
        labName
        zone
        caPathExpr
        ;
    })
    setupScript
    browserScript
    teardownScript
    exportScript
    ;

  caManagedEntries = lib.filterAttrs (_: ms: ms.kind == "ca") config.lab.secrets.managed;
  hasCaEntry = caManagedEntries != { };
  firstCaEntryName = if hasCaEntry then lib.head (lib.attrNames caManagedEntries) else "";
  firstCaEntry = caManagedEntries.${firstCaEntryName} or null;
  caStoreName = if hasCaEntry then firstCaEntry.store else "";

in
{

  imports = [ ./options.nix ];

  config.lab.ops.commands.setup = mkDefault {
    description = "Install the lab CA into the operator's OS / browser / Docker trust stores";
    category = "trust";
    options.docker = {
      type = "bool";
      default = "false";
      description = "Also install into /etc/docker/certs.d/registry.<zone>/ca.crt (Linux, sudo)";
    };
    package = setupScript;
  };

  config.lab.ops.commands.browser = mkDefault {
    description = "Trust the lab CA in your browsers (no sudo)";
    category = "trust";
    options.firefox-profile = {
      type = "string";
      default = "";
      description = "Only this Firefox profile directory, e.g. a throwaway one for a demo. Created if absent.";
    };
    package = browserScript;
  };

  config.lab.ops.commands.teardown = mkDefault {
    description = "Remove the lab CA from the operator's trust stores";
    category = "trust";
    package = teardownScript;
  };

  config.lab.ops.commands.export = mkDefault {
    description = "Print the lab CA PEM to stdout";
    category = "trust";
    package = exportScript;
  };

  config.lab.ops.commands.init-intermediate = mkDefault {
    description = "Mint an intermediate CA signed by the root, SOPS-encrypt into the trust store";
    category = "trust";
    args = [
      {
        name = "intermediate-secret-name";
        description = "Managed-secret name for the intermediate CA (e.g. lab-ca-intermediate). Must be declared with kind=ca in lab.secrets.managed.";
      }
    ];
    options.replace = {
      type = "bool";
      default = "false";
      description = "Overwrite the existing intermediate entry in the SOPS file (rotation).";
    };
    options.days = {
      type = "string";
      default = "365";
      description = "Intermediate certificate validity in days (default 365).";
    };
    options.root-secret = {
      type = "string";
      default = "";
      description = "Root managed-secret name to sign with. Defaults to the single kind=ca entry excluding <intermediate-secret-name>.";
    };
    package = pkgs.writeShellApplication {
      name = "init-intermediate";
      runtimeInputs = with pkgs; [
        openssl
        sops
        yq-go
        gnused
      ];
      text = ''
        set -eu
        lab="${labName}"
        store="${caStoreName}"
        has_ca="${if hasCaEntry then "true" else "false"}"
        ca_names_json='${builtins.toJSON (lib.attrNames caManagedEntries)}'

        out_name="''${1:?Usage: init-intermediate <intermediate-secret-name>}"
        days="''${OPT_days:-365}"
        root_override="''${OPT_root_secret:-}"

        if [ "$has_ca" != "true" ]; then
          cat >&2 <<'NOCAEOF'
        >>> No managed secret with kind="ca" is declared in the lab
        >>> nix config. Declare BOTH the root and the intermediate
        >>> (typically named `lab-ca` and `lab-ca-intermediate`)
        >>> under `lab.secrets.managed.<name>` with `kind = "ca"`,
        >>> then run `cata lab ops -- trust init-ca` (root) followed
        >>> by `cata lab ops -- trust init-intermediate <int-name>`.
        NOCAEOF
          exit 1
        fi

        if ! echo "$ca_names_json" | yq -r '.[]' | grep -qx "$out_name"; then
          cat >&2 <<EOF
        >>> '$out_name' is not declared in lab.secrets.managed with kind="ca".
        >>> Declared kind="ca" secrets: $(echo "$ca_names_json" | yq -r '. | join(", ")')
        EOF
          exit 1
        fi

        if [ -n "$root_override" ]; then
          root_name="$root_override"
        else
          root_name=$(echo "$ca_names_json" | out_name="$out_name" yq -r '.[] | select(. != strenv(out_name))' | head -1)
          count=$(echo "$ca_names_json" | out_name="$out_name" yq -r '[.[] | select(. != strenv(out_name))] | length')
          if [ "$count" != "1" ]; then
            cat >&2 <<EOF
        >>> Ambiguous root: found $count kind="ca" secret(s) besides '$out_name'.
        >>> Pass --root-secret <name> to select which one signs the intermediate.
        EOF
            exit 1
          fi
        fi
        if [ "$root_name" = "$out_name" ]; then
          echo ">>> root and intermediate must be different secrets" >&2
          exit 1
        fi

        sops_path="secrets/$lab/$store.enc.yaml"
        if [ ! -f "$sops_path" ]; then
          cat >&2 <<EOF
        >>> $sops_path does not exist: run \`cata lab ops -- trust init-ca\` first.
        EOF
          exit 1
        fi

        existing=$(sops -d "$sops_path" | yq -r ".$out_name // \"absent\"")
        if [ "$existing" != "absent" ] && [ "''${OPT_replace:-false}" != "true" ]; then
          cat >&2 <<EOF
        $out_name already present in $sops_path.

        Use \`cata lab ops -- trust init-intermediate $out_name --replace\` to rotate
        (all leaf certs get re-issued on next \`cata lab up\`; pods bounce as they roll).
        EOF
          exit 1
        fi

        tmp=$(mktemp -d)
        # shellcheck disable=SC2064
        trap "rm -rf $tmp" EXIT

        echo ">>> Reading root CA ($root_name) from $sops_path…"
        sops -d "$sops_path" | yq -r ".\"$root_name\".\"ca.crt\"" > "$tmp/root.crt"
        sops -d "$sops_path" | yq -r ".\"$root_name\".\"ca.key\"" > "$tmp/root.key"
        if ! grep -q "BEGIN CERTIFICATE" "$tmp/root.crt" || ! grep -q "PRIVATE KEY" "$tmp/root.key"; then
          echo ">>> root secret '$root_name' in $sops_path is missing ca.crt or ca.key" >&2
          exit 1
        fi
        chmod 600 "$tmp/root.key"

        echo ">>> Generating 4096-bit intermediate keypair…"
        openssl genrsa -out "$tmp/int.key" 4096 2>/dev/null

        cat > "$tmp/int.ext" <<'EXTEOF'
        basicConstraints = critical, CA:TRUE, pathlen:0
        keyUsage = critical, digitalSignature, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid:always, issuer:always
        EXTEOF

        echo ">>> Building intermediate CSR…"
        openssl req -new -key "$tmp/int.key" \
          -subj "/CN=Catallaxy Lab Intermediate CA ($lab)" \
          -out "$tmp/int.csr" 2>/dev/null

        echo ">>> Signing intermediate with root ($days-day validity)…"
        openssl x509 -req -in "$tmp/int.csr" \
          -CA "$tmp/root.crt" -CAkey "$tmp/root.key" -CAcreateserial \
          -days "$days" \
          -extfile "$tmp/int.ext" \
          -out "$tmp/int.crt" 2>/dev/null

        if ! openssl verify -CAfile "$tmp/root.crt" "$tmp/int.crt" >/dev/null 2>&1; then
          echo ">>> chain verification failed; refusing to write" >&2
          exit 1
        fi

        echo ">>> Merging intermediate into $sops_path…"
        sops -d "$sops_path" \
          | int_crt="$(cat "$tmp/int.crt")" \
            int_key="$(cat "$tmp/int.key")" \
            out_name="$out_name" \
            yq 'del(.[""]) | (.[strenv(out_name)]) = {"ca.crt": strenv(int_crt), "ca.key": strenv(int_key)}' \
          > "$tmp/plain.yaml"

        staging=".init-intermediate.staging.enc.yaml"
        plain_at_dest="$(dirname "$sops_path")/$staging"
        cp "$tmp/plain.yaml" "$plain_at_dest"
        # shellcheck disable=SC2064
        trap "rm -f '$plain_at_dest'; rm -rf '$tmp'" EXIT

        sops --encrypt --output "$sops_path" "$plain_at_dest"
        rm -f "$plain_at_dest"

        cat <<EOF

        Wrote intermediate '$out_name' into $sops_path.

        Chain:
          Catallaxy Lab CA ($lab)                     (root, $root_name)
            └─ Catallaxy Lab Intermediate CA ($lab)   (intermediate, $out_name, ''${days}d)

        Next steps:
          1. git add $sops_path
          2. git commit -m "lab: mint intermediate CA"
          3. Ensure lab.secrets.projections.<name> exists to project
             '$out_name' into the cluster as a kubernetes.io/tls Secret
             (see floes.cert-manager.selfSignedCA.intermediate.secretName).
          4. cata lab up $lab; cert-manager issues leaves under the
             intermediate; trust-manager continues to distribute the ROOT.
        EOF
      '';
    };
  };

  config.lab.ops.commands.init-ca = mkDefault {
    description = "Mint the team-shared lab CA and SOPS-encrypt it into the trust store";
    category = "trust";
    options.replace = {
      type = "bool";
      default = "false";
      description = "Overwrite the existing SOPS file if it already exists (rotation).";
    };
    package = pkgs.writeShellApplication {
      name = "init-ca";
      runtimeInputs = with pkgs; [
        openssl
        sops
        yq-go
        gnused
      ];
      text = ''
        set -eu
        lab="${labName}"
        store="${caStoreName}"
        secret_name="${firstCaEntryName}"
        has_ca="${if hasCaEntry then "true" else "false"}"

        if [ "$has_ca" != "true" ]; then
          cat >&2 <<'NOCAEOF'
        >>> No managed secret with kind="ca" is declared in the lab
        >>> nix config. Add one to wire up the team-shared CA flow:
        >>>
        >>>   lab.secrets.stores.trust.backend = "sops";
        >>>   lab.secrets.managed.lab-ca = {
        >>>     store = "trust";
        >>>     kind = "ca";
        >>>     hostPaths = {
        >>>       "ca.crt" = "$LAB_STATE_DIR/proxy/ca.crt";
        >>>       "ca.key" = "$LAB_STATE_DIR/proxy/ca.key";
        >>>     };
        >>>   };
        NOCAEOF
          exit 1
        fi

        sops_path="secrets/$lab/$store.enc.yaml"

        if [ -f "$sops_path" ] && [ "''${OPT_replace:-false}" != "true" ]; then
          cat >&2 <<EOF
        $sops_path already exists.

        Use \`cata lab ops -- trust init-ca --replace\` to rotate the CA
        (every operator will need to re-trust + nixos-rebuild after).
        EOF
          exit 1
        fi

        tmp=$(mktemp -d)
        # shellcheck disable=SC2064
        trap "rm -rf $tmp" EXIT

        echo ">>> Generating 4096-bit self-signed CA…"
        openssl genrsa -out "$tmp/ca.key" 4096 2>/dev/null
        openssl req -x509 -new -key "$tmp/ca.key" -days 3650 \
          -subj "/CN=Catallaxy Lab CA ($lab)" -out "$tmp/ca.crt" 2>/dev/null

        echo ">>> Building plaintext YAML for SOPS…"
        crt=$(cat "$tmp/ca.crt") key=$(cat "$tmp/ca.key") \
        secret_name="$secret_name" \
          yq -n \
            '{(strenv(secret_name)): {"ca.crt": strenv(crt), "ca.key": strenv(key)}}' \
            > "$tmp/plain.yaml"

        mkdir -p "$(dirname "$sops_path")"
        staging_name=".init-ca.staging.enc.yaml"
        plain_at_dest="$(dirname "$sops_path")/$staging_name"
        cp "$tmp/plain.yaml" "$plain_at_dest"
        # shellcheck disable=SC2064
        trap "rm -f '$plain_at_dest'; rm -rf '$tmp'" EXIT

        echo ">>> Encrypting → $sops_path"
        sops --encrypt --output "$sops_path" "$plain_at_dest"
        rm -f "$plain_at_dest"

        cat <<EOF

        Wrote $sops_path.

        Next steps:
          1. git add $sops_path
          2. git commit -m "lab: init shared CA"
          3. cata lab up $lab  (the CA decrypts onto your host at
             \$HOME/.local/share/catallaxy/labs/$lab/proxy/{ca.crt,ca.key})
          4. Every operator on the team does the same after pulling.
        EOF
      '';
    };
  };
}
