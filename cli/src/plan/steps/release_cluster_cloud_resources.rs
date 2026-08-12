use std::collections::HashSet;
use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::Result;
use console::style;

use crate::io;
use crate::plan::StepContext;

const FINALIZER_STRIP_GRACE_SECS: u64 = 60;
const PROGRESS_REPORT_SECS: u64 = 30;
const POLL_INTERVAL_SECS: u64 = 10;

const DIAGNOSTIC_DUMP_GRACE_SECS: u64 = 45;

pub fn run(
    sctx: &StepContext<'_>,
    target: &str,
    kube_context: Option<&str>,
    timeout_secs: u64,
) -> Result<()> {
    let kube_ctx = kube_context
        .map(String::from)
        .unwrap_or_else(|| target.to_string());

    if !io::kubectl::api_reachable(&kube_ctx) {
        report_unreachable(sctx, &kube_ctx);
        return Ok(());
    }

    delete_load_balancer_services(&kube_ctx);
    let target_namespaces = delete_user_namespaces(&kube_ctx);

    if !poll_until_released(&kube_ctx, &target_namespaces, timeout_secs) {
        println!(
            "{} Timed out releasing cloud resources on '{}'; cloud resources may orphan",
            style("Warning:").yellow(),
            kube_ctx
        );
        println!(
            "{} Check for stuck namespace finalizers with:  kubectl --context {} get ns",
            style(">>>").yellow(),
            kube_ctx
        );
        sctx.failures
            .borrow_mut()
            .push(format!("release-cluster-cloud-resources {kube_ctx}"));
    }
    Ok(())
}

fn report_unreachable(sctx: &StepContext<'_>, kube_ctx: &str) {
    let ctx_in_kubeconfig = Command::new("kubectl")
        .args(["config", "get-contexts", "-o", "name", kube_ctx])
        .output()
        .ok()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if ctx_in_kubeconfig {
        println!(
            "{} '{}' unreachable; assuming already gone",
            style(">>>").green(),
            kube_ctx
        );
        return;
    }
    println!(
        "{} '{}' is not in kubeconfig, skipping cloud-resource release.\n\
         {} If clusters were renamed or the operator's kubeconfig was cleaned\n\
         {} before an earlier destroy completed, cloud LBs / Volumes may still\n\
         {} be paid-for. Verify with your cloud provider's own console/CLI.",
        style("Warning:").yellow(),
        kube_ctx,
        style(">>>").yellow(),
        style(">>>").yellow(),
        style(">>>").yellow(),
    );
    sctx.failures.borrow_mut().push(format!(
        "release-cluster-cloud-resources {kube_ctx}: context missing from kubeconfig"
    ));
}

fn delete_load_balancer_services(kube_ctx: &str) {
    println!(
        "{} Deleting LoadBalancer Services on '{}' (triggers CCM release)...",
        style(">>>").cyan(),
        kube_ctx,
    );
    let _ = Command::new("kubectl")
        .args([
            "--context",
            kube_ctx,
            "delete",
            "svc",
            "-A",
            "--field-selector",
            "spec.type=LoadBalancer",
            "--ignore-not-found",
            "--wait=false",
        ])
        .status();
}

fn delete_user_namespaces(kube_ctx: &str) -> Vec<String> {
    let target_namespaces: Vec<String> = list_namespaces(kube_ctx)
        .into_iter()
        .filter(|n| {
            !n.ends_with("-system")
                && n != "kube-public"
                && n != "kube-node-lease"
                && n != "default"
        })
        .collect();
    if target_namespaces.is_empty() {
        println!(
            "{} No user namespaces to release on '{}'",
            style(">>>").green(),
            kube_ctx,
        );
        return target_namespaces;
    }
    println!(
        "{} Deleting {} user namespace(s) on '{}' (K8s cascade releases PVCs → CSI releases cloud volumes)...",
        style(">>>").cyan(),
        target_namespaces.len(),
        kube_ctx,
    );
    let mut args = vec![
        "--context".to_string(),
        kube_ctx.to_string(),
        "delete".to_string(),
        "ns".to_string(),
    ];
    for ns in &target_namespaces {
        args.push(ns.clone());
    }
    args.push("--wait=false".to_string());
    args.push("--ignore-not-found".to_string());
    let _ = Command::new("kubectl").args(&args).status();
    target_namespaces
}

fn poll_until_released(kube_ctx: &str, target_namespaces: &[String], timeout_secs: u64) -> bool {
    let deadline = Instant::now() + Duration::from_secs(timeout_secs);
    let mut last_report = Instant::now();
    let mut stuck_since: Option<Instant> = None;
    let mut finalizer_strip_done = false;
    let mut stall_since: Option<Instant> = None;
    let mut last_counts: Option<(usize, usize, usize)> = None;
    let mut diagnostic_dumped = false;
    let target_ns_set: HashSet<&str> = target_namespaces.iter().map(|s| s.as_str()).collect();

    while Instant::now() < deadline {
        let remaining_ns: Vec<String> = list_namespaces(kube_ctx)
            .into_iter()
            .filter(|n| target_ns_set.contains(n.as_str()))
            .collect();
        let lb_count = count_kubectl(
            kube_ctx,
            &[
                "get",
                "svc",
                "-A",
                "--field-selector",
                "spec.type=LoadBalancer",
                "--no-headers",
            ],
        );
        let pvc_count = count_kubectl(kube_ctx, &["get", "pvc", "-A", "--no-headers"]);

        if remaining_ns.is_empty() && lb_count == 0 && pvc_count == 0 {
            println!(
                "{} Cloud resources released on '{}' (all target namespaces gone, no LB Services, no PVCs)",
                style(">>>").green(),
                kube_ctx,
            );
            return true;
        }

        let counts = (remaining_ns.len(), lb_count, pvc_count);
        if last_counts.map(|prev| prev != counts).unwrap_or(true) {
            stall_since = Some(Instant::now());
            diagnostic_dumped = false;
        }
        last_counts = Some(counts);

        if last_report.elapsed() >= Duration::from_secs(PROGRESS_REPORT_SECS) {
            println!(
                "{} '{}' still terminating: {} ns, {} LB Service(s), {} PVC(s)...",
                style(">>>").yellow(),
                kube_ctx,
                remaining_ns.len(),
                lb_count,
                pvc_count,
            );
            last_report = Instant::now();
        }

        if !diagnostic_dumped
            && counts != (0, 0, 0)
            && stall_since
                .map(|t| t.elapsed().as_secs() >= DIAGNOSTIC_DUMP_GRACE_SECS)
                .unwrap_or(false)
        {
            dump_stuck_state(kube_ctx, &remaining_ns);
            diagnostic_dumped = true;
        }

        if lb_count == 0 && pvc_count == 0 && !remaining_ns.is_empty() {
            let stuck = *stuck_since.get_or_insert_with(Instant::now);
            if !finalizer_strip_done && stuck.elapsed().as_secs() >= FINALIZER_STRIP_GRACE_SECS {
                println!(
                    "{} Namespace cascade stalled on finalizers ({}s); force-stripping resources in stuck ns(s) [{}]",
                    style(">>>").yellow(),
                    FINALIZER_STRIP_GRACE_SECS,
                    remaining_ns.join(", "),
                );
                crate::commands::lab::orchestrate::strip_finalizers_in_terminating_namespaces(
                    kube_ctx,
                    &remaining_ns,
                );
                finalizer_strip_done = true;
            }
        }
        std::thread::sleep(Duration::from_secs(POLL_INTERVAL_SECS));
    }
    false
}

fn dump_stuck_state(kube_ctx: &str, remaining_ns: &[String]) {
    println!(
        "{} '{}' has not made progress in {}s. Diagnostic dump:",
        style(">>>").yellow(),
        kube_ctx,
        DIAGNOSTIC_DUMP_GRACE_SECS,
    );

    for ns in remaining_ns {
        let finalizers = kubectl_output(
            kube_ctx,
            &["get", "ns", ns, "-o", "jsonpath={.spec.finalizers[*]}"],
        );
        let cond = kubectl_output(
            kube_ctx,
            &[
                "get",
                "ns",
                ns,
                "-o",
                "jsonpath={range .status.conditions[?(@.status=='True')]}{.type}={.reason},{end}",
            ],
        );
        let cond_display = if cond.trim().is_empty() {
            "(no True conditions)".to_string()
        } else {
            cond.trim_end_matches(',').to_string()
        };
        let finalizers_display = if finalizers.trim().is_empty() {
            "(none)".to_string()
        } else {
            finalizers
        };
        println!(
            "{}   ns/{}: finalizers=[{}] conditions=[{}]",
            style(">>>").yellow(),
            ns,
            finalizers_display,
            cond_display,
        );
    }

    let pvc_lines = kubectl_output(
        kube_ctx,
        &[
            "get",
            "pvc",
            "-A",
            "-o",
            "jsonpath={range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.volumeName}|{.metadata.finalizers[*]}{'\\n'}{end}",
        ],
    );
    for line in pvc_lines.lines().filter(|l| !l.trim().is_empty()) {
        let parts: Vec<&str> = line.splitn(4, '|').collect();
        if parts.len() < 4 {
            continue;
        }
        let (ns, name, pv, finalizers) = (parts[0], parts[1], parts[2], parts[3]);
        let pv_status = if pv.is_empty() {
            "(unbound)".to_string()
        } else {
            kubectl_output(
                kube_ctx,
                &[
                    "get",
                    "pv",
                    pv,
                    "-o",
                    "jsonpath={.status.phase} reclaim={.spec.persistentVolumeReclaimPolicy}",
                ],
            )
        };
        let finalizers_display = if finalizers.trim().is_empty() {
            "(none)".to_string()
        } else {
            finalizers.to_string()
        };
        println!(
            "{}   pvc/{}/{}: pv={} [{}] finalizers=[{}]",
            style(">>>").yellow(),
            ns,
            name,
            if pv.is_empty() { "-" } else { pv },
            pv_status,
            finalizers_display,
        );
    }

    println!(
        "{}   (informational only, waiting up to {}s before force-stripping ns finalizers)",
        style(">>>").yellow(),
        FINALIZER_STRIP_GRACE_SECS,
    );
}

fn kubectl_output(kube_ctx: &str, args: &[&str]) -> String {
    let mut full_args = vec!["--context", kube_ctx];
    full_args.extend_from_slice(args);
    Command::new("kubectl")
        .args(&full_args)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default()
}

fn list_namespaces(kube_ctx: &str) -> Vec<String> {
    Command::new("kubectl")
        .args([
            "--context",
            kube_ctx,
            "get",
            "ns",
            "-o",
            "jsonpath={.items[*].metadata.name}",
        ])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default()
        .split_whitespace()
        .map(String::from)
        .collect()
}

fn count_kubectl(kube_ctx: &str, args: &[&str]) -> usize {
    let mut full_args = vec!["--context", kube_ctx];
    full_args.extend_from_slice(args);
    Command::new("kubectl")
        .args(&full_args)
        .output()
        .ok()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| !l.is_empty())
                .count()
        })
        .unwrap_or(usize::MAX)
}
