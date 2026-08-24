use super::plan::{Direction, Idempotency};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepKind {
    SetupServices,
    DockerNetworkCreate,
    CertGenerate,
    TrustBundle,
    HostTrustInstall,
    DnsSetup,
    DnsTeardown,
    ColimaNetworkRoute,
    RegistrySetup,
    WarmCache,
    CreateCluster,
    EnsureSecrets,
    DeployManifests,
    WaitForResources,
    SyncKubeconfig,
    Pivot,
    PublishImages,
    PublishManifests,
    ApplyRootApplication,
    BootstrapForgejoRepos,
    BootstrapArgocdKubectlSsa,
    BootstrapArgocdHelm,
    VerifyArgocdReachable,
    RunScript,
    InfraPlan,
    InfraApply,
    InfraDestroy,
    DestroyCluster,
    ReconcileManagedResource,
    DeleteManagedResource,
    WaitForClusterGone,
    ReleaseClusterCloudResources,
    RemoveNetwork,
    RemoveServices,
}

impl StepKind {
    pub const ALL: [StepKind; 34] = [
        StepKind::SetupServices,
        StepKind::DockerNetworkCreate,
        StepKind::CertGenerate,
        StepKind::TrustBundle,
        StepKind::HostTrustInstall,
        StepKind::DnsSetup,
        StepKind::DnsTeardown,
        StepKind::ColimaNetworkRoute,
        StepKind::RegistrySetup,
        StepKind::WarmCache,
        StepKind::CreateCluster,
        StepKind::EnsureSecrets,
        StepKind::DeployManifests,
        StepKind::WaitForResources,
        StepKind::SyncKubeconfig,
        StepKind::Pivot,
        StepKind::PublishImages,
        StepKind::PublishManifests,
        StepKind::ApplyRootApplication,
        StepKind::BootstrapForgejoRepos,
        StepKind::BootstrapArgocdKubectlSsa,
        StepKind::BootstrapArgocdHelm,
        StepKind::VerifyArgocdReachable,
        StepKind::RunScript,
        StepKind::InfraPlan,
        StepKind::InfraApply,
        StepKind::InfraDestroy,
        StepKind::DestroyCluster,
        StepKind::ReconcileManagedResource,
        StepKind::DeleteManagedResource,
        StepKind::WaitForClusterGone,
        StepKind::ReleaseClusterCloudResources,
        StepKind::RemoveNetwork,
        StepKind::RemoveServices,
    ];

    pub fn from_tag(tag: &str) -> Option<StepKind> {
        StepKind::ALL.into_iter().find(|k| k.tag() == tag)
    }

    pub fn tag(self) -> &'static str {
        match self {
            StepKind::SetupServices => "setup-services",
            StepKind::DockerNetworkCreate => "docker-network-create",
            StepKind::CertGenerate => "cert-generate",
            StepKind::TrustBundle => "trust-bundle",
            StepKind::HostTrustInstall => "host-trust-install",
            StepKind::DnsSetup => "dns-setup",
            StepKind::DnsTeardown => "dns-teardown",
            StepKind::ColimaNetworkRoute => "colima-network-route",
            StepKind::RegistrySetup => "registry-setup",
            StepKind::WarmCache => "warm-cache",
            StepKind::CreateCluster => "create-cluster",
            StepKind::EnsureSecrets => "ensure-secrets",
            StepKind::DeployManifests => "deploy-manifests",
            StepKind::WaitForResources => "wait-for-resources",
            StepKind::SyncKubeconfig => "sync-kubeconfig",
            StepKind::Pivot => "pivot",
            StepKind::PublishImages => "publish-images",
            StepKind::PublishManifests => "publish-manifests",
            StepKind::ApplyRootApplication => "apply-root-application",
            StepKind::BootstrapForgejoRepos => "bootstrap-forgejo-repos",
            StepKind::BootstrapArgocdKubectlSsa => "bootstrap-argocd-kubectl-ssa",
            StepKind::BootstrapArgocdHelm => "bootstrap-argocd-helm",
            StepKind::VerifyArgocdReachable => "verify-argocd-reachable",
            StepKind::RunScript => "run-script",
            StepKind::InfraPlan => "infra-plan",
            StepKind::InfraApply => "infra-apply",
            StepKind::InfraDestroy => "infra-destroy",
            StepKind::DestroyCluster => "destroy-cluster",
            StepKind::ReconcileManagedResource => "reconcile-managed-resource",
            StepKind::DeleteManagedResource => "delete-managed-resource",
            StepKind::WaitForClusterGone => "wait-for-cluster-gone",
            StepKind::ReleaseClusterCloudResources => "release-cluster-cloud-resources",
            StepKind::RemoveNetwork => "remove-network",
            StepKind::RemoveServices => "remove-services",
        }
    }

    pub fn retry(self) -> Idempotency {
        match self {
            StepKind::CreateCluster | StepKind::Pivot => Idempotency::OneShot,
            StepKind::DestroyCluster
            | StepKind::DeleteManagedResource
            | StepKind::InfraDestroy
            | StepKind::RemoveNetwork
            | StepKind::RemoveServices => Idempotency::Destructive,
            StepKind::SetupServices
            | StepKind::DockerNetworkCreate
            | StepKind::CertGenerate
            | StepKind::TrustBundle
            | StepKind::HostTrustInstall
            | StepKind::DnsSetup
            | StepKind::DnsTeardown
            | StepKind::ColimaNetworkRoute
            | StepKind::RegistrySetup
            | StepKind::WarmCache
            | StepKind::EnsureSecrets
            | StepKind::DeployManifests
            | StepKind::WaitForResources
            | StepKind::SyncKubeconfig
            | StepKind::PublishImages
            | StepKind::PublishManifests
            | StepKind::ApplyRootApplication
            | StepKind::BootstrapForgejoRepos
            | StepKind::BootstrapArgocdKubectlSsa
            | StepKind::BootstrapArgocdHelm
            | StepKind::VerifyArgocdReachable
            | StepKind::RunScript
            | StepKind::WaitForClusterGone
            | StepKind::ReconcileManagedResource
            | StepKind::InfraPlan
            | StepKind::InfraApply
            | StepKind::ReleaseClusterCloudResources => Idempotency::Idempotent,
        }
    }

    pub fn runs_in(self, direction: Direction) -> bool {
        let (deploy, teardown) = match self {
            StepKind::RunScript | StepKind::DestroyCluster => (true, true),
            StepKind::InfraDestroy
            | StepKind::ReconcileManagedResource
            | StepKind::DeleteManagedResource
            | StepKind::WaitForClusterGone
            | StepKind::ReleaseClusterCloudResources
            | StepKind::RemoveNetwork
            | StepKind::RemoveServices
            | StepKind::DnsTeardown => (false, true),
            StepKind::SetupServices
            | StepKind::DockerNetworkCreate
            | StepKind::CertGenerate
            | StepKind::TrustBundle
            | StepKind::HostTrustInstall
            | StepKind::DnsSetup
            | StepKind::ColimaNetworkRoute
            | StepKind::RegistrySetup
            | StepKind::WarmCache
            | StepKind::CreateCluster
            | StepKind::EnsureSecrets
            | StepKind::DeployManifests
            | StepKind::WaitForResources
            | StepKind::SyncKubeconfig
            | StepKind::Pivot
            | StepKind::PublishImages
            | StepKind::PublishManifests
            | StepKind::ApplyRootApplication
            | StepKind::BootstrapForgejoRepos
            | StepKind::BootstrapArgocdKubectlSsa
            | StepKind::BootstrapArgocdHelm
            | StepKind::InfraPlan
            | StepKind::InfraApply
            | StepKind::VerifyArgocdReachable => (true, false),
        };
        match direction {
            Direction::Deploy => deploy,
            Direction::Teardown => teardown,
        }
    }

    pub fn dry_run_safe(self) -> bool {
        match self {
            StepKind::WaitForResources
            | StepKind::VerifyArgocdReachable
            | StepKind::InfraPlan
            | StepKind::WaitForClusterGone => true,
            StepKind::SetupServices
            | StepKind::DockerNetworkCreate
            | StepKind::CertGenerate
            | StepKind::TrustBundle
            | StepKind::HostTrustInstall
            | StepKind::DnsSetup
            | StepKind::DnsTeardown
            | StepKind::ColimaNetworkRoute
            | StepKind::RegistrySetup
            | StepKind::WarmCache
            | StepKind::CreateCluster
            | StepKind::EnsureSecrets
            | StepKind::DeployManifests
            | StepKind::SyncKubeconfig
            | StepKind::Pivot
            | StepKind::PublishImages
            | StepKind::PublishManifests
            | StepKind::ApplyRootApplication
            | StepKind::BootstrapForgejoRepos
            | StepKind::BootstrapArgocdKubectlSsa
            | StepKind::BootstrapArgocdHelm
            | StepKind::RunScript
            | StepKind::InfraApply
            | StepKind::InfraDestroy
            | StepKind::DestroyCluster
            | StepKind::ReconcileManagedResource
            | StepKind::DeleteManagedResource
            | StepKind::ReleaseClusterCloudResources
            | StepKind::RemoveNetwork
            | StepKind::RemoveServices => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_kind_round_trips_through_its_tag() {
        for kind in StepKind::ALL {
            assert_eq!(StepKind::from_tag(kind.tag()), Some(kind), "{kind:?}");
        }
    }

    #[test]
    fn tags_are_unique() {
        let mut tags: Vec<&str> = StepKind::ALL.iter().map(|k| k.tag()).collect();
        tags.sort_unstable();
        let before = tags.len();
        tags.dedup();
        assert_eq!(before, tags.len(), "two kinds share a tag");
    }

    #[test]
    fn every_kind_runs_in_at_least_one_direction() {
        for kind in StepKind::ALL {
            assert!(
                kind.runs_in(Direction::Deploy) || kind.runs_in(Direction::Teardown),
                "{kind:?} can never be dispatched"
            );
        }
    }
}
