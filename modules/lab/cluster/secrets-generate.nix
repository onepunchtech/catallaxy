{ config, lib, ... }:

let
  inherit (lib) mkOption types;

  generateType = types.submodule (
    { name, ... }:
    {
      options = {
        namespace = mkOption {
          type = types.str;
          description = "Namespace to materialise the Secret in.";
        };

        secret = mkOption {
          type = types.str;
          default = name;
          description = "Name of the Secret. Defaults to the attribute name.";
        };

        key = mkOption {
          type = types.str;
          default = "password";
          description = "Key within the Secret that the value lands under.";
        };

        length = mkOption {
          type = types.int;
          default = 24;
          description = ''
            Characters in the generated value. Under `encoding = "base64"`
            this counts the bytes the consumer decodes, not the characters
            that reach the Secret.
          '';
        };

        digits = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "How many digits. Null lets the generator take a quarter of the length.";
        };

        symbols = mkOption {
          type = types.int;
          default = 0;
          description = ''
            How many symbol characters. Zero, because a consumer that puts the
            value in a URL, a connection string or a config file it does not
            quote breaks on them, and a caller who wants symbols knows it.
          '';
        };

        symbolCharacters = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Which symbols to draw from. Null takes the generator's set.";
        };

        allowRepeat = mkOption {
          type = types.bool;
          default = true;
          description = "Whether a character may appear more than once.";
        };

        noUpper = mkOption {
          type = types.bool;
          default = false;
          description = "Draw from lowercase only.";
        };

        encoding = mkOption {
          type = types.enum [
            "plain"
            "base64"
          ];
          default = "plain";
          description = ''
            How the value reaches the Secret.

            `base64` is for a consumer that decodes the value to get raw key
            bytes rather than reading it as a string, which is what an
            encryption key usually is. It satisfies a consumer that treats the
            value as an opaque string too, so it is the safe choice when you
            are unsure which one you have.
          '';
        };
      };
    }
  );

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
      # A generator runs again on every refresh, so any interval but zero
      # rotates the value underneath whatever already read it.
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

  config.bundles = lib.mapAttrs' (
    name: g:
    lib.nameValuePair "secret-generator-${name}" {
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
    };
}
