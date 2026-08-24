{
  config,
  lib,
  lab,
  ...
}:
let
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions;
  cd = lab.cd or { };
  strategy = cd.strategy or "kapp";
in
{
  imports = [
    (floeOptions {
      name = "delivery";
    })
  ];

  options.floes.delivery.exports = {
    strategy = lib.mkOption {
      type = lib.types.enum [
        "kapp"
        "argocd"
        "fleet"
      ];
      default = "kapp";
      description = ''
        How rendered manifests reach a cluster: `kapp` applies them
        directly, `argocd` and `fleet` sync them from git.

        Read this rather than `lab.cd.strategy`. A floe that changes what
        it renders because of the delivery strategy is depending on a
        decision, and the decision should have one owner.
      '';
    };

    bootstrapTool = lib.mkOption {
      type = lib.types.enum [
        "kubectl-ssa"
        "helm"
        "none"
      ];
      default = "kubectl-ssa";
      description = ''
        Which imperative tool applies the install-target bundles before a
        pull-based strategy can reconcile the rest. Meaningless under
        `strategy = "kapp"`, which applies everything itself.

        Note the two are different questions: this names the tool that
        goes first, `strategy` names what reconciles afterwards, and
        neither answer implies the other.
      '';
    };

    appliedByKapp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether kapp is what applies this lab's manifests, and so whether
        `kapp.k14s.io` resources a floe emits will be read by anything.

        Derived rather than left to each consumer, because the obvious
        spelling is wrong: `bootstrapTool` never takes the value "kapp",
        so a floe testing it against that string silently renders
        nothing. `crossplane` did exactly that (2026-08-23).
      '';
    };

    gitRepo = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Git repository the rendered manifests are published to, empty
        when nothing publishes them.
      '';
    };
  };

  config = {
    floes.delivery.enable = lib.mkDefault true;

    floes.delivery.network.declared = true;

    floes.delivery.imagesComplete = true;

    floes.delivery.exports = {
      inherit strategy;
      bootstrapTool = cd.bootstrap or "kubectl-ssa";
      appliedByKapp = strategy == "kapp";
      gitRepo = (cd.git or { }).repo or "";
    };
  };
}
