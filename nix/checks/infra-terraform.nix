{
  lib,
  pkgs,
  fixtureLabs,
  exampleLabDefs,
}:

let
  tofu = pkgs.opentofu.withPlugins (p: [
    p.hashicorp_local
    p.hashicorp_null
  ]);

  # Every lab that renders a stack, not just the fixture. A cross-stack
  # reference only appears where routing splits one, and that is the shape
  # most likely to emit something terraform accepts a file of and then
  # refuses.
  labs = lib.filterAttrs (_: lab: lab.config.lab.out.infra != { }) (fixtureLabs // exampleLabDefs);

  stacks = lib.concatMapAttrs (
    labName: lab:
    lib.mapAttrs' (
      stackName: pkg: lib.nameValuePair "${labName}/${stackName}" { inherit pkg stackName; }
    ) lab.config.lab.out.infra
  ) labs;
in
{
  the-rendered-terraform-is-valid-terraform =
    pkgs.runCommand "the-rendered-terraform-is-valid-terraform"
      {
        nativeBuildInputs = [ tofu ];
      }
      ''
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: s: ''
            echo "=== stack ${name} ==="
            mkdir -p "work/${name}"
            cp ${s.pkg}/infra/${s.stackName}/main.tf.json "work/${name}/"
            cat "work/${name}/main.tf.json"

            cd "work/${name}"

            # `-backend=false` because the backend is where state lives and
            # this check never applies anything. Everything else about the
            # file is exercised: provider resolution, resource schemas, and
            # whether every interpolation resolves.
            export TF_IN_AUTOMATION=1
            if ! tofu init -backend=false -input=false > init.log 2>&1; then
              echo "tofu init failed for stack ${name}:" >&2
              cat init.log >&2
              exit 1
            fi

            if ! tofu validate -no-color > validate.log 2>&1; then
              echo "tofu validate rejected stack ${name}:" >&2
              cat validate.log >&2
              exit 1
            fi
            cd - > /dev/null
          '') stacks
        )}

        echo "every rendered stack is valid terraform" > $out
      '';
}
