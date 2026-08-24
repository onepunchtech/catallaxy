{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  delivery = import ../../../modules/lab/cluster/floes/delivery;

  eval =
    cd:
    (evalFloe {
      floe = delivery;
      args = {
        inherit pkgs;
        lab = { inherit cd; };
      };
    }).config.floes.delivery.exports;

  kapp = eval {
    strategy = "kapp";
    bootstrap = "kubectl-ssa";
    git.repo = "";
  };

  argocd = eval {
    strategy = "argocd";
    bootstrap = "helm";
    git.repo = "git@example.com:org/manifests.git";
  };

  emptyLab =
    (evalFloe {
      floe = delivery;
      args = {
        inherit pkgs;
        lab = { };
      };
    }).config.floes.delivery.exports;
in
lib.runTests {
  testStrategyCarriesThrough = {
    expr = kapp.strategy;
    expected = "kapp";
  };

  testBootstrapToolCarriesThrough = {
    expr = argocd.bootstrapTool;
    expected = "helm";
  };

  testGitRepoCarriesThrough = {
    expr = argocd.gitRepo;
    expected = "git@example.com:org/manifests.git";
  };

  testKappStrategyAppliesWithKapp = {
    expr = kapp.appliedByKapp;
    expected = true;
  };

  testPullBasedStrategyDoesNotApplyWithKapp = {
    expr = argocd.appliedByKapp;
    expected = false;
  };

  testAppliedByKappNeverFollowsTheBootstrapTool = {
    expr = argocd.bootstrapTool == "kapp";
    expected = false;
  };

  testALabThatSaysNothingStillAnswers = {
    expr = emptyLab.strategy;
    expected = "kapp";
  };
}
