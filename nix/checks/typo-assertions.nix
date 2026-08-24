{
  lib,
  pkgs,
  labRefusal,
}:

let
  base = {
    lab.name = "typo-fixture";
    lab.environment = "development";
    lab.dns.enable = false;
    lab.registry.enable = false;
    lab.proxy.enable = false;
  };

  refusalsFor =
    extra:
    labRefusal {
      modules = [
        base
        extra
      ];
    };

  evaluates = extra: refusalsFor extra == [ ];

  # `imports` rather than `//` or `recursiveUpdate`: both of those replace a
  # nested attrset wholesale, so `floes.openbao.network` would silently drop
  # `floes.openbao.enable` and the lab under test would not be the one meant.
  mk =
    {
      cluster ? { },
      labScope ? { },
    }:
    {
      imports = [
        labScope
        {
          lab.clusters.app = lib.mkMerge [
            (
              { lab, ... }:
              {
                cluster.name = "app";
                cluster.provisioner = "k3d";
                provisioner.k3d.network = lab.name;
              }
            )
            cluster
          ];
        }
      ];
    };

  withOpenbao = reaches: {
    floes.external-secrets.enable = true;
    floes.openbao = {
      enable = true;
      network.reaches = reaches;
    };
  };

  # kanidm `requires` these two, so a fixture without them fails for an
  # unrelated reason and proves nothing about the reference it is testing.
  kanidmBase = {
    floes.cert-manager.enable = true;
    floes.gateway.enable = true;
    floes.kanidm.enable = true;
  };

  # Each pair is the same lab twice: once naming something that exists, once
  # with a typo in that one name. The first must evaluate and the second must
  # not, because an assertion that fires on everything is as useless as one
  # that fires on nothing.
  cases = [
    {
      what = "network.reaches naming a floe that does not exist";
      expect = "openbao -> external-secretz/webhook";
      good = mk { cluster = withOpenbao [ "external-secrets/webhook" ]; };
      bad = mk { cluster = withOpenbao [ "external-secretz/webhook" ]; };
    }
    {
      what = "networkPolicies.namespaceOverrides naming a namespace the cluster does not create";
      expect = "cluster.security.networkPolicies.namespaceOverrides.openbaoo";
      good = mk {
        cluster = {
          floes.openbao.enable = true;
          cluster.security.networkPolicies.namespaceOverrides.openbao.dns = true;
        };
      };
      bad = mk {
        cluster = {
          floes.openbao.enable = true;
          cluster.security.networkPolicies.namespaceOverrides.openbaoo.dns = true;
        };
      };
    }
    {
      what = "podSecurity.namespaceOverrides naming a namespace the cluster does not create";
      expect = "cluster.security.podSecurity.namespaceOverrides.kube-system";
      good = mk {
        cluster = {
          floes.openbao.enable = true;
          cluster.security.podSecurity.namespaceOverrides.openbao = "baseline";
        };
      };
      bad = mk {
        cluster = {
          floes.openbao.enable = true;
          cluster.security.podSecurity.namespaceOverrides.kube-system = "privileged";
        };
      };
    }
    {
      what = "images.pinned naming a floe no cluster enables";
      expect = "lab.images.pinned.openbaoo is not a floe";
      good = mk {
        cluster.floes.openbao.enable = true;
        labScope.lab.images.pinned.openbao.server.registry = "registry.internal";
      };
      bad = mk {
        cluster.floes.openbao.enable = true;
        labScope.lab.images.pinned.openbaoo.server.registry = "registry.internal";
      };
    }
    {
      what = "images.pinned naming a label the floe never declared";
      expect = "lab.images.pinned.openbao.serverr is not an image openbao declares";
      good = mk {
        cluster.floes.openbao.enable = true;
        labScope.lab.images.pinned.openbao.server.registry = "registry.internal";
      };
      bad = mk {
        cluster.floes.openbao.enable = true;
        labScope.lab.images.pinned.openbao.serverr.registry = "registry.internal";
      };
    }
    {
      what = "cd.clusterPaths naming a cluster this lab does not have";
      expect = "`lab.cd.clusterPaths` names apps, which is not a cluster in this lab";
      good = mk { labScope.lab.cd.clusterPaths.app = "manifests/prod"; };
      bad = mk { labScope.lab.cd.clusterPaths.apps = "manifests/prod"; };
    }
    {
      what = "kanidm group members naming an account that does not exist";
      expect = "groups.admins.members -> alicce";
      good = mk {
        cluster = lib.recursiveUpdate kanidmBase {
          floes.kanidm.users.alice = { };
          floes.kanidm.groups.admins.members = [ "alice" ];
        };
      };
      bad = mk {
        cluster = lib.recursiveUpdate kanidmBase {
          floes.kanidm.users.alice = { };
          floes.kanidm.groups.admins.members = [ "alicce" ];
        };
      };
    }
    {
      what = "kanidm scopeMap naming a group that does not exist";
      expect = "oauth2Clients.app.scopeMap -> adminz";
      good = mk {
        cluster = lib.recursiveUpdate kanidmBase {
          floes.kanidm.groups.admins = { };
          floes.kanidm.oauth2Clients.app = {
            origin = "https://app.test.local";
            scopeMap = [ { group = "admins"; } ];
          };
        };
      };
      bad = mk {
        cluster = lib.recursiveUpdate kanidmBase {
          floes.kanidm.groups.admins = { };
          floes.kanidm.oauth2Clients.app = {
            origin = "https://app.test.local";
            scopeMap = [ { group = "adminz"; } ];
          };
        };
      };
    }
  ];

  describe =
    c:
    let
      bad = refusalsFor c.bad;
    in
    "the typo should be refused by an assertion quoting '${c.expect}', but "
    + (
      if bad == null then
        "it failed to evaluate for a reason that was not an assertion"
      else if bad == [ ] then
        "it evaluated cleanly"
      else
        "the assertions that fired were:\n" + lib.concatMapStringsSep "\n" (m: "      * ${m}") bad
    )
    + ": ${c.what}";

  failures = lib.concatMap (
    c:
    lib.optional (
      !(evaluates c.good)
    ) "the lab without the typo should evaluate, but it threw: ${c.what}"
    ++ lib.optional (
      let
        bad = refusalsFor c.bad;
      in
      bad == null || bad == [ ] || !(lib.any (m: lib.hasInfix c.expect m) bad)
    ) (describe c)
  ) cases;
in
{
  a-mistyped-name-is-refused-not-ignored =
    pkgs.runCommand "a-mistyped-name-is-refused-not-ignored" { }
      (
        if failures == [ ] then
          ''
            echo "every free-form name that matches nothing fails evaluation" > $out
          ''
        else
          ''
            cat >&2 <<'EOF'
            A free-form option key that names nothing is being ignored rather
            than refused.

            These options are keyed by a name the lab writes by hand: a floe,
            a namespace, an image label, a cluster, an account. Nothing checks
            spelling, and the consumer of each reads with a fallback, so a
            typo does not fail. It renders one fewer rule, one fewer label,
            one fewer member, and the lab comes up subtly wrong in a way that
            looks like a bug in the thing being configured.

            Each case below is run twice, once spelled correctly and once
            with a typo, so an assertion that refuses everything fails here
            too.

            ${lib.concatStringsSep "\n" (map (f: "  - ${f}") failures)}
            EOF
            exit 1
          ''
      );
}
