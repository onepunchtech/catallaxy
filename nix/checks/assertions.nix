{
  lib,
  pkgs,
  mkLab,
  labRefusal,
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

  # Two questions, because `tryEval` answers only the first. That evaluation
  # failed says nothing about which assertion failed it, so a lab that broke
  # for an unrelated reason would read as a pass.
  firedFor =
    extra:
    let
      refusals = labRefusal {
        modules = [
          baseLab
          extra
        ];
      };
    in
    if refusals == null then [ ] else refusals;

  quotes = extra: text: lib.any (m: lib.hasInfix text m) (firedFor extra);

  labScopeEntry = {
    lab.assertions = [
      {
        assertion = false;
        message = "the lab-scope assertion fired";
      }
    ];
  };

  clusterScopeEntry = {
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
    ++ lib.optional (firedFor { } != [ ]) "a lab with no failing assertion reported one anyway"
    ++ lib.optional labScopeFailure.success "a failing lab.assertions entry did not fail evaluation"
    ++ lib.optional (
      !(quotes labScopeEntry "the lab-scope assertion fired")
    ) "evaluation failed, but not because the lab-scope assertion fired"
    ++ lib.optional clusterScopeFailure.success "a failing lab.clusters.<n>.assertions entry did not fail evaluation"
    ++ lib.optional (
      !(quotes clusterScopeEntry "the cluster-scope assertion fired")
    ) "evaluation failed, but not because the cluster-scope assertion fired";
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

  a-bgp-router-says-which-lab-it-belongs-to =
    let
      routerName =
        labName:
        (mkLab {
          modules = [
            {
              lab.name = labName;
              lab.environment = "development";
              lab.dns.enable = false;
              lab.registry.enable = false;
              lab.proxy.enable = false;
              lab.bgpRouter.enable = true;
            }
          ];
        }).config.lab.bgpRouter.out.service.container;

      one = routerName "lab-one";
      two = routerName "lab-two";
    in
    pkgs.runCommand "a-bgp-router-says-which-lab-it-belongs-to" { } (
      if one != two && lib.hasInfix "lab-one" one then
        "echo 'the bgp router carries its lab name' > $out"
      else
        ''
          cat >&2 <<'EOF'
          Two labs render the same BGP router container name.

            lab-one: ${one}
            lab-two: ${two}

          It used to default to a bare 'catallaxy-router', which no lab
          claimed: `lab list` could not say whose a running one was, and
          `lab cleanup` could not remove it as part of a lab.

          This does not make two BGP labs co-runnable. The router is
          host-networked and binds BGP/179, so they still collide; the name
          is about knowing which lab a running one belongs to.
          EOF
          exit 1
        ''
    );
}
