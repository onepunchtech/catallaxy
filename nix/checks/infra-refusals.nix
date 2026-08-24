{
  lib,
  pkgs,
  labRefusal,
}:

let
  infra = import ../../lib/infra/ref.nix { inherit lib; };
  inherit (import ../../modules/lab/cluster/floe-options.nix { inherit lib; }) floeOptions;

  base = {
    lab.name = "infra-refusal-fixture";
    lab.environment = "development";
    lab.dns.enable = false;
    lab.registry.enable = false;
    lab.proxy.enable = false;
  };

  floeWith =
    name: contribution:
    { config, ... }:
    {
      imports = [ (floeOptions { inherit name; }) ];
      config = lib.mkIf config.floes.${name}.enable { floes.${name} = contribution; };
    };

  resource =
    attrs:
    {
      provider = "local";
      type = "local_file";
    }
    // attrs;

  refusalsFor =
    {
      lab ? { },
      clusterModules,
    }:
    labRefusal {
      modules = [
        base
        lab
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

  bucket = resource {
    inputs.filename = "b.txt";
    outputs = [ "id" ];
  };

  cases = [
    {
      what = "a reference to a resource nothing declares";
      expect = "no resource\nnamed 'typo' is declared";
      clusterModules = [
        (floeWith "a" {
          infra.resources.policy = resource { inputs.content = infra.ref "typo" "id"; };
        })
        { floes.a.enable = true; }
      ];
    }
    {
      what = "a reference to an output the target does not declare";
      expect = "does not declare as an output";
      clusterModules = [
        (floeWith "a" {
          infra.resources = {
            inherit bucket;
            policy = resource { inputs.content = infra.ref "app-bucket" "arn"; };
          };
        })
        { floes.a.enable = true; }
      ];
    }

    # Routing splits by provider here, so the two are in different stacks and
    # each reads the other. Neither can apply first.
    {
      what = "two stacks referencing each other";
      expect = "reaches itself through what it references";
      clusterModules = [
        (floeWith "a" {
          infra.resources.here = resource {
            phase = "before-clusters";
            outputs = [ "id" ];
            inputs.content = infra.ref "app-there" "id";
          };
          infra.resources.there = resource {
            phase = "after-clusters";
            provider = "null";
            type = "null_resource";
            outputs = [ "id" ];
            inputs.triggers.x = infra.ref "app-here" "id";
          };
        })
        { floes.a.enable = true; }
      ];
    }

    # `<stack>` is what gives each stack its own key. Without it two stacks
    # write one state file, and each apply reads the other's resources as
    # things to destroy.
    {
      what = "two stacks resolving to one state file";
      expect = "the same state";
      lab.lab.infra = {
        backend.s3 = {
          bucket = "tf-state";
          key = "one-key-for-everything";
        };
      };
      clusterModules = [
        (floeWith "a" {
          infra.resources.here = bucket;
          infra.resources.there = resource {
            phase = "before-clusters";
            provider = "null";
            type = "null_resource";
          };
        })
        { floes.a.enable = true; }
      ];
    }

    {
      what = "a publish naming an authored store";
      expect = "is an `authored` store";
      lab.lab.secrets.stores.authored.backend = "sops";
      clusterModules = [
        (floeWith "a" {
          infra.resources.bucket = bucket // {
            publish.id = {
              store = "authored";
              key = "X";
            };
          };
        })
        { floes.a.enable = true; }
      ];
    }

    {
      what = "a reference hidden in a chart's values";
      expect = "cannot go in a Kubernetes resource";
      clusterModules = [
        (floeWith "a" {
          infra.resources.bucket = bucket;
          bundles.app.helmCharts.c = {
            chart = "/dev/null";
            releaseName = "c";
            namespace = "d";
            values.id = infra.ref "app-bucket" "id";
          };
        })
        { floes.a.enable = true; }
      ];
    }

    {
      what = "two floes claiming one resource name";
      expect = "is\ndeclared by `floes.a` and `floes.b`";
      clusterModules = [
        (floeWith "a" { infra.resources.bucket = bucket; })
        (floeWith "b" { infra.resources.bucket = bucket; })
        { floes.a.enable = true; }
        { floes.b.enable = true; }
      ];
    }
  ];

  describe =
    c: refusals:
    "the lab should be refused by an assertion quoting '${c.expect}', but "
    + (
      if refusals == null then
        "it failed to evaluate for a reason that was not an assertion"
      else if refusals == [ ] then
        "it evaluated cleanly"
      else
        "the assertions that fired were:\n" + lib.concatMapStringsSep "\n" (m: "      * ${m}") refusals
    )
    + ": ${c.what}";

  failures = lib.concatMap (
    c:
    let
      actual = refusalsFor (
        { inherit (c) clusterModules; } // lib.optionalAttrs (c ? lab) { inherit (c) lab; }
      );
    in
    lib.optional (actual == null || actual == [ ] || !(lib.any (m: lib.hasInfix c.expect m) actual)) (
      describe c actual
    )
  ) cases;
in
{
  an-unsound-infra-reference-is-refused =
    pkgs.runCommand "an-unsound-infra-reference-is-refused" { }
      (
        if failures == [ ] then
          ''
            echo "every unsound infra declaration fails evaluation, naming what is wrong" > $out
          ''
        else
          ''
            cat >&2 <<'EOF'
            An infra declaration that should have been refused was not, or
            was refused for the wrong reason.

            A reference is the representation of a value that does not exist
            yet, so nothing at eval can check it against reality. What can be
            checked is that it is internally sound: that it names a resource
            that exists and an output that resource declares, that the stacks
            it implies can be ordered, and that each of them has its own
            state.

            Terraform's own schema catches the other half, and that is what
            `the-rendered-terraform-is-valid-terraform` is for. Neither check
            subsumes the other.

            ${lib.concatStringsSep "\n" (map (f: "  - ${f}") failures)}
            EOF
            exit 1
          ''
      );
}
