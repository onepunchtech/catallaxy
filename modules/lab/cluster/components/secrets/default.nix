# Cluster-level secret projections.
#
# Projections map lab-level managed secrets into Kubernetes Secrets
# within a specific namespace, with optional key transforms.
# Components declare projections; the CLI resolves them at deploy time.
{ config, lib, lab, ... }:

let
  inherit (lib) mkOption types;

  projectionKeyType = types.submodule {
    options = {
      from = mkOption {
        type = types.str;
        description = "Source key name in the managed secret";
      };

      transform = mkOption {
        type = types.enum [
          "none"
          "base64"
          "json-wrap"
        ];
        default = "none";
        description = ''
          Transform to apply when projecting:
          - none: passthrough
          - base64: base64-encode the value
          - json-wrap: wrap as JSON object {"<jsonKey>": "<value>"}
        '';
      };

      jsonKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "JSON key name for json-wrap transform (defaults to the projection key name)";
      };
    };
  };

  projectionType = types.submodule (
    { name, config, ... }:
    {
      options = {
        source = mkOption {
          type = types.str;
          description = "Name of the lab-level managed secret (lab.secrets.managed.<name>)";
        };

        namespace = mkOption {
          type = types.str;
          default = "default";
          description = "Kubernetes namespace for the projected Secret";
        };

        phase = mkOption {
          type = types.str;
          default = "secrets";
          description = "Deployment phase for injection";
        };

        keys = mkOption {
          type = types.attrsOf projectionKeyType;
          default = { };
          description = "Key mappings from source managed secret to K8s Secret keys";
        };

        ref = mkOption {
          type = types.attrs;
          readOnly = true;
          description = "Computed references for this projected secret";
        };
      };

      config.ref = {
        inherit name;
        inherit (config) namespace;
        secretRef = { inherit name; };
        envFrom = {
          secretRef = { inherit name; };
        };
        volume = {
          secret.secretName = name;
        };
      };
    }
  );

  # Validate that projections reference existing managed secrets and keys
  projectionAssertions = lib.concatLists (
    lib.mapAttrsToList (
      projName: proj:
      let
        managedSecret = lab.secrets.managed.${proj.source} or null;
        managedSecretKeys = if managedSecret != null then builtins.attrNames managedSecret.keys else [ ];
      in
      [
        {
          assertion = managedSecret != null;
          message = "Projection '${projName}' references managed secret '${proj.source}' which does not exist in lab.secrets.managed";
        }
      ]
      ++ lib.mapAttrsToList (
        keyName: keyDef: {
          assertion = managedSecret == null || builtins.elem keyDef.from managedSecretKeys;
          message = "Projection '${projName}' key '${keyName}' references source key '${keyDef.from}' which does not exist in managed secret '${proj.source}'. Available keys: ${builtins.concatStringsSep ", " managedSecretKeys}";
        }
      ) proj.keys
    ) config.secrets.projections
  );
in
{
  imports = [
    ./sops.nix
    ./external-secrets.nix
  ];

  options.secrets.projections = mkOption {
    type = types.attrsOf projectionType;
    default = { };
    description = ''
      Secret projections map lab-level managed secrets into Kubernetes Secrets.
      Each projection creates one K8s Secret with keys derived from a source
      managed secret, optionally transformed (base64, json-wrap).
    '';
  };

  # Keep backward compat: secrets.managed still works but is deprecated
  options.secrets.managed = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
    internal = true;
    description = "Deprecated — use lab.secrets.managed + secrets.projections";
  };

  config.assertions = projectionAssertions;
}
