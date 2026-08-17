{ lib }:

let
  sbom = import ../render/sbom.nix { inherit lib; };

  cluster =
    {
      tree ? "/store/lab/app",
      floes ? { },
      bundles ? { },
      packages ? null,
    }:
    {
      inherit tree floes;
      view = {
        inherit bundles;
        packages = if packages != null then packages else lib.mapAttrs (_: _: "drv") bundles;
      };
    };

  gateway = {
    enable = true;
    version = "v3.3.6";
  };
  custom = {
    enable = true;
    version = null;
  };
in
lib.runTests {

  testADisabledFloeIsNotAComponent = {
    expr =
      map (f: f.name)
        (sbom.evalInput {
          labName = "l";
          clusters = [
            (cluster {
              floes = {
                inherit gateway;
                off = {
                  enable = false;
                  version = "1.0";
                };
              };
            })
          ];
        }).floes;
    expected = [ "gateway" ];
  };

  testAVersionlessFloeGetsABareRef = {
    expr =
      (builtins.head
        (sbom.evalInput {
          labName = "l";
          clusters = [ (cluster { floes = { inherit custom; }; }) ];
        }).floes
      ).ref;
    expected = "floe/custom";
  };

  testAVersionedFloeCarriesItInTheRef = {
    expr =
      (builtins.head
        (sbom.evalInput {
          labName = "l";
          clusters = [ (cluster { floes = { inherit gateway; }; }) ];
        }).floes
      ).ref;
    expected = "floe/gateway@v3.3.6";
  };

  testTheSameFloeAtOneVersionDedupesAcrossClusters = {
    expr =
      builtins.length
        (sbom.evalInput {
          labName = "l";
          clusters = [
            (cluster { floes = { inherit gateway; }; })
            (cluster { floes = { inherit gateway; }; })
          ];
        }).floes;
    expected = 1;
  };

  testTheSameFloeAtTwoVersionsStaysTwoComponents = {
    expr =
      map (f: f.ref)
        (sbom.evalInput {
          labName = "l";
          clusters = [
            (cluster { floes = { inherit gateway; }; })
            (cluster {
              floes.gateway = {
                enable = true;
                version = "v3.4.0";
              };
            })
          ];
        }).floes;
    expected = [
      "floe/gateway@v3.3.6"
      "floe/gateway@v3.4.0"
    ];
  };

  testABundleKeyIsSanitizedTheWayTheRendererNamesTheDirectory = {
    expr =
      (builtins.head
        (sbom.evalInput {
          labName = "l";
          clusters = [
            (cluster {
              floes = { inherit gateway; };
              bundles."projection/secrets" = {
                floe = "gateway";
              };
            })
          ];
        }).clusters
      ).bundles;
    expected = {
      "projection__secrets" = "floe/gateway@v3.3.6";
    };
  };

  testABundleWithNoFloeMapsToNothing = {
    expr =
      (builtins.head
        (sbom.evalInput {
          labName = "l";
          clusters = [
            (cluster {
              floes = { inherit gateway; };
              bundles = {
                namespaces = { };
                elsewhere.floe = "notrunning";
              };
            })
          ];
        }).clusters
      ).bundles;
    expected = {
      namespaces = null;
      elsewhere = null;
    };
  };

  testABundleNamedLikeAStructuralDirectoryIsACollision = {
    expr = sbom.collisionsOf [
      (cluster {
        floes = { inherit gateway; };
        bundles = {
          applications.floe = "gateway";
          ordinary.floe = "gateway";
        };
      })
    ];
    expected = [ "applications" ];
  };

  testAnOrdinaryLabHasNoCollisions = {
    expr = sbom.collisionsOf [
      (cluster {
        floes = { inherit gateway; };
        bundles.gateway.floe = "gateway";
      })
    ];
    expected = [ ];
  };

  testAChartCarriesTheFloeThatRenderedIt = {
    expr =
      (builtins.head
        (sbom.evalInput {
          labName = "l";
          clusters = [
            (cluster {
              floes = { inherit gateway; };
              bundles.gateway = {
                floe = "gateway";
                helmCharts.traefik.chart = "/store/traefik";
              };
            })
          ];
        }).clusters
      ).charts;
    expected = [
      {
        key = "traefik";
        floeRef = "floe/gateway@v3.3.6";
        path = "/store/traefik";
      }
    ];
  };
}
