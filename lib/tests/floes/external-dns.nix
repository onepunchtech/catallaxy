{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  externalDns = import ../../../modules/lab/cluster/floes/external-dns;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.external-dns = {
        chart = pkgs.emptyDirectory;
      };
    };
  };

  stubClusterName =
    { lib, ... }:
    {
      options.cluster = lib.mkOption {
        type = lib.types.attrs;
        default = {
          name = "isolation-test";
        };
      };
    };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = externalDns;
      cluster = {
        imports = [ stubClusterName ];
        floes.external-dns.enable = false;
      };
    }
  );

  cloudflareResult = evalFloe (
    baseArgs
    // {
      floe = externalDns;
      cluster = {
        imports = [ stubClusterName ];
        floes.external-dns = {
          enable = true;
          domainFilters = [ "example.com" ];
        };
      };
    }
  );

  rfc2136Result = evalFloe (
    baseArgs
    // {
      floe = externalDns;
      cluster = {
        imports = [ stubClusterName ];
        floes.external-dns = {
          enable = true;
          provider = "rfc2136";
          rfc2136 = {
            host = "1.2.3.4";
            port = 5353;
            zone = "lab.test.";
            tsigKeyname = "k";
            tsigSecret = "secret==";
            tsigSecretAlg = "hmac-sha256";
            tsigAxfr = true;
          };
        };
      };
    }
  );

  cfBundle = (cloudflareResult.config.bundles).external-dns or null;
  cfValues = if cfBundle == null then null else cfBundle.helmCharts.external-dns.values;

  rfcBundle = (rfc2136Result.config.bundles).external-dns or null;
  rfcExtraArgs =
    if rfcBundle == null then [ ] else rfcBundle.helmCharts.external-dns.values.extraArgs or [ ];
in
lib.runTests {
  testOptionsDeclared = {
    expr = disabledResult.config.floes.external-dns ? enable;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testExcludedFromBootstrap = {
    expr = if cfBundle == null then null else cfBundle.includeInBootstrap;
    expected = false;
  };

  testTxtOwnerIdDefaultsToClusterName = {
    expr = if cfValues == null then null else cfValues.txtOwnerId;
    expected = "isolation-test";
  };

  testDomainFiltersPropagate = {
    expr = if cfValues == null then null else cfValues.domainFilters;
    expected = [ "example.com" ];
  };

  testRfc2136ExtraArgsBuilt = {
    expr = lib.sort lib.lessThan rfcExtraArgs;
    expected = lib.sort lib.lessThan [
      "--rfc2136-host=1.2.3.4"
      "--rfc2136-port=5353"
      "--rfc2136-zone=lab.test"
      "--rfc2136-tsig-keyname=k"
      "--rfc2136-tsig-secret=secret=="
      "--rfc2136-tsig-secret-alg=hmac-sha256"
      "--rfc2136-tsig-axfr"
    ];
  };

  testNamespaceDefault = {
    expr = cloudflareResult.config.floes.external-dns.namespace;
    expected = "external-dns";
  };
}
