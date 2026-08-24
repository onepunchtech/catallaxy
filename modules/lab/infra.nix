{
  config,
  lib,
  pkgs,
  ...
}:

let
  infraTypes = import ../../lib/infra/types.nix { inherit lib; };
  check = import ../../lib/infra/check.nix { inherit lib; };
  refs = import ../../lib/infra/ref.nix { inherit lib; };
  tokens = import ../../lib/plan-tokens.nix { inherit lib; };
  providers = import ../../lib/infra/providers.nix { inherit lib; };

  labFloes = lib.filterAttrs (_: floe: floe.enable or false) (config.lab.floes or { });

  # A floe names a resource as it knows it, and the fold gives it a
  # lab-unique name. Both halves have to move: a reference to a sibling in
  # the same cluster is rewritten with it, so the floe never says the
  # cluster's name and two clusters running the same floe do not collide.
  # A reference to a lab floe's resource is left alone, because that one was
  # never prefixed.
  fromClusters = lib.concatMapAttrs (
    clusterName: clusterCfg:
    let
      local = clusterCfg.infra.resources;
      rename = name: if local ? ${name} then "${clusterName}-${name}" else name;
    in
    lib.mapAttrs' (
      resourceName: resource:
      lib.nameValuePair "${clusterName}-${resourceName}" (
        resource // { inputs = refs.renameRefs rename resource.inputs; }
      )
    ) local
  ) config.lab.out.allClusters;

  cfg = config.lab.infra;

  # A phase is a stack, so the resource's own phase is its stack name. There
  # is nothing to route: the author said when, and when is where.
  routed = lib.mapAttrs (_: resource: resource // { stack = resource.phase; }) cfg.resources;

  phaseOrder = [
    "before-clusters"
    "after-clusters"
    "after-manifests"
  ];

  stackNames = lib.filter (phase: resourcesIn phase != { }) phaseOrder;

  resourcesIn = stackName: lib.filterAttrs (_: r: r.stack == stackName) routed;

  providersUsedIn =
    stackName: lib.unique (lib.mapAttrsToList (_: r: r.provider) (resourcesIn stackName));

  instancesUsedIn =
    stackName: provider:
    lib.unique (
      lib.mapAttrsToList (_: r: r.instance) (
        lib.filterAttrs (_: r: r.provider == provider) (resourcesIn stackName)
      )
    );

  clustersExist = map (c: "optional:provides:${(tokens.cluster c).created}") (
    lib.attrNames config.lab.out.allClusters
  );

  # Where a phase sits, in the vocabulary steps and bundles already use.
  # `optional:` throughout, so a lab with no clusters or no manifests is not
  # an error, it just has fewer things to sit between.
  anchorsFor = {
    before-clusters = {
      after = [ ];
      before = [ "optional:kind:create-cluster" ];
    };
    after-clusters = {
      after = clustersExist;
      before = [ "optional:kind:deploy-manifests" ];
    };
    after-manifests = {
      after = [ "optional:kind:deploy-manifests" ];
      before = [ ];
    };
  };

  overrideFor = stackName: cfg.stacks.${stackName} or null;

  # One backend declaration covers every stack, with `<stack>` standing in for
  # the name. Without something like it, a lab either writes a backend per
  # stack or two stacks quietly share one state file.
  substituted =
    stackName: value:
    if builtins.isString value then
      lib.replaceStrings [ "<stack>" ] [ stackName ] value
    else if builtins.isAttrs value then
      lib.mapAttrs (_: substituted stackName) value
    else if builtins.isList value then
      map (substituted stackName) value
    else
      value;

  backendFor =
    stackName:
    let
      override = overrideFor stackName;
    in
    if override != null && override.backend != null then
      substituted stackName override.backend
    else
      substituted stackName cfg.backend;

  requiredFor =
    stackName:
    lib.listToAttrs (
      map (
        provider:
        lib.nameValuePair provider (
          providers.resolve {
            plugins = pkgs.opentofu.plugins;
            inherit provider;
            source =
              let
                override = overrideFor stackName;
              in
              if override != null && override.requiredProviders ? ${provider} then
                override.requiredProviders.${provider}.source
              else
                null;
          }
        )
      ) (providersUsedIn stackName)
    );

  assembled = lib.listToAttrs (
    map (
      stackName:
      let
        override = overrideFor stackName;
      in
      lib.nameValuePair stackName {
        name = stackName;
        resources = resourcesIn stackName;
        backend =
          let
            b = backendFor stackName;
            kind = lib.head (lib.attrNames b);
          in
          if kind == "local" then
            {
              local = {
                path = "${stackName}.tfstate";
              }
              // b.local;
            }
          else
            b;
        requiredProviders = requiredFor stackName;
        providers = lib.listToAttrs (
          map (
            provider:
            lib.nameValuePair provider (
              lib.filterAttrs (instance: _: builtins.elem instance (instancesUsedIn stackName provider)) (
                cfg.providers.${provider} or { }
              )
            )
          ) (providersUsedIn stackName)
        );
        after = anchorsFor.${stackName}.after ++ (if override == null then [ ] else override.after);
        before = anchorsFor.${stackName}.before ++ (if override == null then [ ] else override.before);
        provides = if override == null then [ ] else override.provides;
      }
    ) stackNames
  );

  # A stack that reads another's output cannot run first. The edge comes from
  # the reference rather than from anything declared, the same way terraform
  # orders resources inside one stack.
  readsFrom =
    stackName:
    lib.unique (
      lib.concatLists (
        lib.mapAttrsToList (
          _: r:
          map (found: routed.${found.ref.resource}.stack) (
            lib.filter (found: routed ? ${found.ref.resource}) (check.refsWithPath "" r.inputs)
          )
        ) (resourcesIn stackName)
      )
    );

  producersFor = stackName: lib.filter (s: s != stackName) (readsFrom stackName);

  # Teardown runs the other way round. A stack whose output another reads has
  # to outlive it, or the consumer's destroy runs against a resource that is
  # already gone.
  consumersOf =
    stackName: lib.filter (other: builtins.elem stackName (producersFor other)) stackNames;

  manifestErrors =
    if routed == { } then
      [ ]
    else
      lib.concatLists (
        lib.mapAttrsToList (
          clusterName: clusterCfg:
          map (m: "On cluster ${clusterName}: ${m}") (check.manifestRefErrors clusterCfg.bundles)
        ) config.lab.out.allClusters
      );
in
{
  options.lab.infra.backend = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    default = {
      local = { };
    };
    example = lib.literalExpression ''{ s3 = { bucket = "tf-state"; key = "labs/<stack>"; }; }'';
    description = ''
      Where this lab's state lives, as one entry naming the backend and
      carrying its settings.

      The literal `<stack>` anywhere in it is replaced with the stack's name,
      so one declaration gives every stack its own key. Two stacks resolving
      to the same key is refused: sharing a state file silently is the worst
      thing this can do.

      Defaults to a local file in each stack's own working directory, which
      needs no configuration and is right for a lab you can throw away.
    '';
  };

  options.lab.infra.providers = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    default = { };
    example = lib.literalExpression ''{ aws = { region = "us-east-1"; }; }'';
    description = ''
      Provider configuration, keyed by provider name and then by instance,
      written once for the lab and emitted into each stack that has a
      resource using it.

      The instance level is what lets one stack hold two regions or two
      accounts. `main` is the unaliased configuration; every other name
      becomes a provider alias, and a resource asks for one by name.

      Credentials do not belong here. A provider reads them from the
      environment the apply runs in, which is what keeps them out of the
      rendered file and out of state.
    '';
  };

  options.lab.infra.stacks = lib.mkOption {
    type = lib.types.attrsOf infraTypes.stackType;
    default = { };
    description = ''
      Per-stack overrides, for a stack that needs a different backend or
      ordering than the lab's.

      Not where a stack is declared. A stack exists because something routes
      into it, so there is no way to declare one that holds nothing and no
      way to route into one that does not exist.
    '';
  };

  options.lab.infra.resources = lib.mkOption {
    type = lib.types.attrsOf infraTypes.resourceType;
    default = { };
    description = ''
      Every resource this lab provisions, assembled from lab floes directly
      and from each cluster's with the cluster's name prefixed.

      One namespace across the lab, because a stack's state is one
      namespace. Read by the renderer, and by the reference checks, which
      need the whole table to resolve a reference through its target.
    '';
  };

  options.lab.infra.out.stacks = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    readOnly = true;
    internal = true;
    description = ''
      Each stack as the renderer sees it: its resources, its backend, the
      providers it uses and the versions they will run at.

      Derived. A lab declares the backend and the provider configuration, and
      a floe declares when each resource is needed; which stacks exist, what
      is in them and the order they run in all follow.
    '';
  };

  config.lab.infra.resources = lib.mkMerge [
    (lib.mkMerge (lib.mapAttrsToList (_: floe: floe.infra.resources) labFloes))
    fromClusters
  ];

  config.lab.infra.out.stacks = assembled;

  config.lab.steps = lib.mkMerge (
    map (stackName: {
      "infra-plan-${stackName}" = {
        kind = "infra-plan";
        direction = "deploy";
        description = "Show what stack '${stackName}' would change";
        params.stack = stackName;
        after = assembled.${stackName}.after ++ map (p: "infra/${p}/applied") (producersFor stackName);
        provides = [ "infra/${stackName}/planned" ];
      };

      "infra-apply-${stackName}" = {
        kind = "infra-apply";
        direction = "deploy";
        description = "Apply stack '${stackName}'";
        params.stack = stackName;
        after = [ "infra/${stackName}/planned" ];
        before = assembled.${stackName}.before;
        provides = [ "infra/${stackName}/applied" ] ++ assembled.${stackName}.provides;
      };

      "infra-destroy-${stackName}" = {
        kind = "infra-destroy";
        direction = "teardown";
        description = "Destroy stack '${stackName}'";
        params.stack = stackName;
        after = [
          "optional:kind:destroy-cluster"
        ]
        ++ map (c: "optional:infra/${c}/destroyed") (consumersOf stackName);
        provides = [ "infra/${stackName}/destroyed" ];
      };
    }) stackNames
  );

  config.lab.assertions =
    map
      (message: {
        assertion = false;
        inherit message;
      })
      (
        check.referenceErrors routed
        ++ check.phaseOrderErrors {
          resources = routed;
          order = phaseOrder;
        }
        ++ check.identifierErrors {
          resources = routed;
          stacks = stackNames;
        }
        ++ check.backendCollisionErrors assembled
        ++ check.stackCycleErrors {
          inherit routed;
          stacks = stackNames;
        }
        ++ check.publishErrors {
          resources = routed;
          stores = config.lab.secrets.stores;
        }
        ++ manifestErrors
      );
}
