{
  config,
  lib,
  ...
}:

let
  verifyTypes = import ../verify-types.nix { inherit lib; };

  floeChecks = lib.concatMapAttrs (
    floeName: floe:
    lib.mapAttrs' (checkName: check: lib.nameValuePair "${floeName}-${checkName}" check) (
      floe.verify or { }
    )
  ) config.floes;

  allChecks = floeChecks // config.verify.checks;

  mutating = verifyTypes.mutatingOperations (
    lib.concatMap (c: c.out.steps) (lib.attrValues allChecks)
  );
in
{
  options.verify.checks = lib.mkOption {
    type = lib.types.attrsOf verifyTypes.checkType;
    default = { };
    description = ''
      Assertions about this cluster once it is running, checked by
      `cata lab verify` alongside the ones the enabled floes declare.
    '';
  };

  options.verify.out.checks = lib.mkOption {
    internal = true;
    readOnly = true;
    type = lib.types.attrsOf lib.types.attrs;
    description = "Every check that applies to this cluster: the floes' and this cluster's own.";
  };

  config.verify.out.checks = allChecks;

  config.assertions = [
    {
      assertion = mutating == [ ];
      message = ''
        Verify checks on cluster '${config.cluster.name}' declare operations
        that could change the cluster: ${lib.concatStringsSep ", " mutating}.

        `cata lab verify` reads a lab, it does not deploy one. Only `assert`
        and `error` are allowed, so that running it against a lab you care
        about is never a question you have to think about.
      '';
    }
  ];
}
