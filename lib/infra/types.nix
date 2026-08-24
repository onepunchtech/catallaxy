{ lib }:

let
  inherit (lib) mkOption types;
in
{
  resourceType = types.submodule (
    { name, ... }:
    {
      options = {
        phase = mkOption {
          type = types.enum [
            "before-clusters"
            "after-clusters"
            "after-manifests"
          ];
          default = "after-clusters";
          description = ''
            When this resource has to exist, as a point in the lab's
            lifecycle.

            One phase is one stack, which is one state file and one apply.
            Resources sharing a phase are applied together, so the tool
            orders them from the references between them and runs the
            independent ones at the same time.

            A phase boundary is not a preference. It is there because
            something the tool cannot do happens in between: a cluster is
            created, a kubeconfig appears, a provider that could not be
            configured now can be. Splitting for any other reason costs
            parallelism and adds a state read between the halves.

            `before-clusters` for anything a cluster needs in order to exist.
            `after-clusters` for anything that needs a cluster, which is most
            things and the default. `after-manifests` for anything that needs
            the workloads running.

            Not derivable. Whether a bucket is wanted before the cluster or
            after is a fact about the world rather than about the
            declaration, so the author says it and the rest follows.
          '';
        };

        instance = mkOption {
          type = types.str;
          default = "main";
          description = ''
            Which configured instance of the provider this resource uses.

            A provider is configured under
            `lab.infra.providers.<provider>.<instance>`, so one stack can
            hold two regions or two accounts. `main` is the unaliased
            configuration and is what a resource gets without asking.
          '';
        };

        provider = mkOption {
          type = types.str;
          example = "aws";
          description = ''
            Provider that owns this resource type, as the stack configures
            it under `lab.infra.stacks.<stack>.providers`.
          '';
        };

        type = mkOption {
          type = types.str;
          example = "aws_s3_bucket";
          description = ''
            Resource type as the provider names it. Rendered as the type
            half of terraform's `resource.<type>.<name>`, and it is what a
            reference to this resource resolves through.
          '';
        };

        inputs = mkOption {
          type = types.attrsOf types.raw;
          default = { };
          description = ''
            What this resource is configured with. Values are static, or
            references to another resource's output built with
            `infra.ref`, which the renderer turns into the backend's
            interpolation syntax.
          '';
        };

        outputs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "arn" ];
          description = ''
            Attributes of this resource that other things may reference,
            declared rather than inferred.

            Declared because they are the interface: a reference to
            something absent here is refused at eval, where the provider
            would otherwise refuse it at apply, after everything before it
            in the plan had already run.
          '';
        };

        publish = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                store = mkOption {
                  type = types.str;
                  description = "Runtime store to publish into.";
                };
                key = mkOption {
                  type = types.str;
                  description = "Key the value lands under in that store.";
                };
              };
            }
          );
          default = { };
          description = ''
            Outputs to put into a runtime store once the stack has applied,
            keyed by the output's name.

            This is how a value only the apply knows reaches Kubernetes: a
            cluster reads it with `secrets.subscribe`, the same channel that
            already carries a value one cluster mints to another. A
            reference cannot be used in a manifest directly, because
            interpolation syntax in a Kubernetes resource is a literal
            string nothing resolves.
          '';
        };

        name = mkOption {
          type = types.str;
          default = name;
          internal = true;
          description = "Logical name within the stack. Defaults to the attribute key.";
        };
      };
    }
  );

  stackType = types.submodule {
    options = {
      backend = mkOption {
        type = types.nullOr (types.attrsOf types.raw);
        default = null;
        description = ''
          Where this stack's state lives, when it differs from the lab's.

          Normally null: `lab.infra.backend` covers every stack, with the
          literal `<stack>` in it replaced by the stack's name so each gets
          its own key from one declaration.
        '';
      };

      requiredProviders = mkOption {
        type = types.attrsOf (
          types.submodule {
            options.source = mkOption {
              type = types.str;
              example = "oboukili/argocd";
              description = ''
                Registry address of the provider, when the short name does not
                settle which one is meant.

                Normally unnecessary: a resource's `provider` resolves to a
                package, and the address and version are read from it. Three
                of the packaged providers share a short name, and this is how
                you say which of those you mean.
              '';
            };
          }
        );
        default = { };
        description = ''
          Providers this stack needs pinned by address rather than by name.

          What version runs is never declared here. It is the version of the
          package the lab carries, which is what the rendered stack records.
        '';
      };

      after = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Anchors this stack's apply runs after, on top of the ones derived
          from what it references.

          A stack that reads another's output is ordered after it without
          being told. This is for ordering that no reference implies.
        '';
      };

      before = mkOption {
        type = types.listOf types.str;
        default = [ "optional:kind:deploy-manifests" ];
        description = ''
          Anchors this stack's apply runs before.

          Defaults to before manifests are applied, because a manifest wanting
          a value from a stack is the common case and getting it the other way
          round means the first deploy fails on something absent. `optional:`
          so a lab with no manifests is not an error.

          Set it to `[ ]` for a stack that consumes the cluster rather than
          the cluster consuming it.
        '';
      };

      provides = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Extra tokens the apply publishes, on top of
          `infra/<stack>/applied`, which it always publishes.

          A bundle waits on one with `step:infra/<stack>/applied` through the
          bridge that already exists.
        '';
      };
    };
  };

}
