{ lib, pkgs }:

let
  # `lib/tests/manifest-graph.nix` tests the resolver against hand-built
  # bundles, which is why `kind:` and `floe:` could sit inert for so long: the
  # fixtures set those fields and the real graph builder passed null. These
  # evaluate a lab and assert on the waves it actually produces.
  wavesOf =
    cluster:
    (lib.evalModules {
      modules = [
        ../../modules/lab
        {
          _module.args.pkgs = pkgs;
          lab.name = "t";
          lab.dns.zone = "t.test";
          lab.clusters.c = cluster;
        }
      ];
    }).config.lab.clusters.c.cluster.out.manifestWaves;

  indexOf =
    waves: name:
    let
      hit = lib.filter (w: builtins.elem name (map (b: b.name) w.wave)) (
        lib.imap0 (i: wave: {
          inherit i;
          wave = wave;
        }) waves
      );
    in
    if hit == [ ] then null else (builtins.head hit).i;

  resource = kind: name: {
    apiVersion = if kind == "ConfigMap" then "v1" else "apiextensions.k8s.io/v1";
    inherit kind;
    metadata = {
      inherit name;
      namespace = "default";
    };
  };

  crd = {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    metadata.name = "widgets.example.com";
    spec = {
      group = "example.com";
      scope = "Namespaced";
      names = {
        kind = "Widget";
        plural = "widgets";
        singular = "widget";
      };
      versions = [
        {
          name = "v1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };

  # The consumer names no edge at all: emitting a Widget is what puts it after
  # whoever installs the Widget CRD.
  ordered = wavesOf {
    bundles.crds.declaredBy = "cluster";
    bundles.crds.resources.widgets = crd;
    bundles.consumer.declaredBy = "cluster";
    bundles.consumer.resources.w = {
      apiVersion = "example.com/v1";
      kind = "Widget";
      metadata = {
        name = "hello";
        namespace = "default";
      };
    };
  };

  # A chart's kinds are not eval-visible, so a bundle whose CRDs arrive that
  # way says what it installs rather than being scanned for it.
  chartOnly = wavesOf {
    bundles.chart.declaredBy = "cluster";
    bundles.chart.helmCharts.thing = {
      chart = pkgs.emptyDirectory;
      releaseName = "thing";
      namespace = "default";
    };
    bundles.user.declaredBy = "cluster";
    bundles.user = {
      resources.cm = resource "ConfigMap" "cm";
      after = [ "optional:kind:apps/Deployment" ];
    };
  };

  # `floe:` needs a real floe, because provenance is the key a bundle is
  # declared under and a lab-declared bundle carries none.
  withFloe = wavesOf {
    floes.reloader.enable = true;
    bundles.user.declaredBy = "cluster";
    bundles.user = {
      resources.cm = resource "ConfigMap" "cm";
      after = [ "floe:reloader" ];
    };
  };

  throws = e: !(builtins.tryEval (builtins.deepSeq e e)).success;
in
lib.runTests {

  # The case the nulls made impossible. `after every CRD bundle` without
  # naming each one is the whole reason the anchor exists.
  testAKindAnchorOrdersAgainstTheRealGraph = {
    expr =
      let
        crds = indexOf ordered "crds";
        consumer = indexOf ordered "consumer";
      in
      crds != null && consumer != null && crds < consumer;
    expected = true;
  };

  # A hard anchor matching nothing is an eval error, not a silently missing
  # edge, which is what makes the anchor safe to rely on.
  testAHardKindAnchorMatchingNothingThrows = {
    expr = throws (wavesOf {
      bundles.user.declaredBy = "cluster";
      bundles.user = {
        resources.cm = resource "ConfigMap" "cm";
        after = [ "kind:example.com/NoSuchKind" ];
      };
    });
    expected = true;
  };

  # The derived form of the same refusal: nothing here says `after`, the
  # Widget resource does.
  testACustomResourceWithNoCrdThrows = {
    expr = throws (wavesOf {
      bundles.orphan.declaredBy = "cluster";
      bundles.orphan.resources.w = {
        apiVersion = "example.com/v1";
        kind = "Widget";
        metadata = {
          name = "hello";
          namespace = "default";
        };
      };
    });
    expected = true;
  };

  # Pins the documented limitation rather than leaving it to be discovered:
  # a chart's kinds are not eval-visible, so this bundle answers nothing.
  testAChartOnlyBundleAnswersNoKindAnchor = {
    expr = indexOf chartOnly "user" != null;
    expected = true;
  };

  testAFloeAnchorOrdersAgainstEveryBundleThatFloeDeclared = {
    expr =
      let
        reloader = indexOf withFloe "reloader";
        user = indexOf withFloe "user";
      in
      reloader != null && user != null && reloader < user;
    expected = true;
  };

  testAFloeAnchorNamingNoFloeThrows = {
    expr = throws (wavesOf {
      bundles.user.declaredBy = "cluster";
      bundles.user = {
        resources.cm = resource "ConfigMap" "cm";
        after = [ "floe:nothing" ];
      };
    });
    expected = true;
  };
}
