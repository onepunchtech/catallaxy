{
  lib,
  pkgs,
  e2eLabs,
}:

let
  testsDir = ../../lib/tests;
  floesDir = ../../lib/tests/floes;

  mkCheck =
    name: results:
    pkgs.runCommand "${name}-tests" { } ''
      cat <<'EOF' > $out
      ${builtins.toJSON results}
      EOF
      if [ ${toString (builtins.length results)} -ne 0 ]; then
        echo "${name} FAILED:" >&2
        cat $out >&2
        exit 1
      fi
    '';

  pure = {
    coredns-internal = testsDir + "/coredns-internal.nix";
    k8s-helpers = testsDir + "/k8s-helpers.nix";
    k8s-fields = testsDir + "/k8s-fields.nix";
    k3d-volumes = testsDir + "/k3d-volumes.nix";
    idempotent-job = testsDir + "/util-idempotent-job.nix";
    wait-helpers = testsDir + "/util-wait.nix";
    hcl = testsDir + "/util-hcl.nix";
    image-types = testsDir + "/image-types.nix";
    netpol = testsDir + "/netpol.nix";
    sbom = testsDir + "/sbom.nix";
    drift-lowering = testsDir + "/drift.nix";
    plan-graph = testsDir + "/plan-graph.nix";
    manifest-graph = testsDir + "/manifest-graph.nix";
    manifest-autoedges = testsDir + "/manifest-autoedges.nix";
    manifest-projections = testsDir + "/manifest-projections.nix";
    secret-sharing = testsDir + "/secret-sharing.nix";
    secret-stores = testsDir + "/secret-stores.nix";
    eval-floe = testsDir + "/floe/eval-floe.nix";
    cluster-lint = testsDir + "/cluster-lint.nix";
  };

  withPkgs = {
    secret-generate = testsDir + "/secret-generate.nix";
    manifest-waves = testsDir + "/manifest-waves.nix";
    floe-options = testsDir + "/floe/floe-options.nix";
    infra-refs = testsDir + "/infra/refs.nix";
    infra-providers = testsDir + "/infra/providers.nix";
    render-images = testsDir + "/render-images.nix";
  };

  floeTests = [
    "argocd"
    "boundary"
    "cert-manager"
    "cnpg"
    "custom"
    "exports-defaults"
    "external-dns"
    "forgejo"
    "gateway"
    "grafana"
    "harbor"
    "kanidm"
    "kaniop"
    "loki"
    "netbird"
    "openbao"
    "openebs"
    "prometheus"
    "redis-operator"
    "seaweedfs"
    "tempo"
    "trust-manager"
    "velero"
    "zot"
  ];

  onDisk = map (lib.removeSuffix ".nix") (
    lib.attrNames (
      lib.filterAttrs (file: kind: kind == "regular" && lib.hasSuffix ".nix" file) (
        builtins.readDir floesDir
      )
    )
  );

  unregistered = lib.subtractLists floeTests onDisk;
  missing = lib.subtractLists onDisk floeTests;

  floeSuites = lib.listToAttrs (
    map (name: {
      name = "floe-${name}";
      value = import (floesDir + "/${name}.nix") { inherit lib pkgs; };
    }) floeTests
  );

  suites =
    lib.mapAttrs (_: path: import path { inherit lib; }) pure
    // lib.mapAttrs (_: path: import path { inherit lib pkgs; }) withPkgs
    // floeSuites
    // {
      self-contained = import (testsDir + "/self-contained.nix") { inherit lib e2eLabs; };

      contracts-oidc =
        import (testsDir + "/contracts/oidc-scopes.nix") { inherit lib pkgs; }
        ++ import (testsDir + "/contracts/oidc-client-type.nix") { inherit lib pkgs; };
    };
in
assert lib.assertMsg (unregistered == [ ]) ''
  lib/tests/floes holds test files no check runs: ${lib.concatStringsSep ", " unregistered}.
  Add them to floeTests in nix/checks/lib-tests.nix.
'';
assert lib.assertMsg (missing == [ ]) ''
  floeTests in nix/checks/lib-tests.nix names tests that do not exist: ${lib.concatStringsSep ", " missing}.
'';
lib.mapAttrs mkCheck suites
