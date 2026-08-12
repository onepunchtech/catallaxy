{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  certManager = import ../../../modules/lab/cluster/floes/cert-manager;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.cert-manager = {
        chart = pkgs.emptyDirectory;
        crds = "cert-manager-crds-stub";
      };
    };
  };

  stubTrustManager =
    { lib, ... }:
    {
      options.floes.trust-manager.exports.bundleDistribution = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
      };
    };

  distributing = {
    readyToken = "trust-manager/bundles/ready";
    namespace = "trust-manager";
    secretTargets = true;
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = certManager;
      cluster = {
        imports = [ stubTrustManager ];
        floes.cert-manager.enable = false;
      };
    }
  );

  operatorOnlyResult = evalFloe (
    baseArgs
    // {
      floe = certManager;
      cluster = {
        imports = [ stubTrustManager ];
        floes.cert-manager.enable = true;
      };
    }
  );

  selfSignedResult = evalFloe (
    baseArgs
    // {
      floe = certManager;
      cluster = {
        imports = [ stubTrustManager ];
        floes.cert-manager = {
          enable = true;
          selfSignedCA.enable = true;
        };
      };
    }
  );

  intermediateResult = evalFloe (
    baseArgs
    // {
      floe = certManager;
      cluster = {
        imports = [ stubTrustManager ];
        floes.cert-manager = {
          enable = true;
          selfSignedCA = {
            enable = true;
            intermediate.enable = true;
          };
        };
      };
    }
  );

  acmeResult = evalFloe (
    baseArgs
    // {
      floe = certManager;
      cluster = {
        imports = [ stubTrustManager ];
        floes.cert-manager = {
          enable = true;
          acme = {
            enable = true;
            email = "admin@test.local";
            dns01.provider = "cloudflare";
          };
        };
      };
    }
  );

  intermediateAndAcmeResult = evalFloe (
    baseArgs
    // {
      floe = certManager;
      cluster = {
        imports = [ stubTrustManager ];
        floes.cert-manager = {
          enable = true;
          selfSignedCA = {
            enable = true;
            intermediate.enable = true;
          };
          acme = {
            enable = true;
            email = "admin@test.local";
            dns01.provider = "cloudflare";
          };
        };
      };
    }
  );

  withTrustManagerResult = evalFloe (
    baseArgs
    // {
      floe = certManager;
      cluster = {
        imports = [
          stubTrustManager
          { config.floes.trust-manager.exports.bundleDistribution = distributing; }
        ];
        floes.cert-manager = {
          enable = true;
          selfSignedCA.enable = true;
        };
      };
    }
  );

  issuers =
    res:
    let
      bundle = (res.config.bundles).cert-manager-issuers or null;
    in
    if bundle == null then { } else bundle.resources or { };
in
lib.runTests {
  testOptionsDeclared = {
    expr =
      disabledResult.config.floes.cert-manager ? enable
      && disabledResult.config.floes.cert-manager ? selfSignedCA
      && disabledResult.config.floes.cert-manager ? acme;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testCaBundleNullWhenDisabled = {
    expr = disabledResult.config.floes.cert-manager.exports.caBundle;
    expected = null;
  };

  testCaBundleNullWhenNoSelfSignedCA = {
    expr = operatorOnlyResult.config.floes.cert-manager.exports.caBundle;
    expected = null;
  };

  testCaBundleNullWithoutDistributor = {
    expr = selfSignedResult.config.floes.cert-manager.exports.caBundle;
    expected = null;
  };

  testCaBundleWithDistributor = {
    expr = withTrustManagerResult.config.floes.cert-manager.exports.caBundle;
    expected = {
      name = "lab-ca-bundle";
      key = "ca.crt";
      readyToken = "cert-manager/default-issuer/ready";
      readyProbe = {
        kind = "exists";
        resource = "configmap/lab-ca-bundle";
        namespace = "cert-manager";
        timeout = "5m";
      };
    };
  };

  testIssuanceNullWhenDisabled = {
    expr = disabledResult.config.floes.cert-manager.exports.issuance;
    expected = null;
  };

  testIssuanceTokens = {
    expr = operatorOnlyResult.config.floes.cert-manager.exports.issuance;
    expected = {
      webhookReady = "cert-manager/webhook/ready";
      defaultIssuerReady = "cert-manager/default-issuer/ready";
      publicIssuer = false;
    };
  };

  testIssuancePublicWithAcme = {
    expr = acmeResult.config.floes.cert-manager.exports.issuance.publicIssuer;
    expected = true;
  };

  testDefaultIssuerRefRoot = {
    expr = selfSignedResult.config.floes.cert-manager.exports.defaultIssuerRef;
    expected = {
      name = "lab-ca";
      kind = "ClusterIssuer";
    };
  };

  testDefaultIssuerRefIntermediate = {
    expr = intermediateResult.config.floes.cert-manager.exports.defaultIssuerRef;
    expected = {
      name = "lab-ca-intermediate";
      kind = "ClusterIssuer";
    };
  };

  testDefaultIssuerRefAcme = {
    expr = acmeResult.config.floes.cert-manager.exports.defaultIssuerRef;
    expected = {
      name = "letsencrypt";
      kind = "ClusterIssuer";
    };
  };

  testDefaultIssuerRefAcmeBeatsIntermediate = {
    expr = intermediateAndAcmeResult.config.floes.cert-manager.exports.defaultIssuerRef;
    expected = {
      name = "letsencrypt";
      kind = "ClusterIssuer";
    };
  };

  testInternalIssuerRefIntermediate = {
    expr = intermediateAndAcmeResult.config.floes.cert-manager.exports.internalIssuerRef;
    expected = {
      name = "lab-ca-intermediate";
      kind = "ClusterIssuer";
    };
  };

  testInternalIssuerRefRootOnly = {
    expr = selfSignedResult.config.floes.cert-manager.exports.internalIssuerRef;
    expected = {
      name = "lab-ca";
      kind = "ClusterIssuer";
    };
  };

  testInternalIssuerRefEmptyWithAcmeOnly = {
    expr = acmeResult.config.floes.cert-manager.exports.internalIssuerRef;
    expected = { };
  };

  testSelfSignedRootIssuerEmitted = {
    expr = (issuers selfSignedResult) ? "lab-ca";
    expected = true;
  };

  testTrustManagerBundleEmitted = {
    expr =
      let
        r = issuers withTrustManagerResult;
      in
      r ? "lab-ca-bundle" && r."lab-ca-bundle".kind == "Bundle";
    expected = true;
  };

  testAcmeIssuerEmitted = {
    expr = (issuers acmeResult) ? "letsencrypt";
    expected = true;
  };

  testCrdsBundleEmitted = {
    expr =
      let
        bundle = (selfSignedResult.config.bundles).cert-manager-crds or null;
      in
      if bundle == null then null else bundle.yamls;
    expected = [ "cert-manager-crds-stub" ];
  };
}
