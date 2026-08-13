use anyhow::Result;

use crate::domain::plan::CreateClusterParams;
use crate::host::state;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>, p: &CreateClusterParams) -> Result<()> {
    let CreateClusterParams {
        name,
        provisioner: _,
    } = p;

    let spec = sctx.lab.cluster(name)?;

    let registry_dir = state::service_state_dir(sctx.lab_name, "registry");
    let registries_yaml = registry_dir.join("registries.yaml");
    let registries_yaml = registries_yaml.exists().then_some(registries_yaml);

    crate::provision::provision_cluster_with_registry(
        sctx.ctx,
        name,
        spec,
        registries_yaml.as_deref(),
        Some(sctx.lab_package),
    )?;

    if sctx.lab.services.contains_key("proxy") {
        crate::host::pki::import_lab_ca(sctx.lab_name, sctx.lab, name)?;
    }

    Ok(())
}
