{ lib }:

let
  inherit (lib) mkOption types;

  issuerRef = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Name of the issuer.";
      };
      kind = mkOption {
        type = types.str;
        default = "ClusterIssuer";
        description = "Issuer scope. `ClusterIssuer` is lab-wide; `Issuer` is confined to the namespace.";
      };
    };
  };
in
{
  defaultIssuer =
    config:
    let
      ref = config.floes.cert-manager.exports.defaultIssuerRef or { };
    in
    if ref == { } then null else ref;

  issuerRefOption =
    {
      default,
      description,
      nullable ? true,
    }:
    mkOption {
      type = if nullable then types.nullOr issuerRef else issuerRef;
      inherit default description;
    };
}
