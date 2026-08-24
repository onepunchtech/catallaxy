{ config, lib, ... }:

let
  inherit (lib) mkOption types;

  inherit (import ./secrets-generate-types.nix { inherit lib; }) generateType;
  inherit (import ../../../lib/floe/collisions.nix { inherit lib; }) contestedKeys;

  enabledFloes = lib.filterAttrs (_: floe: floe.enable or false) config.floes;

  contestedSecrets = contestedKeys {
    floes = config.floes;
    keysOf = floe: lib.attrNames (floe.secrets.generate or { });
  };

  generatorFor = g: {
    apiVersion = "generators.external-secrets.io/v1alpha1";
    kind = "Password";
    metadata = {
      name = g.secret;
      inherit (g) namespace;
      labels."app.kubernetes.io/managed-by" = "catallaxy";
    };
    spec = {
      inherit (g)
        length
        digits
        symbols
        symbolCharacters
        allowRepeat
        noUpper
        ;
    };
  };

  externalSecretFor = g: {
    apiVersion = "external-secrets.io/v1beta1";
    kind = "ExternalSecret";
    metadata = {
      name = g.secret;
      inherit (g) namespace;
      labels."app.kubernetes.io/managed-by" = "catallaxy";
    };
    spec = {
      refreshInterval = "0";

      target = {
        name = g.secret;
        creationPolicy = "Owner";
      }
      // lib.optionalAttrs (g.encoding == "base64") {
        template = {
          engineVersion = "v2";
          data.${g.key} = "{{ .password | b64enc }}";
        };
      };

      dataFrom = [
        (
          {
            sourceRef.generatorRef = {
              apiVersion = "generators.external-secrets.io/v1alpha1";
              kind = "Password";
              name = g.secret;
            };
          }
          // lib.optionalAttrs (g.encoding == "plain" && g.key != "password") {
            rewrite = [
              {
                regexp = {
                  source = "^password$";
                  target = g.key;
                };
              }
            ];
          }
        )
      ];
    };
  };
in
{
  options.secrets.generate = mkOption {
    type = types.attrsOf generateType;
    default = { };
    description = ''
      Secrets this cluster mints for itself, with no value authored anywhere:
      an external-secrets `Password` generator produces one and an
      ExternalSecret lands it in a Secret.

      Each entry becomes a bundle providing `secret:<namespace>/<secret>`,
      which is the token a projection provides, so anything referencing the
      Secret waits for it without saying so.

      A value that exists before the lab does belongs in `lab.secrets.managed`
      and `secrets.projections`. A value another cluster mints belongs in
      `secrets.subscribe`.
    '';
    example = lib.literalExpression ''
      {
        harbor-admin = {
          namespace = "harbor";
          key = "HARBOR_ADMIN_PASSWORD";
          length = 24;
        };
      }
    '';
  };

  config.secrets.generate = lib.mkMerge (
    lib.mapAttrsToList (_: floe: floe.secrets.generate) enabledFloes
  );

  config.bundles = lib.mapAttrs' (
    name: g:
    lib.nameValuePair "secret-generator-${name}" {
      declaredBy = "cluster";
      resources = {
        "${name}-generator" = generatorFor g;
        "${name}-external-secret" = externalSecretFor g;
      };
      createNamespaces = [ g.namespace ];
      requires = [ "external-secrets/webhook/ready" ];
      provides = [ "secret:${g.namespace}/${g.secret}" ];
      readyProbe = {
        kind = "jsonpath";
        resource = "secret/${g.secret}";
        namespace = g.namespace;
        jsonpath = "{.data.${g.key}}";
        timeout = "5m";
      };
    }
  ) config.secrets.generate;

  config.assertions =
    let
      generated = lib.concatStringsSep ", " (lib.attrNames config.secrets.generate);
    in
    lib.optional (config.secrets.generate != { } && !(config.floes.external-secrets.enable or false)) {
      assertion = false;
      message = ''
        this cluster generates secrets (${generated}) but
        `floes.external-secrets.enable` is false. The Password generator and
        the ExternalSecret that reads it are reconciled by that controller,
        and its validating webhook rejects them outright when it is not
        running.

        Enable it on every cluster that generates a secret.
      '';
    }
    ++ lib.mapAttrsToList (secretName: claimants: {
      assertion = false;
      message = ''
        generated secret '${secretName}' on cluster '${config.cluster.name}'
        is declared by ${lib.concatStringsSep " and " (map (n: "`floes.${n}`") claimants)}.

        Each entry mints one Secret and publishes
        `secret:<namespace>/<secret>` for anything waiting on it, so two
        floes claiming the key are two generators racing to fill the same
        name, and whichever reconciles last decides the value.

        Rename one, or have the second read what the first published rather
        than minting its own.
      '';
    }) contestedSecrets;
}
