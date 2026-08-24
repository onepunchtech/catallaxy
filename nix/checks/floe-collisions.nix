{
  lib,
  pkgs,
  labRefusal,
}:

let
  base = {
    lab.name = "collision-fixture";
    lab.environment = "development";
    lab.dns.enable = false;
    lab.registry.enable = false;
    lab.proxy.enable = false;
  };

  inherit (import ../../modules/lab/cluster/floe-options.nix { inherit lib; }) floeOptions;

  twin =
    name: contribution:
    { config, ... }:
    {
      imports = [ (floeOptions { inherit name; }) ];
      config = lib.mkIf config.floes.${name}.enable { floes.${name} = contribution; };
    };

  refusalsFor =
    clusterModules:
    labRefusal {
      modules = [
        base
        {
          lab.clusters.app = lib.mkMerge (
            [
              {
                cluster.name = "app";
                cluster.provisioner = "k3d";
              }
            ]
            ++ clusterModules
          );
        }
      ];
    };

  aStep = stepName: {
    steps.${stepName} = {
      kind = "run-script";
      direction = "deploy";
      params.bin = "/bin/true";
    };
  };

  anOps = category: name: {
    ops.${category}.${name} = {
      description = "does a thing";
      package = pkgs.writeShellScriptBin "thing" "true";
    };
  };

  aSecret = secretName: {
    secrets.generate.${secretName}.namespace = "default";
  };

  cases = [
    {
      what = "two floes declaring the same step key";
      expect = "step 'sync' on cluster 'app' is declared by `floes.alpha` and `floes.beta`";
      good = [
        (twin "alpha" (aStep "sync"))
        (twin "beta" (aStep "reconcile"))
        { floes.alpha.enable = true; }
        { floes.beta.enable = true; }
      ];
      bad = [
        (twin "alpha" (aStep "sync"))
        (twin "beta" (aStep "sync"))
        { floes.alpha.enable = true; }
        { floes.beta.enable = true; }
      ];
    }
    {
      what = "two floes publishing the same ops category and name";
      expect = "ops command `shared status` on cluster 'app' is published";
      good = [
        (twin "alpha" (anOps "alpha" "status"))
        (twin "beta" (anOps "beta" "status"))
        { floes.alpha.enable = true; }
        { floes.beta.enable = true; }
      ];
      bad = [
        (twin "alpha" (anOps "shared" "status"))
        (twin "beta" (anOps "shared" "status"))
        { floes.alpha.enable = true; }
        { floes.beta.enable = true; }
      ];
    }
    {
      what = "two floes minting the same generated secret";
      expect = "generated secret 'shared-password' on cluster 'app'";
      good = [
        (twin "alpha" (aSecret "alpha-password"))
        (twin "beta" (aSecret "beta-password"))
        { floes.alpha.enable = true; }
        { floes.beta.enable = true; }
        { floes.external-secrets.enable = true; }
      ];
      bad = [
        (twin "alpha" (aSecret "shared-password"))
        (twin "beta" (aSecret "shared-password"))
        { floes.alpha.enable = true; }
        { floes.beta.enable = true; }
        { floes.external-secrets.enable = true; }
      ];
    }
    {
      what = "a disabled floe does not contest a key";
      expect = "step 'sync' on cluster 'app' is declared by `floes.alpha` and `floes.beta`";
      good = [
        (twin "alpha" (aStep "sync"))
        (twin "beta" (aStep "sync"))
        { floes.alpha.enable = true; }
        { floes.beta.enable = false; }
      ];
      bad = [
        (twin "alpha" (aStep "sync"))
        (twin "beta" (aStep "sync"))
        { floes.alpha.enable = true; }
        { floes.beta.enable = true; }
      ];
    }
  ];

  describe =
    refusals:
    if refusals == null then
      "it failed to evaluate for a reason that was not an assertion"
    else if refusals == [ ] then
      "it evaluated cleanly"
    else
      "the assertions that fired were:\n" + lib.concatMapStringsSep "\n" (m: "      * ${m}") refusals;

  failures = lib.concatMap (
    c:
    let
      good = refusalsFor c.good;
      bad = refusalsFor c.bad;
    in
    lib.optional (good != [ ]) "the non-colliding lab should evaluate, but ${describe good}: ${c.what}"
    ++ lib.optional (bad == null || bad == [ ] || !(lib.any (m: lib.hasInfix c.expect m) bad)) ''
      the colliding lab should be refused by an assertion quoting
        '${c.expect}', but ${describe bad}: ${c.what}''
  ) cases;
in
{
  a-collision-between-floes-is-refused = pkgs.runCommand "a-collision-between-floes-is-refused" { } (
    if failures == [ ] then
      ''
        echo "two floes claiming one key fails evaluation, naming both" > $out
      ''
    else
      ''
        cat >&2 <<'EOF'
        Two floes are claiming one key and the lab still evaluates, or a
        lab with no collision is being refused.

        Steps, ops commands and generated secrets are lifted into one
        namespace per cluster. Without the check, the second claimant does
        not merge with the first: it collides on whichever field the two
        happen to disagree about, and the module system reports that
        naming neither floe.

        Each case runs twice, once in a shape that should work and once in
        one that should not, so a check that refuses everything fails here
        too.

        ${lib.concatStringsSep "\n" (map (f: "  - ${f}") failures)}
        EOF
        exit 1
      ''
  );
}
