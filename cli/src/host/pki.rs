use std::process::Command;

use anyhow::Result;
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::io::process::run_capture;

pub fn import_lab_ca(
    ctx: &CataContext,
    lab_name: &str,
    lab: &LabSpec,
    cluster_name: &str,
) -> Result<()> {
    let ingress_dir = crate::host::state::service_state_dir(lab_name, "proxy");
    let ca_crt = ingress_dir.join("ca.crt");
    let ca_key = ingress_dir.join("ca.key");

    if !ca_crt.exists() || !ca_key.exists() {
        return Ok(());
    }

    let context = lab.kube_context(cluster_name)?;

    let mut namespace = Command::new("kubectl");
    namespace.args(["--context", context, "create", "namespace", "cert-manager"]);
    let _ = run_capture(&mut namespace, ctx);

    let mut delete = Command::new("kubectl");
    delete.args([
        "--context",
        context,
        "delete",
        "secret",
        "lab-ca-ca-secret",
        "-n",
        "cert-manager",
    ]);
    let _ = run_capture(&mut delete, ctx);

    let mut create = Command::new("kubectl");
    create
        .args([
            "--context",
            context,
            "create",
            "secret",
            "tls",
            "lab-ca-ca-secret",
            "-n",
            "cert-manager",
            "--cert",
        ])
        .arg(&ca_crt)
        .args(["--key"])
        .arg(&ca_key);

    match run_capture(&mut create, ctx) {
        Ok(_) => {
            println!(
                "{} Lab CA imported into '{cluster_name}'",
                style(">>>").green()
            );
        }
        Err(_) => {
            println!(
                "{} Failed to import CA into '{cluster_name}'",
                style(">>>").yellow()
            );
        }
    }

    Ok(())
}
