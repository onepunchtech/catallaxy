{ lib }:

{
  "apply-root-application" = import ./apply-root-application.nix { inherit lib; };
  "bootstrap-argocd-helm" = import ./bootstrap-argocd-helm.nix { inherit lib; };
  "bootstrap-argocd-kubectl-ssa" = import ./bootstrap-argocd-kubectl-ssa.nix { inherit lib; };
  "bootstrap-forgejo-repos" = import ./bootstrap-forgejo-repos.nix { inherit lib; };
  "cert-generate" = import ./cert-generate.nix { inherit lib; };
  "colima-network-route" = import ./colima-network-route.nix { inherit lib; };
  "create-cluster" = import ./create-cluster.nix { inherit lib; };
  "delete-managed-resource" = import ./delete-managed-resource.nix { inherit lib; };
  "deploy-manifests" = import ./deploy-manifests.nix { inherit lib; };
  "destroy-cluster" = import ./destroy-cluster.nix { inherit lib; };
  "dns-setup" = import ./dns-setup.nix { inherit lib; };
  "dns-teardown" = import ./dns-teardown.nix { inherit lib; };
  "docker-network-create" = import ./docker-network-create.nix { inherit lib; };
  "ensure-secrets" = import ./ensure-secrets.nix { inherit lib; };
  "host-trust-install" = import ./host-trust-install.nix { inherit lib; };
  "pivot" = import ./pivot.nix { inherit lib; };
  "publish-images" = import ./publish-images.nix { inherit lib; };
  "publish-manifests" = import ./publish-manifests.nix { inherit lib; };
  "reconcile-managed-resource" = import ./reconcile-managed-resource.nix { inherit lib; };
  "registry-setup" = import ./registry-setup.nix { inherit lib; };
  "release-cluster-cloud-resources" = import ./release-cluster-cloud-resources.nix { inherit lib; };
  "remove-network" = import ./remove-network.nix { inherit lib; };
  "remove-services" = import ./remove-services.nix { inherit lib; };
  "run-script" = import ./run-script.nix { inherit lib; };
  "setup-services" = import ./setup-services.nix { inherit lib; };
  "sync-kubeconfig" = import ./sync-kubeconfig.nix { inherit lib; };
  "trust-bundle" = import ./trust-bundle.nix { inherit lib; };
  "verify-argocd-reachable" = import ./verify-argocd-reachable.nix { inherit lib; };
  "wait-for-cluster-gone" = import ./wait-for-cluster-gone.nix { inherit lib; };
  "wait-for-resources" = import ./wait-for-resources.nix { inherit lib; };
  "warm-cache" = import ./warm-cache.nix { inherit lib; };
}
