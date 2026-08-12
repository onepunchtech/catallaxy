{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkOption types;

  verifyTypes = import ./verify-types.nix { inherit lib; };
in
{
  options.lab.verify = {
    checks = mkOption {
      type = types.attrsOf verifyTypes.checkType;
      default = { };
      description = ''
        Assertions about a lab that is already running, checked by
        `cata lab verify` on top of the built-in ones (clusters reachable,
        host services ready, workloads rolled out, exposed hosts
        answering).

        This is the live counterpart to `lab.lint.checks`: lint reads
        rendered manifests and needs no cluster, verify needs a running lab
        and reads its actual state.

        A check here applies to every cluster in the lab. A floe declares
        the same shape at `floes.<n>.verify.<name>`, which is usually where
        it belongs: the component knows what working means for itself, and
        every lab enabling it inherits the assertion.
      '';
    };

    endpoints = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Probe every public host in `cluster.out.exposedHosts` from the
          machine running the command, which is what proves the lab's
          ingress, routing and CA are wired together rather than merely
          rendered.

          Turn it off for a lab whose endpoints are deliberately
          unreachable from wherever `verify` runs.
        '';
      };

      acceptStatuses = mkOption {
        type = types.listOf types.int;
        default = [ ];
        example = [ 402 ];
        description = ''
          HTTP statuses to accept in addition to the defaults.

          A response under 400 passes, and so do 401 and 403: a route that
          resolved and then declined the request has proven what this check
          asks. Everything else fails, 404 included, because a 404 is what
          the gateway returns when no route matched, which is the failure
          this check exists to catch.
        '';
      };
    };
  };

  options.lab.out.verifyConfig = mkOption {
    readOnly = true;
    internal = true;
    type = types.attrs;
    description = "The verify configuration the CLI reads: endpoint policy, and where the rendered tests live.";
  };

  config.lab.out.verifyConfig = {
    inherit (config.lab.verify) endpoints;
  };
}
