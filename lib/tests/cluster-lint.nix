{ lib }:

let
  check = description: {
    inherit description;
    command = "true";
  };

  evalCluster =
    {
      labChecks ? { },
      cluster ? { },
    }:
    (lib.evalModules {
      modules = [
        ../../modules/lab
        {
          lab.name = "t";
          lab.dns.zone = "t.test";
          lab.lint.checks = labChecks;
          lab.clusters.c = cluster;
        }
      ];
    }).config.lab.clusters.c.lint.out.checks;
in
lib.runTests {

  # Prefixed the way `verify` prefixes, so two floes can name a check the same
  # thing and the lint directory stays a flat namespace per cluster.
  testAFloeCheckIsPrefixedWithTheFloeName = {
    expr = builtins.attrNames (evalCluster {
      cluster = {
        floes.gateway.enable = true;
        floes.gateway.lint.no-bare-image = check "from the floe";
      };
    });
    expected = [
      "gateway-no-bare-image"
      "gateway-route-listener-exists"
    ];
  };

  testADisabledFloeContributesNothing = {
    expr = builtins.attrNames (evalCluster {
      cluster.floes.gateway.lint.no-bare-image = check "from the floe";
    });
    expected = [ ];
  };

  testALabCheckReachesEveryCluster = {
    expr = builtins.attrNames (evalCluster {
      labChecks.house-style = check "from the lab";
    });
    expected = [ "house-style" ];
  };

  # Precedence is floe, then lab, then cluster: the narrower scope wins,
  # because it is the one that knows about the exception.
  testAClusterCheckWinsOverALabCheckOfTheSameName = {
    expr =
      (evalCluster {
        labChecks.x = check "from the lab";
        cluster.lint.checks.x = check "from the cluster";
      }).x.description;
    expected = "from the cluster";
  };

  testALabCheckWinsOverAFloeCheckOfTheSameName = {
    expr =
      (evalCluster {
        labChecks.gateway-x = check "from the lab";
        cluster = {
          floes.gateway.enable = true;
          floes.gateway.lint.x = check "from the floe";
        };
      }).gateway-x.description;
    expected = "from the lab";
  };
}
