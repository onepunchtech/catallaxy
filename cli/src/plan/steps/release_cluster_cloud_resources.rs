use std::collections::HashSet;
use std::time::{Duration, Instant};

use anyhow::Result;
use console::style;

use crate::config::Context as CataContext;
use crate::domain::StepFailure;
use crate::domain::plan::ReleaseClusterCloudResourcesParams;
use crate::io;
use crate::plan::StepContext;

const STEP: &str = "release-cluster-cloud-resources";

const FINALIZER_STRIP_GRACE_SECS: u64 = 60;
const PROGRESS_REPORT_SECS: u64 = 30;
const POLL_INTERVAL_SECS: u64 = 10;

const DIAGNOSTIC_DUMP_GRACE_SECS: u64 = 45;

/// What a diagnostic field reads when the query itself failed, which is not
/// the same as the field being empty.
const UNAVAILABLE: &str = "(unavailable)";

pub fn run(sctx: &StepContext<'_>, p: &ReleaseClusterCloudResourcesParams) -> Result<()> {
    let ReleaseClusterCloudResourcesParams {
        target,
        kube_context,
        wait_timeout_seconds: timeout_secs,
    } = p;
    let timeout_secs = timeout_secs.unwrap_or(600);
    let kube_context = kube_context.as_deref();

    let kube_ctx = kube_context
        .map(String::from)
        .unwrap_or_else(|| target.to_string());

    if !sctx.kubectl.api_reachable(&kube_ctx) {
        report_unreachable(sctx.kubectl, &sctx.failures, &kube_ctx);
        return Ok(());
    }

    delete_load_balancer_services(&kube_ctx);
    let Some(target_namespaces) = delete_user_namespaces(&kube_ctx) else {
        println!(
            "{} Could not list namespaces on '{}', so nothing was released.",
            style("ERROR").red(),
            kube_ctx,
        );
        sctx.failures.borrow_mut().push(StepFailure::new(
            STEP,
            format!("could not list namespaces on '{kube_ctx}', so nothing was released"),
        ));
        return Ok(());
    };

    let outcome = poll_until_released(sctx.ctx, &kube_ctx, &target_namespaces, timeout_secs);

    if !outcome.stripped_finalizers.is_empty() {
        sctx.failures.borrow_mut().push(StepFailure::new(
            STEP,
            format!(
                "force-stripped finalizers on {} resource(s) on '{kube_ctx}' ({}); \
                 their controllers never ran a release path, so cloud resources may remain",
                outcome.stripped_finalizers.len(),
                outcome.stripped_finalizers.join(", "),
            ),
        ));
    }

    if !outcome.released {
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
        sctx.failures.borrow_mut().push(StepFailure::new(
            STEP,
            format!("cloud resources on '{kube_ctx}' were never confirmed released"),
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reachability {
    Reachable,
    InKubeconfigButDown,
    NotInKubeconfig,
}

pub fn classify_reachability(in_kubeconfig: bool, api_answers: bool) -> Reachability {
    match (in_kubeconfig, api_answers) {
        (_, true) => Reachability::Reachable,
        (true, false) => Reachability::InKubeconfigButDown,
        (false, false) => Reachability::NotInKubeconfig,
    }
}

fn report_unreachable(
    kubectl: &dyn crate::io::kubectl::Kubectl,
    failures: &std::cell::RefCell<Vec<StepFailure>>,
    kube_ctx: &str,
) {
    let verdict = classify_reachability(kubectl.context_in_kubeconfig(kube_ctx), false);

    let detail = match verdict {
        Reachability::Reachable => return,
        Reachability::InKubeconfigButDown => {
            "it is configured but did not answer, so whether its cloud resources \
             were released is unknown"
        }
        Reachability::NotInKubeconfig => {
            "it is missing from kubeconfig, so nothing could be released. If \
             clusters were renamed or the kubeconfig was cleaned before an \
             earlier destroy completed, this is expected"
        }
    };

    println!(
        "{} '{}' could not be reached: {}\n\
         {} This step deletes LoadBalancer Services and PersistentVolumes that the\n\
         {} Cluster resource does not own, so the cascade delete will not collect\n\
         {} them. Cloud LBs and Volumes may still be paid-for. Verify with your\n\
         {} cloud provider's own console or CLI.",
        style("Warning:").yellow(),
        kube_ctx,
        detail,
        style(">>>").yellow(),
        style(">>>").yellow(),
        style(">>>").yellow(),
        style(">>>").yellow(),
    );

    failures.borrow_mut().push(StepFailure::new(
        STEP,
        format!("cloud resources on '{kube_ctx}' were never confirmed released ({detail})"),
    ));
}

fn delete_load_balancer_services(kube_ctx: &str) {
    println!(
        "{} Deleting LoadBalancer Services on '{}' (triggers CCM release)...",
        style(">>>").cyan(),
        kube_ctx,
    );
    let _ = io::kubectl::status(
        kube_ctx,
        &[
            "delete",
            "svc",
            "-A",
            "--field-selector",
            "spec.type=LoadBalancer",
            "--ignore-not-found",
            "--wait=false",
        ],
    );
}

fn delete_user_namespaces(kube_ctx: &str) -> Option<Vec<String>> {
    let target_namespaces: Vec<String> = io::kubectl::namespace_names(kube_ctx)?
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
        return Some(target_namespaces);
    }
    println!(
        "{} Deleting {} user namespace(s) on '{}' (K8s cascade releases PVCs → CSI releases cloud volumes)...",
        style(">>>").cyan(),
        target_namespaces.len(),
        kube_ctx,
    );
    let mut args = vec!["delete", "ns"];
    args.extend(target_namespaces.iter().map(String::as_str));
    args.push("--wait=false");
    args.push("--ignore-not-found");
    let _ = io::kubectl::status(kube_ctx, &args);
    Some(target_namespaces)
}

pub struct ReleaseOutcome {
    pub released: bool,
    pub stripped_finalizers: Vec<String>,
}

fn read_remaining(kube_ctx: &str) -> Option<(Vec<String>, usize, usize)> {
    let namespaces = io::kubectl::namespace_names(kube_ctx)?;
    let load_balancers = io::kubectl::count_lines(
        kube_ctx,
        &[
            "get",
            "svc",
            "-A",
            "--field-selector",
            "spec.type=LoadBalancer",
            "--no-headers",
        ],
    )?;
    let volume_claims = io::kubectl::count_lines(kube_ctx, &["get", "pvc", "-A", "--no-headers"])?;
    Some((namespaces, load_balancers, volume_claims))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Observation {
    pub remaining_ns: Vec<String>,
    pub load_balancers: usize,
    pub volume_claims: usize,
}

impl Observation {
    fn counts(&self) -> (usize, usize, usize) {
        (
            self.remaining_ns.len(),
            self.load_balancers,
            self.volume_claims,
        )
    }

    fn everything_gone(&self) -> bool {
        self.counts() == (0, 0, 0)
    }

    fn only_namespaces_left(&self) -> bool {
        self.load_balancers == 0 && self.volume_claims == 0 && !self.remaining_ns.is_empty()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReleaseState {
    last_report_at: u64,
    last_counts: Option<(usize, usize, usize)>,
    stall_since: Option<u64>,
    diagnostic_dumped: bool,
    stuck_since: Option<u64>,
    finalizer_strip_done: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Unreadable,
    Released,
    ReportProgress,
    DumpDiagnostics,
    StripFinalizers,
}

pub fn advance(
    state: &ReleaseState,
    observed: Option<&Observation>,
    elapsed: u64,
) -> (ReleaseState, Vec<Action>) {
    let Some(obs) = observed else {
        return (state.clone(), vec![Action::Unreadable]);
    };

    if obs.everything_gone() {
        return (state.clone(), vec![Action::Released]);
    }

    let mut next = state.clone();
    let mut actions = Vec::new();

    let counts = obs.counts();
    if next.last_counts != Some(counts) {
        next.stall_since = Some(elapsed);
        next.diagnostic_dumped = false;
    }
    next.last_counts = Some(counts);

    if elapsed.saturating_sub(next.last_report_at) >= PROGRESS_REPORT_SECS {
        actions.push(Action::ReportProgress);
        next.last_report_at = elapsed;
    }

    let stalled_for = next.stall_since.map(|t| elapsed.saturating_sub(t));
    if !next.diagnostic_dumped && stalled_for.is_some_and(|s| s >= DIAGNOSTIC_DUMP_GRACE_SECS) {
        actions.push(Action::DumpDiagnostics);
        next.diagnostic_dumped = true;
    }

    if obs.only_namespaces_left() {
        let stuck_since = *next.stuck_since.get_or_insert(elapsed);
        if !next.finalizer_strip_done
            && elapsed.saturating_sub(stuck_since) >= FINALIZER_STRIP_GRACE_SECS
        {
            actions.push(Action::StripFinalizers);
            next.finalizer_strip_done = true;
        }
    }

    (next, actions)
}

fn poll_until_released(
    _ctx: &CataContext,
    kube_ctx: &str,
    target_namespaces: &[String],
    timeout_secs: u64,
) -> ReleaseOutcome {
    let mut stripped_finalizers = Vec::new();
    let started = Instant::now();
    let deadline = started + Duration::from_secs(timeout_secs);
    let mut state = ReleaseState::default();
    let target_ns_set: HashSet<&str> = target_namespaces.iter().map(|s| s.as_str()).collect();

    while Instant::now() < deadline {
        let observed =
            read_remaining(kube_ctx).map(|(all_ns, load_balancers, volume_claims)| Observation {
                remaining_ns: all_ns
                    .into_iter()
                    .filter(|n| target_ns_set.contains(n.as_str()))
                    .collect(),
                load_balancers,
                volume_claims,
            });

        let (next, actions) = advance(&state, observed.as_ref(), started.elapsed().as_secs());
        state = next;

        for action in actions {
            match action {
                Action::Released => {
                    println!(
                        "{} Cloud resources released on '{}' (all target namespaces gone, no LB Services, no PVCs)",
                        style(">>>").green(),
                        kube_ctx,
                    );
                    return ReleaseOutcome {
                        released: true,
                        stripped_finalizers,
                    };
                }
                Action::Unreadable => println!(
                    "{} Could not read '{}' this round, so nothing is confirmed released; retrying...",
                    style(">>>").yellow(),
                    kube_ctx,
                ),
                Action::ReportProgress => {
                    let obs = observed.as_ref().expect("progress implies an observation");
                    println!(
                        "{} '{}' still terminating: {} ns, {} LB Service(s), {} PVC(s)...",
                        style(">>>").yellow(),
                        kube_ctx,
                        obs.remaining_ns.len(),
                        obs.load_balancers,
                        obs.volume_claims,
                    );
                }
                Action::DumpDiagnostics => {
                    let obs = observed.as_ref().expect("a dump implies an observation");
                    dump_stuck_state(kube_ctx, &obs.remaining_ns);
                }
                Action::StripFinalizers => {
                    let obs = observed.as_ref().expect("a strip implies an observation");
                    println!(
                        "{} Namespace cascade stalled on finalizers ({}s); force-stripping resources in stuck ns(s) [{}]",
                        style(">>>").yellow(),
                        FINALIZER_STRIP_GRACE_SECS,
                        obs.remaining_ns.join(", "),
                    );
                    stripped_finalizers.extend(
                        crate::io::kubectl::strip_finalizers_in_terminating_namespaces(
                            kube_ctx,
                            &obs.remaining_ns,
                        ),
                    );
                }
            }
        }

        std::thread::sleep(Duration::from_secs(POLL_INTERVAL_SECS));
    }
    ReleaseOutcome {
        released: false,
        stripped_finalizers,
    }
}

fn or_none(value: &str) -> String {
    if value.trim().is_empty() {
        "(none)".to_string()
    } else {
        value.to_string()
    }
}

pub fn describe_namespace(ns: &str, finalizers: &str, conditions: &str) -> String {
    let conditions = if conditions.trim().is_empty() {
        "(no True conditions)".to_string()
    } else {
        conditions.trim_end_matches(',').to_string()
    };
    format!(
        "ns/{ns}: finalizers=[{}] conditions=[{conditions}]",
        or_none(finalizers),
    )
}

#[derive(Debug, PartialEq, Eq)]
pub struct PvcLine<'a> {
    pub namespace: &'a str,
    pub name: &'a str,
    pub pv: &'a str,
    pub finalizers: &'a str,
}

pub fn parse_pvc_line(line: &str) -> Option<PvcLine<'_>> {
    if line.trim().is_empty() {
        return None;
    }
    let parts: Vec<&str> = line.splitn(4, '|').collect();
    let [namespace, name, pv, finalizers] = parts[..] else {
        return None;
    };
    Some(PvcLine {
        namespace,
        name,
        pv,
        finalizers,
    })
}

impl PvcLine<'_> {
    pub fn describe(&self, pv_status: &str) -> String {
        format!(
            "pvc/{}/{}: pv={} [{pv_status}] finalizers=[{}]",
            self.namespace,
            self.name,
            if self.pv.is_empty() { "-" } else { self.pv },
            or_none(self.finalizers),
        )
    }
}

fn dump_stuck_state(kube_ctx: &str, remaining_ns: &[String]) {
    println!(
        "{} '{}' has not made progress in {}s. Diagnostic dump:",
        style(">>>").yellow(),
        kube_ctx,
        DIAGNOSTIC_DUMP_GRACE_SECS,
    );

    for ns in remaining_ns {
        let finalizers = io::kubectl::stdout_of(
            kube_ctx,
            &["get", "ns", ns, "-o", "jsonpath={.spec.finalizers[*]}"],
        )
        .unwrap_or_else(|| UNAVAILABLE.to_string());
        let cond = io::kubectl::stdout_of(
            kube_ctx,
            &[
                "get",
                "ns",
                ns,
                "-o",
                "jsonpath={range .status.conditions[?(@.status=='True')]}{.type}={.reason},{end}",
            ],
        )
        .unwrap_or_else(|| UNAVAILABLE.to_string());
        println!(
            "{}   {}",
            style(">>>").yellow(),
            describe_namespace(ns, &finalizers, &cond),
        );
    }

    match io::kubectl::stdout_of(
        kube_ctx,
        &[
            "get",
            "pvc",
            "-A",
            "-o",
            "jsonpath={range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.volumeName}|{.metadata.finalizers[*]}{'\\n'}{end}",
        ],
    ) {
        None => println!(
            "{}   could not list PersistentVolumeClaims, so any that are stuck are not shown here",
            style(">>>").yellow()
        ),
        Some(pvc_lines) => {
            for pvc in pvc_lines.lines().filter_map(parse_pvc_line) {
                let pv_status = if pvc.pv.is_empty() {
                    "(unbound)".to_string()
                } else {
                    io::kubectl::stdout_of(
                        kube_ctx,
                        &[
                            "get",
                            "pv",
                            pvc.pv,
                            "-o",
                            "jsonpath={.status.phase} reclaim={.spec.persistentVolumeReclaimPolicy}",
                        ],
                    )
                    .unwrap_or_else(|| UNAVAILABLE.to_string())
                };
                println!("{}   {}", style(">>>").yellow(), pvc.describe(&pv_status));
            }
        }
    }

    println!(
        "{}   (informational only, waiting up to {}s before force-stripping ns finalizers)",
        style(">>>").yellow(),
        FINALIZER_STRIP_GRACE_SECS,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obs(ns: &[&str], lb: usize, pvc: usize) -> Observation {
        Observation {
            remaining_ns: ns.iter().map(|s| s.to_string()).collect(),
            load_balancers: lb,
            volume_claims: pvc,
        }
    }

    fn run_to(mut state: ReleaseState, o: &Observation, until: u64, step: u64) -> ReleaseState {
        let mut t = 0;
        while t <= until {
            let (next, _) = advance(&state, Some(o), t);
            state = next;
            t += step;
        }
        state
    }

    #[test]
    fn an_empty_cluster_is_released() {
        let (_, actions) = advance(&ReleaseState::default(), Some(&obs(&[], 0, 0)), 0);
        assert_eq!(actions, vec![Action::Released]);
    }

    #[test]
    fn a_round_it_could_not_read_is_neither_released_nor_progress() {
        let (state, actions) = advance(&ReleaseState::default(), None, 120);

        assert_eq!(actions, vec![Action::Unreadable]);
        assert_eq!(
            state,
            ReleaseState::default(),
            "an unreadable round must not advance any timer, or a blind cluster \
             would age into a finalizer strip"
        );
    }

    #[test]
    fn progress_is_reported_on_the_cadence_not_every_round() {
        let o = obs(&["app"], 1, 1);

        let (s1, a1) = advance(&ReleaseState::default(), Some(&o), 0);
        assert!(!a1.contains(&Action::ReportProgress), "{a1:?}");

        let (_, a2) = advance(&s1, Some(&o), PROGRESS_REPORT_SECS - 1);
        assert!(!a2.contains(&Action::ReportProgress), "{a2:?}");

        let (s3, a3) = advance(&s1, Some(&o), PROGRESS_REPORT_SECS);
        assert!(a3.contains(&Action::ReportProgress), "{a3:?}");

        let (_, a4) = advance(&s3, Some(&o), PROGRESS_REPORT_SECS + 1);
        assert!(!a4.contains(&Action::ReportProgress), "{a4:?}");
    }

    #[test]
    fn diagnostics_are_dumped_once_a_stall_passes_the_grace() {
        let o = obs(&["app"], 1, 1);
        let stalled = run_to(ReleaseState::default(), &o, DIAGNOSTIC_DUMP_GRACE_SECS, 5);

        assert!(
            stalled.diagnostic_dumped,
            "a stall longer than the grace should have dumped"
        );

        let (_, again) = advance(&stalled, Some(&o), DIAGNOSTIC_DUMP_GRACE_SECS * 3);
        assert!(
            !again.contains(&Action::DumpDiagnostics),
            "the dump is once per stall, not per round"
        );
    }

    #[test]
    fn progress_resets_the_stall_so_diagnostics_can_fire_again() {
        let stalled = run_to(
            ReleaseState::default(),
            &obs(&["app", "db"], 1, 1),
            DIAGNOSTIC_DUMP_GRACE_SECS,
            5,
        );
        assert!(stalled.diagnostic_dumped);

        let (moved, _) = advance(&stalled, Some(&obs(&["app"], 1, 1)), 100);
        assert!(
            !moved.diagnostic_dumped,
            "counts changed, so this is progress and the next stall is new"
        );
    }

    #[test]
    fn finalizers_are_stripped_only_when_namespaces_alone_remain() {
        let with_lb = run_to(
            ReleaseState::default(),
            &obs(&["app"], 1, 0),
            FINALIZER_STRIP_GRACE_SECS * 2,
            10,
        );
        assert!(
            !with_lb.finalizer_strip_done,
            "a LoadBalancer still present means the cascade is not stuck on finalizers"
        );

        let ns_only = run_to(
            ReleaseState::default(),
            &obs(&["app"], 0, 0),
            FINALIZER_STRIP_GRACE_SECS,
            10,
        );
        assert!(ns_only.finalizer_strip_done);
    }

    #[test]
    fn finalizers_are_stripped_at_most_once() {
        let o = obs(&["app"], 0, 0);
        let after = run_to(
            ReleaseState::default(),
            &o,
            FINALIZER_STRIP_GRACE_SECS * 4,
            10,
        );

        let (_, actions) = advance(&after, Some(&o), FINALIZER_STRIP_GRACE_SECS * 8);
        assert!(!actions.contains(&Action::StripFinalizers), "{actions:?}");
    }

    #[test]
    fn a_strip_does_not_happen_before_the_grace_elapses() {
        let o = obs(&["app"], 0, 0);
        let (s, _) = advance(&ReleaseState::default(), Some(&o), 0);
        let (_, actions) = advance(&s, Some(&o), FINALIZER_STRIP_GRACE_SECS - 1);

        assert!(!actions.contains(&Action::StripFinalizers), "{actions:?}");
    }

    #[test]
    fn a_namespace_with_nothing_holding_it_says_so_in_both_fields() {
        assert_eq!(
            describe_namespace("harbor", "", ""),
            "ns/harbor: finalizers=[(none)] conditions=[(no True conditions)]"
        );
    }

    #[test]
    fn the_trailing_comma_kubectl_emits_after_each_condition_is_dropped() {
        assert_eq!(
            describe_namespace(
                "harbor",
                "kubernetes",
                "NamespaceDeletionContentFailure=Error,"
            ),
            "ns/harbor: finalizers=[kubernetes] \
             conditions=[NamespaceDeletionContentFailure=Error]"
        );
    }

    #[test]
    fn a_pvc_line_splits_into_four_fields_keeping_pipes_inside_the_finalizer_list() {
        let pvc = parse_pvc_line("harbor|data-0|pvc-abc|kubernetes.io/pvc-protection|other")
            .expect("four fields");
        assert_eq!(pvc.namespace, "harbor");
        assert_eq!(pvc.name, "data-0");
        assert_eq!(pvc.pv, "pvc-abc");
        assert_eq!(pvc.finalizers, "kubernetes.io/pvc-protection|other");
    }

    #[test]
    fn a_blank_or_truncated_line_is_not_a_pvc() {
        assert_eq!(parse_pvc_line(""), None);
        assert_eq!(parse_pvc_line("   "), None);
        assert_eq!(parse_pvc_line("harbor|data-0|pvc-abc"), None);
    }

    #[test]
    fn an_unbound_claim_shows_a_dash_rather_than_an_empty_name() {
        let pvc = parse_pvc_line("harbor|data-0||").expect("four fields");
        assert_eq!(
            pvc.describe("(unbound)"),
            "pvc/harbor/data-0: pv=- [(unbound)] finalizers=[(none)]"
        );
    }

    #[test]
    fn a_bound_claim_reports_the_volume_and_its_phase() {
        let pvc = parse_pvc_line("harbor|data-0|pvc-abc|kubernetes.io/pvc-protection")
            .expect("four fields");
        assert_eq!(
            pvc.describe("Bound reclaim=Delete"),
            "pvc/harbor/data-0: pv=pvc-abc [Bound reclaim=Delete] \
             finalizers=[kubernetes.io/pvc-protection]"
        );
    }

    #[test]
    fn a_cluster_that_answers_is_reachable_however_kubeconfig_looks() {
        assert_eq!(classify_reachability(true, true), Reachability::Reachable);
        assert_eq!(classify_reachability(false, true), Reachability::Reachable);
    }

    #[test]
    fn a_configured_cluster_that_does_not_answer_is_not_proof_it_is_gone() {
        assert_eq!(
            classify_reachability(true, false),
            Reachability::InKubeconfigButDown
        );
    }

    #[test]
    fn a_cluster_missing_from_kubeconfig_is_its_own_verdict() {
        assert_eq!(
            classify_reachability(false, false),
            Reachability::NotInKubeconfig
        );
    }

    #[test]
    fn neither_unreachable_verdict_is_reachable() {
        for verdict in [
            classify_reachability(true, false),
            classify_reachability(false, false),
        ] {
            assert_ne!(verdict, Reachability::Reachable);
        }
    }

    // The polarity this asserts is the bug that shipped: an unreachable but
    // configured cluster was read as proof of deletion and recorded nothing,
    // so teardown exited 0 while LoadBalancers and volumes stayed paid-for.
    #[test]
    fn a_configured_but_silent_cluster_records_a_failure() {
        use crate::io::kubectl::seam::fake::FakeKubectl;

        let kubectl = FakeKubectl::new().with_contexts(&["k3d-gone"]);
        let failures = std::cell::RefCell::new(Vec::new());

        report_unreachable(&kubectl, &failures, "k3d-gone");

        let recorded = failures.borrow();
        assert_eq!(recorded.len(), 1, "an unverified release must be a failure");
        assert!(
            recorded[0].detail.contains("did not answer"),
            "{:?}",
            recorded[0]
        );
    }

    #[test]
    fn a_cluster_missing_from_kubeconfig_also_records_a_failure() {
        use crate::io::kubectl::seam::fake::FakeKubectl;

        let kubectl = FakeKubectl::new().with_contexts(&["k3d-other"]);
        let failures = std::cell::RefCell::new(Vec::new());

        report_unreachable(&kubectl, &failures, "k3d-gone");

        let recorded = failures.borrow();
        assert_eq!(recorded.len(), 1);
        assert!(
            recorded[0].detail.contains("missing from kubeconfig"),
            "{:?}",
            recorded[0]
        );
    }
}
