use serde::Deserialize;

use super::step_kind::StepKind;
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

    pub fn runs_in(&self, direction: &str) -> bool {
        self.kind().runs_in(direction)
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
    SetupServices {},

    #[serde(rename_all = "camelCase")]
    DockerNetworkCreate {
        name: String,
        subnet: String,
        gateway: String,
    },

    #[serde(rename_all = "camelCase")]
    CertGenerate {
        zone: String,
    },

    TrustBundle {},

    HostTrustInstall {},

    #[serde(rename_all = "camelCase")]
    DnsSetup {
        host: String,
        port: u64,
        zone: String,
    },

    #[serde(rename_all = "camelCase")]
    DnsTeardown {
        zone: String,
    },

    #[serde(rename_all = "camelCase")]
    ColimaNetworkRoute {
        subnet: String,
        profile: String,
    },

    #[serde(rename_all = "camelCase")]
    RegistrySetup {
        port: u64,
        #[serde(default)]
        upstreams: Vec<String>,
        zone: String,
    },

    WarmCache {},

    #[serde(rename_all = "camelCase")]
    CreateCluster {
        name: String,
        provisioner: String,
    },

    EnsureSecrets {
        #[serde(default)]
        stores: Vec<String>,
    },

    #[serde(rename_all = "camelCase")]
    DeployManifests {
        target: String,
        #[serde(default)]
        bootstrap: bool,
        #[serde(default)]
        kube_context: Option<String>,
    },

    #[serde(rename_all = "camelCase")]
    CrossClusterSecretCopy {
        name: String,
        source_cluster: String,
        source_namespace: String,
        source_secret: String,
        target_cluster: String,
        target_namespace: String,
        target_secret: String,
        #[serde(default)]
        secret_type: Option<String>,
        #[serde(default)]
        source_context: Option<String>,
        #[serde(default)]
        target_context: Option<String>,
    },

    #[serde(rename_all = "camelCase")]
    WaitForResources {
        target: String,
        #[serde(default)]
        resources: Vec<Value>,
        #[serde(default)]
        wait_timeout_seconds: Option<u64>,
        #[serde(default)]
        kube_context: Option<String>,
    },

    #[serde(rename_all = "camelCase")]
    SyncKubeconfig {
        target: String,
        #[serde(default)]
        clusters: Vec<String>,
        #[serde(default)]
        kube_context: Option<String>,
    },

    #[serde(rename_all = "camelCase")]
    Pivot {
        cluster: String,
        bootstrap_context: String,
        target_context: String,
        provisioner: String,
    },

    #[serde(rename_all = "camelCase")]
    PublishImages {
        source_cluster: String,
        #[serde(default)]
        images: Vec<Value>,
    },

    PublishManifests {},

    #[serde(rename_all = "camelCase")]
    ApplyRootApplication {
        target: String,
        #[serde(default)]
        namespace: Option<String>,
        #[serde(default)]
        manifest_path: Option<String>,
        #[serde(default)]
        kube_context: Option<String>,
    },

    #[serde(rename_all = "camelCase")]
    BootstrapForgejoRepos {
        target: String,
        #[serde(default)]
        namespace: Option<String>,
        #[serde(default)]
        job_label_selector: Option<String>,
        #[serde(default)]
        kube_context: Option<String>,
    },

    #[serde(rename_all = "camelCase")]
    BootstrapArgocdKubectlSsa {
        target: String,
        manifest_root: String,
        #[serde(default)]
        kube_context: Option<String>,
        #[serde(default)]
        field_manager: Option<String>,
        #[serde(default)]
        namespace: Option<String>,
        #[serde(default)]
        wait_timeout_seconds: Option<u64>,
    },

    #[serde(rename_all = "camelCase")]
    BootstrapArgocdHelm {
        target: String,
        values_path: String,
        chart_ref: String,
        release_name: String,
        #[serde(default)]
        kube_context: Option<String>,
        #[serde(default)]
        namespace: Option<String>,
        #[serde(default)]
        wait_timeout_seconds: Option<u64>,
    },

    #[serde(rename_all = "camelCase")]
    VerifyArgocdReachable {
        target: String,
        #[serde(default)]
        kube_context: Option<String>,
        #[serde(default)]
        namespace: Option<String>,
    },

    #[serde(rename_all = "camelCase")]
    RunScript {
        bin: String,
        #[serde(default)]
        env: Vec<ScriptEnv>,
        #[serde(default)]
        kube_context: Option<String>,
    },

    #[serde(rename_all = "camelCase")]
    DestroyCluster {
        name: String,
        provisioner: String,
        #[serde(default)]
        skip_if_missing: Option<bool>,
    },

    #[serde(rename_all = "camelCase")]
    DeleteManagedResource {
        target: String,
        resource_kind: String,
        resource_name: String,
        #[serde(default)]
        wait: Option<bool>,
        #[serde(default)]
        wait_timeout_seconds: Option<u64>,
        #[serde(default)]
        kube_context: Option<String>,
        #[serde(default)]
        external_name_discovery_bin: Option<String>,
    },

    #[serde(rename_all = "camelCase")]
    WaitForClusterGone {
        #[serde(default)]
        target: Option<String>,
        #[serde(default)]
        kube_context: Option<String>,
        #[serde(default)]
        resource_kind: Option<String>,
        #[serde(default)]
        resource_name: Option<String>,
        #[serde(default)]
        wait_timeout_seconds: Option<u64>,
    },

    #[serde(rename_all = "camelCase")]
    ReleaseClusterCloudResources {
        target: String,
        #[serde(default)]
        kube_context: Option<String>,
        #[serde(default)]
        wait_timeout_seconds: Option<u64>,
    },

    RemoveNetwork {},

    RemoveServices {},
}

impl StepParams {
    pub fn cluster_refs(&self) -> Vec<(&'static str, &str)> {
        match self {
            StepParams::CreateCluster { name, .. } => vec![("name", name)],
            StepParams::DeployManifests { target, .. } => vec![("target", target)],
            StepParams::CrossClusterSecretCopy {
                source_cluster,
                target_cluster,
                ..
            } => vec![
                ("sourceCluster", source_cluster),
                ("targetCluster", target_cluster),
            ],
            StepParams::WaitForResources { target, .. } => vec![("target", target)],
            StepParams::SyncKubeconfig { target, .. } => vec![("target", target)],
            StepParams::Pivot { cluster, .. } => vec![("cluster", cluster)],
            StepParams::PublishImages { source_cluster, .. } => {
                vec![("sourceCluster", source_cluster)]
            }
            StepParams::ApplyRootApplication { target, .. } => vec![("target", target)],
            StepParams::BootstrapForgejoRepos { target, .. } => vec![("target", target)],
            StepParams::DestroyCluster { name, .. } => vec![("name", name)],
            StepParams::DeleteManagedResource { target, .. } => vec![("target", target)],
            StepParams::WaitForClusterGone { target, .. } => target
                .as_deref()
                .map(|t| vec![("target", t)])
                .unwrap_or_default(),
            StepParams::ReleaseClusterCloudResources { target, .. } => vec![("target", target)],
            StepParams::BootstrapArgocdKubectlSsa { target, .. } => vec![("target", target)],
            StepParams::BootstrapArgocdHelm { target, .. } => vec![("target", target)],
            StepParams::VerifyArgocdReachable { target, .. } => vec![("target", target)],

            StepParams::SetupServices { .. }
            | StepParams::DockerNetworkCreate { .. }
            | StepParams::CertGenerate { .. }
            | StepParams::TrustBundle { .. }
            | StepParams::HostTrustInstall { .. }
            | StepParams::DnsSetup { .. }
            | StepParams::DnsTeardown { .. }
            | StepParams::ColimaNetworkRoute { .. }
            | StepParams::RegistrySetup { .. }
            | StepParams::WarmCache { .. }
            | StepParams::EnsureSecrets { .. }
            | StepParams::PublishManifests { .. }
            | StepParams::RunScript { .. }
            | StepParams::RemoveNetwork { .. }
            | StepParams::RemoveServices { .. } => Vec::new(),
        }
    }

    pub fn kind(&self) -> StepKind {
        match self {
            StepParams::SetupServices { .. } => StepKind::SetupServices,
            StepParams::DockerNetworkCreate { .. } => StepKind::DockerNetworkCreate,
            StepParams::CertGenerate { .. } => StepKind::CertGenerate,
            StepParams::TrustBundle { .. } => StepKind::TrustBundle,
            StepParams::HostTrustInstall { .. } => StepKind::HostTrustInstall,
            StepParams::DnsSetup { .. } => StepKind::DnsSetup,
            StepParams::DnsTeardown { .. } => StepKind::DnsTeardown,
            StepParams::ColimaNetworkRoute { .. } => StepKind::ColimaNetworkRoute,
            StepParams::RegistrySetup { .. } => StepKind::RegistrySetup,
            StepParams::WarmCache { .. } => StepKind::WarmCache,
            StepParams::CreateCluster { .. } => StepKind::CreateCluster,
            StepParams::EnsureSecrets { .. } => StepKind::EnsureSecrets,
            StepParams::DeployManifests { .. } => StepKind::DeployManifests,
            StepParams::CrossClusterSecretCopy { .. } => StepKind::CrossClusterSecretCopy,
            StepParams::WaitForResources { .. } => StepKind::WaitForResources,
            StepParams::SyncKubeconfig { .. } => StepKind::SyncKubeconfig,
            StepParams::Pivot { .. } => StepKind::Pivot,
            StepParams::PublishImages { .. } => StepKind::PublishImages,
            StepParams::PublishManifests { .. } => StepKind::PublishManifests,
            StepParams::ApplyRootApplication { .. } => StepKind::ApplyRootApplication,
            StepParams::BootstrapForgejoRepos { .. } => StepKind::BootstrapForgejoRepos,
            StepParams::BootstrapArgocdKubectlSsa { .. } => StepKind::BootstrapArgocdKubectlSsa,
            StepParams::BootstrapArgocdHelm { .. } => StepKind::BootstrapArgocdHelm,
            StepParams::VerifyArgocdReachable { .. } => StepKind::VerifyArgocdReachable,
            StepParams::RunScript { .. } => StepKind::RunScript,
            StepParams::DestroyCluster { .. } => StepKind::DestroyCluster,
            StepParams::DeleteManagedResource { .. } => StepKind::DeleteManagedResource,
            StepParams::WaitForClusterGone { .. } => StepKind::WaitForClusterGone,
            StepParams::ReleaseClusterCloudResources { .. } => {
                StepKind::ReleaseClusterCloudResources
            }
            StepParams::RemoveNetwork { .. } => StepKind::RemoveNetwork,
            StepParams::RemoveServices { .. } => StepKind::RemoveServices,
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
            StepParams::DeployManifests {
                ref target,
                bootstrap,
                ..
            } => {
                assert_eq!(target, "core");
                assert!(bootstrap);
            }
            _ => panic!("wrong variant"),
        }
    }
}
