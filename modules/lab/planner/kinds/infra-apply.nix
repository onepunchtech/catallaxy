{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    stack = lib.mkOption {
      type = lib.types.str;
      description = "Stack this step acts on, which is one unit of state and one apply.";
    };
    workingDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Directory the tool runs in. Null lets the CLI derive it, which is
        what a lab wants: it is host state, not something a lab declares.
      '';
    };
  };
}
