{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  custom = import ../../../modules/lab/cluster/floes/custom;

  stubUpstreamOptions =
    { lib, ... }:
    {
      config._module.freeformType = lib.types.attrs;
      options.floes.gateway.exports = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      options.floes.gateway.internalHostnames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      config.floes.gateway.exports.internalGatewayName = "stub-internal";
    };

  baseArgs = {
    args = { inherit pkgs; };
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = custom;
      cluster = {
        imports = [ stubUpstreamOptions ];
        floes.custom.enable = false;
      };
    }
  );

  singleAppResult = evalFloe (
    baseArgs
    // {
      floe = custom;
      cluster = {
        imports = [ stubUpstreamOptions ];
        floes.custom = {
          enable = true;
          apps.hello = {
            namespace = "hello-ns";
            resources.demo = {
              apiVersion = "v1";
              kind = "ConfigMap";
              metadata.name = "demo";
              data.k = "v";
            };
          };
        };
      };
    }
  );

  gatewayInternalResult = evalFloe (
    baseArgs
    // {
      floe = custom;
      cluster = {
        imports = [ stubUpstreamOptions ];
        floes.custom = {
          enable = true;
          apps.web = {
            namespace = "web";
            gateway = {
              enable = true;
              tier = "internal";
              domain = "web.internal.test";
              serviceName = "web";
              servicePort = 8080;
            };
          };
        };
      };
    }
  );

  helloBundle = (singleAppResult.config.bundles)."custom-hello" or null;

  webRoute =
    let
      bundle = (gatewayInternalResult.config.bundles)."custom-web" or null;
    in
    if bundle == null then null else bundle.resources.web-httproute or null;
in
lib.runTests {

  testCustomOptionsDeclared = {
    expr = disabledResult.config.floes.custom ? enable && disabledResult.config.floes.custom ? apps;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testSingleAppEmitsBundle = {
    expr = helloBundle != null;
    expected = true;
  };

  testBundleResourceCarriedThrough = {
    expr = if helloBundle == null then null else helloBundle.resources.demo.data.k;
    expected = "v";
  };

  testBundleCreateNamespace = {
    expr = if helloBundle == null then [ ] else helloBundle.createNamespaces;
    expected = [ "hello-ns" ];
  };

  testInternalRouteUsesInternalGatewayName = {
    expr = if webRoute == null then null else (builtins.head webRoute.spec.parentRefs).name;
    expected = "stub-internal";
  };

  testInternalHostnameRegistered = {
    expr = gatewayInternalResult.config.floes.gateway.internalHostnames or [ ];
    expected = [ "web.internal.test" ];
  };
}
