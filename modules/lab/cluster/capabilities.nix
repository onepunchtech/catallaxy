{ config, lib, ... }:

let
  claims = lib.foldl' (
    acc: floeCfg:
    lib.foldl' (
      inner: capability:
      inner
      // {
        ${capability} = (inner.${capability} or [ ]) ++ [ floeCfg.capabilities.provides.${capability} ];
      }
    ) acc (lib.attrNames (floeCfg.capabilities.provides or { }))
  ) { } (lib.attrValues (lib.filterAttrs (_: floeCfg: floeCfg.enable or false) config.floes));
in
{
  options.cluster.capabilities.resolved = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    default = { };
    internal = true;
    description = ''
      What some floe does, addressed by the job rather than by which floe is
      doing it: each name exactly one enabled floe claims, holding what that
      floe offers for the job.

      Read as `config.cluster.capabilities.resolved.<name>.<field>`.
      `config.floes.gateway.exports.routing` names traefik specifically, so a
      cluster whose gateway is cilium answers null and every consumer refuses
      though the Gateway API is right there.

      The payload is what the provider declared under that name, not its whole
      exports, so what a consumer may read is what the provider offered for
      this job and nothing that happens to sit beside it.

      Only where exactly one enabled floe provides the name, because only then
      is there an answer: two providers of `oci-registry` are both right and
      picking one would pick it by evaluation order. A name nobody provides is
      absent rather than null, so a consumer writes
      `resolved.<name>.<field> or null` and the missing case reads the same as
      the not-provided one.

      Derived here rather than handed to a floe as an argument, so a module
      that a floe never went near can read it too.
    '';
  };

  config.cluster.capabilities.resolved = lib.mapAttrs (_: providers: builtins.head providers) (
    lib.filterAttrs (_: providers: lib.length providers == 1) claims
  );

  options.cluster.capabilities.provides = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          exclusive = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Whether a second provider of this name is a race rather than a
              merge. Two default StorageClasses make a PVC that names none
              bind to whichever the API server picks.
            '';
          };
          provider = lib.mkOption {
            type = lib.types.str;
            example = "k3s's bundled Flannel";
            description = "What to call this provider in a refusal, as a noun phrase.";
          };
          disableWith = lib.mkOption {
            type = lib.types.str;
            example = "provisioner.k3d.noFlannel = true";
            description = "The setting that stops the distribution providing it.";
          };
        };
      }
    );
    default = { };
    description = ''
      Names the cluster already supplies before any floe is enabled.

      A distribution is not a blank Kubernetes. k3s ships Flannel, ServiceLB,
      a `local-path` StorageClass marked default, and Traefik; Talos ships a
      CNI and kube-proxy. Each of those is a name some floe also provides.

      These become a bundle the cluster owns, so they answer a `requires` as
      well as colliding with a second provider: a floe that needs a CNI is
      satisfied by the one k3s already installed, which it could not be while
      this only produced assertions.

      The provisioner answers this because only it knows what its distribution
      installs, the same reason it answers
      `cluster.provisionerOut.ingressBackend`.
    '';
  };

  config.bundles = lib.mapAttrs' (
    name: claim:
    lib.nameValuePair "cluster-provided/${name}" {
      declaredBy = "cluster";
      owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };
      provides = [ name ];
      conflicts = lib.optional claim.exclusive name;
      disableWith = "${claim.disableWith}, which is how ${claim.provider} stops providing it";
    }
  ) config.cluster.capabilities.provides;
}
