{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  harbor = import ../../../modules/lab/cluster/floes/harbor;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.harbor = {
        chart = pkgs.emptyDirectory;
      };
    };
  };

  stubUpstream =
    { lib, ... }:
    {
      config._module.freeformType = lib.types.attrs;
      # Null capabilities, which `refs.needs` reads as "this peer provides
      # nothing", so a floe evaluated on its own still has a resolvable
      # `requires`.
      options.floes.gateway.exports = lib.mkOption {
        type = lib.types.attrs;
        default = {
          routing = null;
          internalGatewayName = "stub-internal";
          gatewayName = "stub-gateway";
          namespace = "kube-system";
          defaultTier = "public";
        };
      };
      options.floes.cert-manager.exports = lib.mkOption {
        type = lib.types.attrs;
        default = {
          issuance = null;
          caBundle = null;
        };
      };
      options.floes.gateway.internalHostnames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      options.floes.gateway.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      options.floes.cert-manager.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };

  client = grantedScopes: {
    clientId = "harbor";
    issuer = "https://idm.test.local/oauth2/openid/grafana";
    clientSecretRef = {
      name = "harbor-kanidm-oauth2-credentials";
      namespace = "kanidm";
      key = "CLIENT_SECRET";
    };
    inherit grantedScopes;
  };

  mk =
    {
      providers ? { },
      oidc,
    }:
    evalFloe (
      baseArgs
      // {
        inherit providers;
        floe = harbor;
        cluster = {
          imports = [ stubUpstream ];
          floes.harbor = {
            enable = true;
            domain = "registry.test.local";
            inherit oidc;
          };
        };
      }
    );

  failures = r: map (a: a.message) (builtins.filter (a: !a.assertion) r.config.assertions);

  underGranted = mk {
    providers.kanidm.oauth2Clients.harbor = client [ "openid" ];
    oidc = {
      enable = true;
      scopes = [
        "openid"
        "groups"
      ];
    };
  };

  fullyGranted = mk {
    providers.kanidm.oauth2Clients.harbor = client [
      "openid"
      "groups"
    ];
    oidc = {
      enable = true;
      scopes = [
        "openid"
        "groups"
      ];
    };
  };

  noProvider = mk {
    oidc = {
      enable = true;
      scopes = [
        "openid"
        "groups"
      ];
    };
  };

  # No lab in the repo configures harbor projects, so without this the
  # conversion from generated shell to a JSON document would be unverified.
  withProjects = evalFloe (
    baseArgs
    // {
      floe = harbor;
      cluster = {
        imports = [ stubUpstream ];
        floes.harbor = {
          enable = true;
          domain = "registry.test.local";
          projects.team = {
            public = false;
            storageQuota = 1073741824;
            members.developers = {
              entityType = "group";
              role = "developer";
            };
            immutableTagRules = [
              {
                disabled = false;
                scope_selectors.repository = [
                  {
                    decoration = "repoMatches";
                    kind = "doublestar";
                    pattern = "**";
                  }
                ];
              }
            ];
          };
        };
      };
    }
  );

  projectsJson =
    let
      containers =
        withProjects.config.bundles.harbor.resources.harbor-project-bootstrap.spec.template.spec.containers;
      env = (builtins.head containers).env;
      var = builtins.head (builtins.filter (e: e.name == "PROJECTS_JSON") env);
    in
    builtins.fromJSON var.value;

  oidcOff = mk {
    providers.kanidm.oauth2Clients.harbor = client [ ];
    oidc.enable = false;
  };
in
lib.runTests {

  testUnderGrantedScopesFail = {
    expr = builtins.length (failures underGranted);
    expected = 1;
  };

  testFailureNamesTheMissingScope = {
    expr = lib.hasInfix "groups" (builtins.head (failures underGranted));
    expected = true;
  };

  testFullyGrantedPasses = {
    expr = failures fullyGranted;
    expected = [ ];
  };

  testNoProviderFailsWithAClearMessage = {
    expr = failures noProvider;
    expected = [
      "harbor OIDC login is enabled but no identity provider publishes an OAuth2 client named \"harbor\"."
    ];
  };

  testNoProviderLeavesClientNull = {
    expr = noProvider.config.floes.harbor.oidc.client;
    expected = null;
  };

  testDisabledOidcEmitsNoScopeAssertion = {
    expr = builtins.any (a: lib.hasInfix "oidc.scopes" a.message) oidcOff.config.assertions;
    expected = false;
  };

  testClientResolvesFromProvider = {
    expr = fullyGranted.config.floes.harbor.oidc.client.clientSecretRef.name;
    expected = "harbor-kanidm-oauth2-credentials";
  };

  # The script iterates this. It used to be a shell program Nix wrote per
  # project, so the shape is now the contract between the two.
  testProjectsAreRenderedAsData = {
    expr =
      let
        p = builtins.head projectsJson;
      in
      [
        (builtins.length projectsJson)
        p.name
        p.storageQuota
        p.registry
        p.retention
        p.cveAllowlist
        (builtins.length p.immutableRules)
        p.members
      ];
    expected = [
      1
      "team"
      1073741824
      null
      null
      null
      1
      [
        {
          entity = "developers";
          entityType = 2;
          roleId = 2;
        }
      ]
    ];
  };

  # The group suffix is applied to a group member's name and not to a user's.
  # It was applied at the point the shell line was generated, so this is the
  # same rule in the new place.
  testAGroupMemberCarriesTheOidcSuffix = {
    expr = (builtins.head (builtins.head projectsJson).members).entity;
    expected = "developers";
  };

  # Harbor's admin password and secret key used to come from a Job that shelled
  # out to /dev/urandom and skipped itself if the Secret already existed.
  testTheMintJobIsGone = {
    expr = builtins.attrNames (
      lib.filterAttrs (
        n: _: lib.hasInfix "admin-bootstrap" n
      ) withProjects.config.bundles.harbor.resources
    );
    expected = [ ];
  };

  # The ServiceAccount and Role it ran under stay: the OIDC, robot and project
  # Jobs are still bound to them.
  testTheBootstrapRbacRemains = {
    expr = map (n: withProjects.config.bundles.harbor.resources.${n}.kind) [
      "harbor-admin-sa"
      "harbor-admin-role"
      "harbor-admin-rb"
    ];
    expected = [
      "ServiceAccount"
      "Role"
      "RoleBinding"
    ];
  };

}
