{ lib }:

let
  inherit (lib) mkOption types;
in
rec {

  mountableRefOptions = {
    name = mkOption {
      type = types.str;
      description = "Name of the ConfigMap / Secret holding the data.";
    };
    key = mkOption {
      type = types.str;
      default = "ca.crt";
      description = "Key inside it holding the payload.";
    };
    readyToken = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Install-DAG token the consumer puts in its bundle's `requires`.

        Null when nothing in the lab claims to produce this: an
        operator pointing a floe at a bundle of their own, say. No
        token, no edge: the framework will not invent ordering over
        something it does not create.
      '';
    };
    readyProbe = mkOption {
      type = types.nullOr types.attrs;
      default = null;
      description = ''
        Optional probe for `k8sHelpers.wait.mkWaitInitContainer`, for
        consumers that want a pod-level wait in addition to the DAG
        edge. Callers override `namespace`: the producer renders the
        probe against its own, but a distributed bundle is materialised
        in the consumer's.
      '';
    };
  };

  mountableRefType = types.submodule { options = mountableRefOptions; };

  nullableMountableRef = types.nullOr mountableRefType;

  mkCapability = fields: types.nullOr (types.submodule { options = fields; });

  tokenOption =
    description:
    mkOption {
      type = types.str;
      inherit description;
    };

}
