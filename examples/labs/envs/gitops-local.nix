# Local GitOps — k3d with ArgoCD + Forgejo, full GitOps loop
#
# lab up: bootstraps cluster via direct-apply (kapp format)
# lab publish: pushes argocd-format manifests to local Forgejo
# ArgoCD syncs from Forgejo automatically
{ ... }:
{
  lab.name = "homelab.gitops";
  lab.environment = "development";

  lab.dns.enable = true;
  lab.registry.enable = true;
  lab.proxy.enable = true;

  # ArgoCD strategy — manifests rendered as ArgoCD Applications
  lab.cd.strategy = "argocd";
  lab.cd.argocd = {
    repoUrl = "https://git.homelab.gitops.test/infrastructure/manifests.git";
    targetBranch = "main";
  };
  lab.cd.git = {
    repo = "https://git.homelab.gitops.test/infrastructure/manifests.git";
    branch = "main";
    provider = "forgejo";
  };

  lab.clusters.core =
    { lab, ... }:
    {
      imports = [
        ../clusters/core.nix
        ../provisioners/k3d.nix
      ];
      provisioner.k3d.network = lab.name;
    };
}
