use serde::Deserialize;

use super::step_kind::StepKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Deploy,
    Teardown,
}

impl Direction {
    pub fn of_teardown_flag(teardown: bool) -> Self {
        if teardown {
            Direction::Teardown
        } else {
            Direction::Deploy
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Direction::Deploy => "deployment",
            Direction::Teardown => "teardown",
        }
    }
}
use serde_json::{Map, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Idempotency {
    Idempotent,
    OneShot,
    Destructive,
}

impl Idempotency {
    pub fn attempts(self) -> u32 {
        match self {
            Idempotency::Idempotent => 3,
            Idempotency::OneShot | Idempotency::Destructive => 1,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OnFailure {
    Fatal,
    Continue,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StepPolicy {
    pub retry: Idempotency,
    #[serde(default = "fatal")]
    pub on_failure: OnFailure,
    #[serde(default)]
    pub interactive: bool,
    #[serde(default)]
    pub skip_if_cluster_reachable: Option<String>,
}

fn fatal() -> OnFailure {
    OnFailure::Fatal
}

#[derive(Debug, Clone, Deserialize)]
#[serde(try_from = "WirePlannedStep")]
pub struct PlannedStep {
    pub name: String,
    pub origin: String,
    pub description: String,
    pub cluster: Option<String>,
    pub policy: StepPolicy,
    pub params: StepParams,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WirePlannedStep {
    name: String,
    #[serde(default)]
    origin: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    cluster: Option<String>,
    kind: String,
    policy: StepPolicy,
    #[serde(default)]
    params: Map<String, Value>,
}

impl TryFrom<WirePlannedStep> for PlannedStep {
    type Error = serde_json::Error;

    fn try_from(wire: WirePlannedStep) -> Result<Self, Self::Error> {
        let mut tagged = wire.params;
        tagged.insert("kind".into(), Value::String(wire.kind));
        Ok(PlannedStep {
            name: wire.name,
            origin: wire.origin,
            description: wire.description,
            cluster: wire.cluster,
            policy: wire.policy,
            params: serde_json::from_value(Value::Object(tagged))?,
        })
    }
}

impl PlannedStep {
    pub fn kind(&self) -> StepKind {
        self.params.kind()
    }

    pub fn type_tag(&self) -> &'static str {
        self.kind().tag()
    }

    pub fn runs_in(&self, direction: Direction) -> bool {
        self.kind().runs_in(direction)
    }

    pub fn refuse_wrong_direction(&self, direction: Direction, index: usize) -> anyhow::Result<()> {
        if self.runs_in(direction) {
            return Ok(());
        }
        anyhow::bail!(
            "{} plan step {} is '{}', which the executor only runs in the \
             other direction. Refusing to start: aborting part-way through \
             would leave the lab half-built.",
            direction.label(),
            index + 1,
            self.type_tag(),
        )
    }

    pub fn dry_run_safe(&self) -> bool {
        self.kind().dry_run_safe()
    }

    pub fn attempts(&self) -> u32 {
        if self.policy.interactive {
            1
        } else {
            self.policy.retry.attempts()
        }
    }

    pub fn continues_on_failure(&self) -> bool {
        self.policy.on_failure == OnFailure::Continue
    }

    pub fn label(&self) -> &str {
        if self.description.is_empty() {
            &self.name
        } else {
            &self.description
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct ScriptEnv {
    pub name: String,
    pub secret: String,
    pub key: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum StepParams {
    SetupServices(SetupServicesParams),
    DockerNetworkCreate(DockerNetworkCreateParams),
    CertGenerate(CertGenerateParams),
    TrustBundle(TrustBundleParams),
    HostTrustInstall(HostTrustInstallParams),
    DnsSetup(DnsSetupParams),
    DnsTeardown(DnsTeardownParams),
    ColimaNetworkRoute(ColimaNetworkRouteParams),
    RegistrySetup(RegistrySetupParams),
    WarmCache(WarmCacheParams),
    CreateCluster(CreateClusterParams),
    EnsureSecrets(EnsureSecretsParams),
    DeployManifests(DeployManifestsParams),
    WaitForResources(WaitForResourcesParams),
    SyncKubeconfig(SyncKubeconfigParams),
    Pivot(PivotParams),
    PublishImages(PublishImagesParams),
    PublishManifests(PublishManifestsParams),
    ApplyRootApplication(ApplyRootApplicationParams),
    BootstrapForgejoRepos(BootstrapForgejoReposParams),
    BootstrapArgocdKubectlSsa(BootstrapArgocdKubectlSsaParams),
    BootstrapArgocdHelm(BootstrapArgocdHelmParams),
    VerifyArgocdReachable(VerifyArgocdReachableParams),
    RunScript(RunScriptParams),
    DestroyCluster(DestroyClusterParams),
    ReconcileManagedResource(ReconcileManagedResourceParams),
    DeleteManagedResource(DeleteManagedResourceParams),
    WaitForClusterGone(WaitForClusterGoneParams),
    ReleaseClusterCloudResources(ReleaseClusterCloudResourcesParams),
    RemoveNetwork(RemoveNetworkParams),
    RemoveServices(RemoveServicesParams),
}

#[derive(Debug, Clone, Deserialize)]
pub struct SetupServicesParams {}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerNetworkCreateParams {
    pub name: String,
    pub subnet: String,
    pub gateway: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CertGenerateParams {
    pub zone: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TrustBundleParams {}

#[derive(Debug, Clone, Deserialize)]
pub struct HostTrustInstallParams {}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DnsSetupParams {
    pub host: String,
    pub port: u64,
    pub zone: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DnsTeardownParams {
    pub zone: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColimaNetworkRouteParams {
    pub subnet: String,
    pub profile: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistrySetupParams {
    pub port: u64,
    #[serde(default)]
    pub upstreams: Vec<String>,
    pub zone: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WarmCacheParams {}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateClusterParams {
    pub name: String,
    pub provisioner: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnsureSecretsParams {
    #[serde(default)]
    pub stores: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeployManifestsParams {
    pub target: String,
    #[serde(default)]
    pub bootstrap: bool,
    #[serde(default)]
    pub kube_context: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaitForResourcesParams {
    pub target: String,
    #[serde(default)]
    pub resources: Vec<Value>,
    #[serde(default)]
    pub wait_timeout_seconds: Option<u64>,
    #[serde(default)]
    pub kube_context: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncKubeconfigParams {
    pub target: String,
    #[serde(default)]
    pub clusters: Vec<String>,
    #[serde(default)]
    pub kube_context: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PivotParams {
    pub cluster: String,
    pub bootstrap_context: String,
    pub target_context: String,
    pub provisioner: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PublishImagesParams {
    pub source_cluster: String,
    #[serde(default)]
    pub images: Vec<Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PublishManifestsParams {}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyRootApplicationParams {
    pub target: String,
    #[serde(default)]
    pub namespace: Option<String>,
    #[serde(default)]
    pub manifest_path: Option<String>,
    #[serde(default)]
    pub kube_context: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BootstrapForgejoReposParams {
    pub target: String,
    #[serde(default)]
    pub namespace: Option<String>,
    #[serde(default)]
    pub job_label_selector: Option<String>,
    #[serde(default)]
    pub kube_context: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BootstrapArgocdKubectlSsaParams {
    pub target: String,
    pub manifest_root: String,
    #[serde(default)]
    pub kube_context: Option<String>,
    #[serde(default)]
    pub field_manager: Option<String>,
    #[serde(default)]
    pub namespace: Option<String>,
    #[serde(default)]
    pub wait_timeout_seconds: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BootstrapArgocdHelmParams {
    pub target: String,
    pub values_path: String,
    pub chart_ref: String,
    pub release_name: String,
    #[serde(default)]
    pub kube_context: Option<String>,
    #[serde(default)]
    pub namespace: Option<String>,
    #[serde(default)]
    pub wait_timeout_seconds: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VerifyArgocdReachableParams {
    pub target: String,
    #[serde(default)]
    pub kube_context: Option<String>,
    #[serde(default)]
    pub namespace: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunScriptParams {
    pub bin: String,
    #[serde(default)]
    pub env: Vec<ScriptEnv>,
    #[serde(default)]
    pub kube_context: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DestroyClusterParams {
    pub name: String,
    pub provisioner: String,
    #[serde(default)]
    pub skip_if_missing: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReconcileManagedResourceParams {
    pub target: String,
    pub resource_kind: String,
    pub resource_name: String,
    #[serde(default)]
    pub kube_context: Option<String>,
    #[serde(default)]
    pub external_name_discovery_bin: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeleteManagedResourceParams {
    pub target: String,
    pub resource_kind: String,
    pub resource_name: String,
    #[serde(default)]
    pub wait: Option<bool>,
    #[serde(default)]
    pub wait_timeout_seconds: Option<u64>,
    #[serde(default)]
    pub kube_context: Option<String>,
    #[serde(default)]
    pub external_name_discovery_bin: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaitForClusterGoneParams {
    #[serde(default)]
    pub target: Option<String>,
    #[serde(default)]
    pub kube_context: Option<String>,
    #[serde(default)]
    pub resource_kind: Option<String>,
    #[serde(default)]
    pub resource_name: Option<String>,
    #[serde(default)]
    pub wait_timeout_seconds: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseClusterCloudResourcesParams {
    pub target: String,
    #[serde(default)]
    pub kube_context: Option<String>,
    #[serde(default)]
    pub wait_timeout_seconds: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RemoveNetworkParams {}

#[derive(Debug, Clone, Deserialize)]
pub struct RemoveServicesParams {}

impl StepParams {
    pub fn cluster_refs(&self) -> Vec<(&'static str, &str)> {
        match self {
            StepParams::CreateCluster(p) => vec![("name", &p.name)],
            StepParams::DeployManifests(p) => vec![("target", &p.target)],
            StepParams::WaitForResources(p) => vec![("target", &p.target)],
            StepParams::SyncKubeconfig(p) => vec![("target", &p.target)],
            StepParams::Pivot(p) => vec![("cluster", &p.cluster)],
            StepParams::PublishImages(p) => vec![("sourceCluster", &p.source_cluster)],
            StepParams::ApplyRootApplication(p) => vec![("target", &p.target)],
            StepParams::BootstrapForgejoRepos(p) => vec![("target", &p.target)],
            StepParams::DestroyCluster(p) => vec![("name", &p.name)],
            StepParams::ReconcileManagedResource(p) => vec![("target", &p.target)],
            StepParams::DeleteManagedResource(p) => vec![("target", &p.target)],
            StepParams::WaitForClusterGone(p) => p
                .target
                .as_deref()
                .map(|t| vec![("target", t)])
                .unwrap_or_default(),
            StepParams::ReleaseClusterCloudResources(p) => vec![("target", &p.target)],
            StepParams::BootstrapArgocdKubectlSsa(p) => vec![("target", &p.target)],
            StepParams::BootstrapArgocdHelm(p) => vec![("target", &p.target)],
            StepParams::VerifyArgocdReachable(p) => vec![("target", &p.target)],

            StepParams::SetupServices(_)
            | StepParams::DockerNetworkCreate(_)
            | StepParams::CertGenerate(_)
            | StepParams::TrustBundle(_)
            | StepParams::HostTrustInstall(_)
            | StepParams::DnsSetup(_)
            | StepParams::DnsTeardown(_)
            | StepParams::ColimaNetworkRoute(_)
            | StepParams::RegistrySetup(_)
            | StepParams::WarmCache(_)
            | StepParams::EnsureSecrets(_)
            | StepParams::PublishManifests(_)
            | StepParams::RunScript(_)
            | StepParams::RemoveNetwork(_)
            | StepParams::RemoveServices(_) => Vec::new(),
        }
    }

    pub fn kind(&self) -> StepKind {
        match self {
            StepParams::SetupServices(_) => StepKind::SetupServices,
            StepParams::DockerNetworkCreate(_) => StepKind::DockerNetworkCreate,
            StepParams::CertGenerate(_) => StepKind::CertGenerate,
            StepParams::TrustBundle(_) => StepKind::TrustBundle,
            StepParams::HostTrustInstall(_) => StepKind::HostTrustInstall,
            StepParams::DnsSetup(_) => StepKind::DnsSetup,
            StepParams::DnsTeardown(_) => StepKind::DnsTeardown,
            StepParams::ColimaNetworkRoute(_) => StepKind::ColimaNetworkRoute,
            StepParams::RegistrySetup(_) => StepKind::RegistrySetup,
            StepParams::WarmCache(_) => StepKind::WarmCache,
            StepParams::CreateCluster(_) => StepKind::CreateCluster,
            StepParams::EnsureSecrets(_) => StepKind::EnsureSecrets,
            StepParams::DeployManifests(_) => StepKind::DeployManifests,
            StepParams::WaitForResources(_) => StepKind::WaitForResources,
            StepParams::SyncKubeconfig(_) => StepKind::SyncKubeconfig,
            StepParams::Pivot(_) => StepKind::Pivot,
            StepParams::PublishImages(_) => StepKind::PublishImages,
            StepParams::PublishManifests(_) => StepKind::PublishManifests,
            StepParams::ApplyRootApplication(_) => StepKind::ApplyRootApplication,
            StepParams::BootstrapForgejoRepos(_) => StepKind::BootstrapForgejoRepos,
            StepParams::BootstrapArgocdKubectlSsa(_) => StepKind::BootstrapArgocdKubectlSsa,
            StepParams::BootstrapArgocdHelm(_) => StepKind::BootstrapArgocdHelm,
            StepParams::VerifyArgocdReachable(_) => StepKind::VerifyArgocdReachable,
            StepParams::RunScript(_) => StepKind::RunScript,
            StepParams::DestroyCluster(_) => StepKind::DestroyCluster,
            StepParams::ReconcileManagedResource(_) => StepKind::ReconcileManagedResource,
            StepParams::DeleteManagedResource(_) => StepKind::DeleteManagedResource,
            StepParams::WaitForClusterGone(_) => StepKind::WaitForClusterGone,
            StepParams::ReleaseClusterCloudResources(_) => StepKind::ReleaseClusterCloudResources,
            StepParams::RemoveNetwork(_) => StepKind::RemoveNetwork,
            StepParams::RemoveServices(_) => StepKind::RemoveServices,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn planned(kind: &str, params: serde_json::Value, policy: serde_json::Value) -> PlannedStep {
        serde_json::from_value(serde_json::json!({
            "name": "a-step",
            "origin": "lab.steps.a-step",
            "description": "does a thing",
            "kind": kind,
            "policy": policy,
            "params": params,
        }))
        .expect("fixture parses")
    }

    fn idempotent(kind: &str, params: serde_json::Value) -> PlannedStep {
        planned(kind, params, serde_json::json!({ "retry": "idempotent" }))
    }

    #[test]
    fn parses_a_step_with_no_params() {
        let step = idempotent("setup-services", serde_json::json!({}));
        assert_eq!(step.type_tag(), "setup-services");
        assert_eq!(step.label(), "does a thing");
    }

    #[test]
    fn a_step_with_no_description_labels_itself_by_name() {
        let step: PlannedStep = serde_json::from_value(serde_json::json!({
            "name": "publish",
            "kind": "publish-manifests",
            "policy": { "retry": "idempotent" },
        }))
        .unwrap();
        assert_eq!(step.label(), "publish");
    }

    #[test]
    fn policy_defaults_to_fatal_and_non_interactive() {
        let step = idempotent(
            "run-script",
            serde_json::json!({ "bin": "/nix/store/x/bin/hook" }),
        );
        assert!(!step.continues_on_failure());
        assert!(!step.policy.interactive);
        assert_eq!(step.policy.skip_if_cluster_reachable, None);
    }

    #[test]
    fn policy_carries_continue_and_skip_across_the_wire() {
        let step = planned(
            "run-script",
            serde_json::json!({ "bin": "/nix/store/x/bin/logout" }),
            serde_json::json!({
                "retry": "idempotent",
                "onFailure": "continue",
                "skipIfClusterReachable": "mgmt",
            }),
        );
        assert!(step.continues_on_failure());
        assert_eq!(
            step.policy.skip_if_cluster_reachable.as_deref(),
            Some("mgmt")
        );
    }

    #[test]
    fn retry_comes_off_the_wire_rather_than_a_second_table() {
        let one_shot = planned(
            "create-cluster",
            serde_json::json!({ "name": "x", "provisioner": "k3d" }),
            serde_json::json!({ "retry": "oneShot" }),
        );
        assert_eq!(one_shot.policy.retry, Idempotency::OneShot);
        assert_eq!(one_shot.attempts(), 1);

        let destructive = planned(
            "destroy-cluster",
            serde_json::json!({ "name": "x", "provisioner": "k3d" }),
            serde_json::json!({ "retry": "destructive" }),
        );
        assert_eq!(destructive.policy.retry, Idempotency::Destructive);
    }

    #[test]
    fn an_interactive_step_is_idempotent_but_not_auto_retried() {
        let step = planned(
            "run-script",
            serde_json::json!({ "bin": "/bin/join" }),
            serde_json::json!({ "retry": "idempotent", "interactive": true }),
        );
        assert_eq!(step.policy.retry, Idempotency::Idempotent);
        assert_eq!(step.attempts(), 1);
    }

    #[test]
    fn an_idempotent_step_is_retried() {
        let step = idempotent("publish-manifests", serde_json::json!({}));
        assert_eq!(step.attempts(), 3);
    }

    #[test]
    fn parses_deploy_manifests_with_bootstrap_flag() {
        let step = idempotent(
            "deploy-manifests",
            serde_json::json!({ "target": "core", "bootstrap": true }),
        );
        match step.params {
            StepParams::DeployManifests(ref p) => {
                assert_eq!(p.target, "core");
                assert!(p.bootstrap);
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn the_wire_format_did_not_change_when_the_variants_became_newtypes() {
        // camelCase on the wire, snake_case in Rust, and defaults for the
        // fields a plan omits. Any kind with a mix of both would do; this one
        // is here because it has required and optional fields together.
        let step = idempotent(
            "wait-for-resources",
            serde_json::json!({
                "target": "core",
                "waitTimeoutSeconds": 120,
                "kubeContext": "k3d-core",
            }),
        );
        match step.params {
            StepParams::WaitForResources(ref p) => {
                assert_eq!(p.target, "core");
                assert_eq!(p.wait_timeout_seconds, Some(120));
                assert_eq!(p.kube_context.as_deref(), Some("k3d-core"));
                assert!(p.resources.is_empty(), "an omitted list defaults empty");
            }
            _ => panic!("wrong variant"),
        }
    }
}
