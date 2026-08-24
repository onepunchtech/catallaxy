{
  lib,
  pkgs,
  mkLab,
}:

let
  allFloes = lib.attrNames (
    lib.filterAttrs (_: t: t == "directory") (builtins.readDir ../../modules/lab/cluster/floes)
  );

  # Nothing is enabled. A consumer may read an export while computing its own
  # option default, and that is evaluated whether or not the producer is on,
  # so the disabled cluster is the case the rule is about.
  cluster =
    (mkLab {
      modules = [
        {
          lab.name = "floe-exports";
          lab.environment = "development";
          lab.dns.enable = false;
          lab.registry.enable = false;
          lab.proxy.enable = false;
          lab.clusters.probe = {
            cluster.name = "probe";
            cluster.provisioner = "k3d";
            provisioner.k3d.network = "floe-exports";
          };
        }
      ];
    }).config.lab.clusters.probe;

  # A floe that exports nothing declares no `exports` at all, which is fine;
  # the rule is about fields that exist but cannot be read.
  readable =
    name: (builtins.tryEval (builtins.deepSeq (cluster.floes.${name}.exports or { }) true)).success;

  missing = lib.filter (name: !readable name) allFloes;
in
{
  every-floe-export-has-a-default = pkgs.runCommand "every-floe-export-has-a-default" { } ''
    ${lib.optionalString (missing != [ ]) ''
      echo "these floes have an export that cannot be read while they are off:" >&2
      ${lib.concatMapStringsSep "\n" (f: ''echo "  ${f}" >&2'') missing}
      echo "" >&2
      echo "Give every field under exports a default. A consumer may read" >&2
      echo "one while computing its own option default, which evaluates" >&2
      echo "whether or not the producing floe is enabled, so an export" >&2
      echo "with no default breaks a lab that never turned the floe on." >&2
      echo "" >&2
      echo "Where there is genuinely no value until the floe runs, the" >&2
      echo "default is null and the type is nullOr, so a consumer can ask." >&2
      exit 1
    ''}
    touch $out
  '';
}
