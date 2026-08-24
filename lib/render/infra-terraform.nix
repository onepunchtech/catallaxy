{ lib }:

let
  refs = import ../infra/ref.nix { inherit lib; };

  outputName = resourceName: output: "${resourceName}_${output}";
in
{
  inherit outputName;

  # One stack, as terraform's JSON syntax.
  #
  # Takes every stack, not just this one, because a reference that leaves this
  # stack is resolved through the target's own type and read out of the
  # target's state. Both of those are facts about the other stack.
  stack =
    {
      name,
      stacks,
      publishedOutputs ? [ ],
    }:
    let
      here = stacks.${name};
      inherit (here) resources;

      everywhere = lib.foldl' (acc: s: acc // s.resources) { } (lib.attrValues stacks);

      # Which stack a resource is in, read from where it actually is rather
      # than from what it says. The two agree when the module assembled them,
      # and a renderer that trusted the field would quietly emit a remote
      # state pointing at itself if they ever stopped agreeing.
      stackOf =
        let
          index = lib.foldl' (
            acc: stackName: acc // lib.genAttrs (lib.attrNames stacks.${stackName}.resources) (_: stackName)
          ) { } (lib.attrNames stacks);
        in
        resourceName: index.${resourceName} or name;

      resolve = refs.resolveWith {
        resources = everywhere;
        crossStack = {
          inherit stackOf;
          here = name;
        };
      };

      # A resource on an aliased instance has to say so; one on `main` uses
      # the unaliased configuration and says nothing, which is what terraform
      # expects.
      resolved = lib.mapAttrs (
        _: r:
        resolve r.inputs
        // lib.optionalAttrs (r.instance != "main") { provider = "${r.provider}.${r.instance}"; }
      ) resources;

      byType = lib.foldl' (
        acc: resourceName:
        let
          r = resources.${resourceName};
        in
        acc
        // {
          ${r.type} = (acc.${r.type} or { }) // {
            ${resourceName} = resolved.${resourceName};
          };
        }
      ) { } (lib.attrNames resources);

      foreign = lib.unique (
        lib.filter (s: s != name && stacks ? ${s}) (
          map (ref: stackOf ref.resource) (
            lib.concatLists (lib.mapAttrsToList (_: r: refs.refsIn r.inputs) resources)
          )
        )
      );

      # `terraform_remote_state`'s config has the same shape as a backend
      # block, so the producer's passes through. `local` is the exception: its
      # path is read relative to the consumer's working directory, and the
      # stacks are siblings there.
      remoteStates = lib.listToAttrs (
        map (
          producer:
          let
            backend = stacks.${producer}.backend;
            kind = lib.head (lib.attrNames backend);
            config = backend.${kind};
          in
          lib.nameValuePair producer {
            backend = kind;
            config =
              if kind == "local" then
                config // { path = "../${producer}/${config.path or "${producer}.tfstate"}"; }
              else
                config;
          }
        ) foreign
      );

      # Terraform takes a list under a provider name when there is more than
      # one configuration of it, and every configuration but the default
      # carries an `alias`.
      providerBlocks = lib.mapAttrs (
        provider: instances:
        let
          blocks = lib.mapAttrsToList (
            instance: config: config // lib.optionalAttrs (instance != "main") { alias = instance; }
          ) instances;
        in
        if lib.length blocks == 1 && instances ? main then lib.head blocks else blocks
      ) (lib.filterAttrs (_: instances: instances != { }) here.providers);

      outputs = lib.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (
            resourceName: r:
            map (
              output:
              lib.nameValuePair (outputName resourceName output) (
                {
                  value = resolve (refs.ref resourceName output);
                }
                // lib.optionalAttrs (builtins.elem (outputName resourceName output) publishedOutputs) {
                  # Published means the value goes to a secret store, and a
                  # secret printed in every plan and apply log is not much of
                  # one. `tofu output -json` still returns it, so publishing
                  # is unaffected.
                  sensitive = true;
                }
              )
            ) r.outputs
          ) resources
        )
      );
    in
    {
      terraform = {
        inherit (here) backend;
      }
      // lib.optionalAttrs (here.requiredProviders != { }) {
        required_providers = lib.mapAttrs (
          _: p: { inherit (p) source; } // lib.optionalAttrs (p.version != null) { inherit (p) version; }
        ) here.requiredProviders;
      };
    }
    // lib.optionalAttrs (providerBlocks != { }) { provider = providerBlocks; }
    // lib.optionalAttrs (remoteStates != { }) { data.terraform_remote_state = remoteStates; }
    // lib.optionalAttrs (resources != { }) { resource = byType; }
    // lib.optionalAttrs (outputs != { }) { output = outputs; };
}
