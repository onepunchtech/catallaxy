{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  kanidm = import ../../../modules/lab/cluster/floes/kanidm;

  baseStubs = {
    args = {
      inherit pkgs;
      cataCharts.kanidm.chart = pkgs.emptyDirectory;
      k8sSpecs = { };
      k8sHelpers = import ../../k8s-helpers.nix { inherit lib; };
    };
  };

  stubUpstreamOptions =
    { lib, ... }:
    {
      config._module.freeformType = lib.types.attrs;
      options.lab = lib.mkOption {
        type = lib.types.attrs;
        default = {
          policy.exposure.defaultTier = "public";
        };
      };
      options.cluster.ref.kubeContext = lib.mkOption {
        type = lib.types.str;
        default = "stub-ctx";
      };
      options.floes.cert-manager.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      options.floes.gateway.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      options.floes.kaniop.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      options.floes.cert-manager.exports = lib.mkOption {
        type = lib.types.attrs;
        default = {
          issuance = {
            webhookReady = "cert-manager/webhook/ready";
            publicIssuer = false;
          };
          caBundle = null;
          defaultIssuerRef = null;
        };
      };
      options.floes.gateway.exports = lib.mkOption {
        type = lib.types.attrs;
        default = {
          routing = {
            publicReady = "gateway/public/ready";
          };
          internalEnabled = false;
          internalGatewayName = "traefik-internal";
          terminatingListenerName = "https";
          gatewayName = "stub-gateway";
          namespace = "kube-system";
          defaultTier = "public";
        };
      };
      options.floes.kaniop.exports = lib.mkOption {
        type = lib.types.attrs;
        default = {
          operator = {
            ready = "kaniop/operator/ready";
          };
        };
      };
    };

  mk =
    extra:
    evalFloe (
      {
        floe = kanidm;
        cluster = lib.recursiveUpdate {
          imports = [ stubUpstreamOptions ];
          floes.kanidm = {
            enable = true;
            domain = "idm.test.local";
          };
        } extra;
      }
      // baseStubs
    );

  disabledResult = evalFloe (
    {
      floe = kanidm;
      cluster = {
        imports = [ stubUpstreamOptions ];
        floes.kanidm.enable = false;
      };
    }
    // baseStubs
  );

  twoClients = mk {
    floes.kanidm = {
      groups.platform-admins.members = [ "lab-admin" ];
      oauth2Clients = {

        harbor = {
          origin = "https://registry.test.local";
        };

        cli = {
          origin = "https://cli.test.local";
          public = true;
        };
      };
    };
  };

  crossNamespace = mk {
    floes.kanidm.oauth2Clients.argocd = {
      origin = "https://argocd.test.local";
      namespace = "argocd";
    };
  };

  localOnly = mk {
    floes.kanidm.oauth2Clients.local = {
      origin = "https://local.test.local";
    };
  };

  labelSelector = mk {
    floes.kanidm = {
      oauth2ClientNamespaceSelector = {
        matchLabels.team = "platform";
      };
      oauth2Clients.argocd = {
        origin = "https://argocd.test.local";
        namespace = "argocd";
      };
    };
  };

  clientsOf = r: r.config.floes.kanidm.exports.oauth2Clients;
  selectorOf = r: r.config.bundles.kanidm.resources.kanidm-cr.spec.oauth2ClientNamespaceSelector;
  failed = r: map (a: a.message) (builtins.filter (a: !a.assertion) r.config.assertions);
in
lib.runTests {

  testDisabledHasNullCapability = {
    expr = disabledResult.config.floes.kanidm.exports.identity;
    expected = null;
  };

  testDisabledEmitsNoBundles = {
    expr = builtins.attrNames (disabledResult.config.bundles or { });
    expected = [ ];
  };

  testDisabledPublishesNoClients = {
    expr = clientsOf disabledResult;
    expected = { };
  };

  testDisabledLookupIsNull = {
    expr = (clientsOf disabledResult).grafana or null;
    expected = null;
  };

  testConfidentialClientHasSecretRef = {
    expr = (clientsOf twoClients).harbor.clientSecretRef.name;
    expected = "harbor-kanidm-oauth2-credentials";
  };

  testPublicClientHasNoSecretRef = {
    expr = (clientsOf twoClients).cli.clientSecretRef;
    expected = null;
  };

  testPublicClientHasNoReadyProbe = {
    expr = (clientsOf twoClients).cli.readyProbe;
    expected = { };
  };

  testConfidentialClientHasReadyProbe = {
    expr = (clientsOf twoClients).harbor.readyProbe.kind;
    expected = "jsonpath";
  };

  testCrossNamespaceClientDerivesASelectorThatConstrainsNothing = {
    expr =
      let
        s = selectorOf crossNamespace;
      in
      [
        (s != null)
        s.matchLabels
        s.matchExpressions
      ];
    expected = [
      true
      null
      null
    ];
  };

  testLocalOnlyClientsLeaveSelectorUnset = {
    expr = selectorOf localOnly;
    expected = null;
  };

  testLabelSelectorWithCrossNamespaceClientAsserts = {
    expr = builtins.length (failed labelSelector) == 1;
    expected = true;
  };

  testDerivedSelectorRaisesNoAssertion = {
    expr = failed crossNamespace;
    expected = [ ];
  };

  testGroupExportCarriesSpn = {
    expr = twoClients.config.floes.kanidm.exports.groups.platform-admins.spn;
    expected = "platform-admins@idm.test.local";
  };

  testOriginTracksDomain = {
    expr = twoClients.config.floes.kanidm.exports.oidcIssuer;
    expected = "https://idm.test.local/oauth2/openid/";
  };

  testIssuerUsesConfiguredDomain = {
    expr = (clientsOf twoClients).harbor.issuer;
    expected = "https://idm.test.local/oauth2/openid/harbor";
  };
}
