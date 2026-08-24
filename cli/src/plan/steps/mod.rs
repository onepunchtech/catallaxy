pub mod apply_root_application;
pub mod bootstrap_argocd_helm;
pub mod bootstrap_argocd_kubectl_ssa;
pub mod bootstrap_forgejo_repos;
pub mod cert_generate;
pub mod colima_network_route;
pub mod create_cluster;
pub mod delete_managed_resource;
pub mod deploy_manifests;
pub mod destroy_cluster;
pub mod dns_setup;
pub mod dns_teardown;
pub mod docker_network_create;
pub mod ensure_secrets;
pub mod host_trust_install;
pub mod infra;
pub mod pivot;
pub mod publish_images;
pub mod publish_manifests;
pub mod reconcile_managed_resource;
pub mod registry_setup;
pub mod release_cluster_cloud_resources;
pub mod remove_network;
pub mod remove_services;
pub mod run_script;
pub mod setup_services;
pub mod sync_kubeconfig;
pub mod trust_bundle;
pub mod verify_argocd_reachable;
pub mod wait_for_cluster_gone;
pub mod wait_for_resources;
pub mod warm_cache;

/// The lab's plan carries no kube context for a cluster a step must address.
pub fn missing_kube_context(step: &str, target: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "{step}: the lab's plan resolves no kube context for cluster '{target}', \
         so there is nothing to address it by.\n\
         Run `cata lab plan` to see what the plan resolved, and check that \
         '{target}' is named in `lab.clusters` and that its provisioner \
         publishes a context."
    )
}
