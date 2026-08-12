{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  velero = import ../../../modules/lab/cluster/floes/velero;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.velero = {
        chart = pkgs.emptyDirectory;

        crds = "velero-crds-stub";
      };
    };
  };

  stubUpstream =
    { lib, ... }:
    {
      config._module.freeformType = lib.types.attrs;

      options.cluster = lib.mkOption {
        type = lib.types.attrs;
        default = {
          name = "isolation-test";
          ref.kubeContext = "iso-ctx";
        };
      };

    };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = velero;
      cluster = {
        imports = [ stubUpstream ];
        floes.velero.enable = false;
      };
    }
  );

  enabledResult = evalFloe (
    baseArgs
    // {
      floe = velero;
      cluster = {
        imports = [ stubUpstream ];
        floes.velero.enable = true;
      };
    }
  );

  localWithoutSeaweedResult = evalFloe (
    baseArgs
    // {
      floe = velero;
      cluster = {
        imports = [ stubUpstream ];
        floes.velero = {
          enable = true;
          local.enable = true;
        };
      };
    }
  );

  localWithSeaweedResult = evalFloe (
    baseArgs
    // {
      floe = velero;
      cluster = {
        imports = [
          stubUpstream
          {
            config.floes.seaweedfs = {
              enable = true;
              exports = { };
            };
          }
        ];
        floes.velero = {
          enable = true;
          local.enable = true;
        };
      };
    }
  );

  crdsBundle = (enabledResult.config.bundles).velero-crds or null;
  operatorBundle = (enabledResult.config.bundles).velero or null;
  scheduleBundle = (enabledResult.config.bundles).velero-schedules or null;

  localOperatorBundle = (localWithSeaweedResult.config.bundles).velero or null;
  localScheduleBundle = (localWithSeaweedResult.config.bundles).velero-schedules or null;

  failing = res: builtins.filter (a: !a.assertion) res.config.assertions;
in
lib.runTests {
  testOptionsDeclared = {
    expr = disabledResult.config.floes.velero ? enable;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testCrdsBundleEmitted = {
    expr = if crdsBundle == null then null else crdsBundle.yamls;
    expected = [ "velero-crds-stub" ];
  };

  testOperatorBundleInOperatorsPhaseByDefault = {
    expr = operatorBundle != null && operatorBundle.helmCharts.velero.releaseName == "velero";
    expected = true;
  };

  testSchedulesEmitted = {
    expr =
      if scheduleBundle == null then
        [ ]
      else
        lib.sort lib.lessThan (builtins.attrNames scheduleBundle.resources);
    expected = [
      "schedule-daily"
      "schedule-weekly"
    ];
  };

  testLocalWithoutSeaweedFails = {
    expr =
      let
        f = failing localWithoutSeaweedResult;
      in
      builtins.length f == 1 && lib.hasInfix "SeaweedFS" (builtins.head f).message;
    expected = true;
  };

  testLocalWithSeaweedSilent = {
    expr = failing localWithSeaweedResult;
    expected = [ ];
  };

  testLocalPhaseShift = {
    expr = localOperatorBundle != null && localScheduleBundle != null;
    expected = true;
  };

  testNamespaceDefault = {
    expr = enabledResult.config.floes.velero.namespace;
    expected = "velero";
  };
}
