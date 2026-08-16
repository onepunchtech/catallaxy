{
  lib,
  pkgs,
  mkLab,
}:

let
  baseLab = {
    lab.name = "assert-fixture";
    lab.environment = "development";
    lab.dns.enable = false;
    lab.registry.enable = false;
    lab.proxy.enable = false;
  };

  labWith =
    extra:
    builtins.tryEval (
      let
        result = mkLab {
          modules = [
            baseLab
            extra
          ];
        };
      in
      builtins.seq result.config.lab.name "evaluated"
    );

  clean = labWith { };

  labScopeFailure = labWith {
    lab.assertions = [
      {
        assertion = false;
        message = "the lab-scope assertion fired";
      }
    ];
  };

  clusterScopeFailure = labWith {
    lab.clusters.app =
      { lab, ... }:
      {
        cluster.name = "app";
        cluster.provisioner = "k3d";
        provisioner.k3d.network = lab.name;
        assertions = [
          {
            assertion = false;
            message = "the cluster-scope assertion fired";
          }
        ];
      };
  };

  failures =
    lib.optional (!clean.success) "a lab with no failing assertion should evaluate, but it threw"
    ++ lib.optional labScopeFailure.success "a failing lab.assertions entry did not fail evaluation"
    ++ lib.optional clusterScopeFailure.success "a failing lab.clusters.<n>.assertions entry did not fail evaluation";
in
{
  assertions-fail-evaluation = pkgs.runCommand "assertions-fail-evaluation" { } (
    if failures == [ ] then
      ''
        echo "lab and cluster assertions fail evaluation" > $out
      ''
    else
      ''
        cat >&2 <<'EOF'
        An assertion that should have failed evaluation did not.

        lib/eval/module.nix throws on any entry in the top-level
        `assertions`, and modules/lab/default.nix gathers `lab.assertions`
        and every `lab.clusters.<n>.assertions` into it. If that fold is
        removed, every constraint in the system silently becomes advisory
        and is only reported by `cata lab lint`.

        ${lib.concatStringsSep "\n" (map (f: "  - ${f}") failures)}
        EOF
        exit 1
      ''
  );
}
