{
  lib,
  pkgs,
  mkLab,
}:

let
  labWith =
    openbao:
    (mkLab {
      modules = [
        {
          lab.name = "bao-fixture";
          lab.environment = "development";
          lab.dns.enable = false;
          lab.registry.enable = false;
          lab.proxy.enable = false;
          lab.clusters.app = {
            cluster.name = "app";
            cluster.provisioner = "k3d";
            provisioner.k3d.network = "bao-fixture";
            floes.external-secrets.enable = true;
            floes.openbao = {
              enable = true;
            }
            // openbao;
          };
        }
      ];
    }).config;

  handUnsealed = labWith {
    mode = "standalone";
    seal = { };
  };
in
{
  # The floe's own suite sees the `ops` attrset it writes; only a lab sees
  # what the aggregator makes of it. This is the seam between the two.
  openbao-publishes-its-unseal-commands =
    pkgs.runCommand "openbao-publishes-its-unseal-commands" { }
      ''
        tool=${handUnsealed.lab.ops.out.tool}/bin/bao-fixture-ops
        test -x "$tool" || { echo "no ops tool was generated" >&2; exit 1; }

        # Anchored on the generated `case` branch, not on a substring: every
        # one of these words also appears in seal-status's own description,
        # so a loose grep passes on prose while the command is absent.
        for want in initialise unseal seal-status; do
          grep -qE "^$want\)" "$tool" || {
            echo "the generated tool has no '$want' branch" >&2
            exit 1
          }
        done

        # Category and name are separate words in the invocation, so a
        # command filed under the wrong one is unreachable even though the
        # branch exists.
        grep -qE "^[[:space:]]+openbao\)" "$tool" || {
          echo "the commands are not under the openbao category" >&2
          exit 1
        }

        touch $out
      '';
}
