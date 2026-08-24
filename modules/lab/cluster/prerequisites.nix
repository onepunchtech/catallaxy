{ config, lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.cluster.prerequisites = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = {
          yamls = mkOption {
            type = types.listOf (types.either types.str types.path);
            default = [ ];
            description = "Rendered manifests the prerequisite installs, deduplicated across contributors.";
          };

          provides = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Names this supplies, in the one dependency namespace.";
          };

          requires = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Names that must be supplied and READY before this applies.";
          };

          after = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Names that must be supplied and APPLIED before this. Ordering only.";
          };

          conflicts = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Names a second provider of would be a race rather than a merge.";
          };
        };
      }
    );
    default = { };
    example = lib.literalExpression ''
      {
        gateway-api-crds = {
          yamls = [ k8sSpecs.standaloneCrds.gateway-api ];
          provides = [ "gateway-api/crds/established" ];
        };
      }
    '';
    description = ''
      Things several floes need installed and exactly one installation of
      which is correct. Each key becomes one bundle the cluster owns, holding
      the union of what every contributor asked for.

      A floe declaring a bundle directly is stamped with its name for
      `floe:<name>` anchors, so two floes declaring the same bundle is a
      conflicting definition rather than a merge: enabling cilium and gateway
      together failed outright, because both install the Gateway API CRDs.
      That is not two floes fighting, it is one thing both of them need, and
      the stamp is right to refuse an owner that is genuinely ambiguous.
      Declaring it here says the cluster owns it, which is true, so there is
      no owner to disagree about.

      Distinct from `cluster.bootstrapManifests`, which is what the cluster
      needs before its nodes are Ready and so has to arrive through the
      provisioner. A prerequisite is installed by the deploy like anything
      else; it just has more than one floe asking for it.
    '';
  };

  config.bundles = lib.mapAttrs (_: prereq: {
    declaredBy = "cluster";
    owner = {
      bootstrap = "install-target";
      steady = "argocd";
    };
    yamls = lib.unique prereq.yamls;
    provides = lib.unique prereq.provides;
    requires = lib.unique prereq.requires;
    after = lib.unique prereq.after;
    conflicts = lib.unique prereq.conflicts;
  }) config.cluster.prerequisites;
}
