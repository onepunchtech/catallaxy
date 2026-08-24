//! The kubectl a plan step runs, behind a trait it can be handed.
//!
//! Plan steps used to call `io::kubectl::*` free functions directly, which
//! made every one of them untestable without a cluster: 23 of 32 had no tests
//! at all. The two that did — wait-for-cluster-gone and
//! release-cluster-cloud-resources — got them by factoring the decision out
//! into a pure `classify(...)` and leaving the I/O behind, which works but
//! leaves the wiring between them unverified.
//!
//! The surface is deliberately small: the primitives a step actually runs,
//! plus default methods for the shapes it reads back. The defaults are where
//! the value is, because a test drives the real parsing against fake bytes.
//! Composites that contain their own polling and decisions
//! (`wait_managed_ready`, `strip_finalizers_in_terminating_namespaces`) are
//! not here: mocking one would assert that a step believes the mock, which
//! tests nothing.

use super::run;

/// One kubectl invocation and what came back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KubectlRun {
    pub status_ok: bool,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl KubectlRun {
    pub fn ok(stdout: impl Into<Vec<u8>>) -> Self {
        KubectlRun {
            status_ok: true,
            stdout: stdout.into(),
            stderr: Vec::new(),
        }
    }

    pub fn failed(stderr: impl Into<Vec<u8>>) -> Self {
        KubectlRun {
            status_ok: false,
            stdout: Vec::new(),
            stderr: stderr.into(),
        }
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).to_string()
    }
}

/// Object-safe on purpose: `StepContext` holds `&dyn Kubectl`, so the 32 step
/// modules keep their signatures and migrate one at a time.
pub trait Kubectl {
    /// # Errors
    ///
    /// If the context is empty or kubectl cannot be spawned. A non-zero exit
    /// is `Ok` with `status_ok` false, so a caller distinguishes "kubectl said
    /// no" from "kubectl never ran".
    fn run(&self, context: &str, args: &[&str]) -> std::io::Result<KubectlRun>;

    /// stdout and stderr inherited, for the calls whose progress the operator
    /// is meant to watch. Capturing those would swallow kubectl's own
    /// reporting.
    ///
    /// # Errors
    ///
    /// If the context is empty or kubectl cannot be spawned. A non-zero exit
    /// is `Ok(false)`.
    fn run_streaming(&self, context: &str, args: &[&str]) -> std::io::Result<bool>;

    /// Every context name in the kubeconfig this seam reads.
    ///
    /// # Errors
    ///
    /// If kubectl cannot be spawned or cannot read the kubeconfig. An empty
    /// list means the file was read and holds no contexts.
    fn contexts(&self) -> std::io::Result<Vec<String>>;

    fn api_reachable(&self, context: &str) -> bool {
        matches!(
            self.run(context, &["version", "--request-timeout=2s"]),
            Ok(r) if r.status_ok
        )
    }

    fn context_in_kubeconfig(&self, context: &str) -> bool {
        matches!(self.contexts(), Ok(cs) if cs.iter().any(|c| c == context))
    }

    /// stdout of a kubectl that ran and succeeded, or None. A failure and an
    /// empty result are different answers.
    fn stdout_of(&self, context: &str, args: &[&str]) -> Option<String> {
        let out = self.run(context, args).ok()?;
        out.status_ok.then(|| out.text())
    }

    fn count_lines(&self, context: &str, args: &[&str]) -> Option<usize> {
        Some(
            self.stdout_of(context, args)?
                .lines()
                .filter(|l| !l.trim().is_empty())
                .count(),
        )
    }

    fn namespace_names(&self, context: &str) -> Option<Vec<String>> {
        Some(
            self.stdout_of(
                context,
                &["get", "ns", "-o", "jsonpath={.items[*].metadata.name}"],
            )?
            .split_whitespace()
            .map(String::from)
            .collect(),
        )
    }

    fn resource_json(&self, context: &str, resource: &str) -> Option<serde_json::Value> {
        serde_json::from_str(&self.stdout_of(context, &["get", resource, "-o", "json"])?).ok()
    }
}

/// The kubectl on PATH.
pub struct Real;

impl Kubectl for Real {
    fn run(&self, context: &str, args: &[&str]) -> std::io::Result<KubectlRun> {
        let out = run::output(context, args)?;
        Ok(KubectlRun {
            status_ok: out.status.success(),
            stdout: out.stdout,
            stderr: out.stderr,
        })
    }

    fn run_streaming(&self, context: &str, args: &[&str]) -> std::io::Result<bool> {
        Ok(run::status(context, args)?.success())
    }

    fn contexts(&self) -> std::io::Result<Vec<String>> {
        let out = run::command()
            .args(["config", "get-contexts", "-o", "name"])
            .output()?;
        if !out.status.success() {
            return Err(std::io::Error::other("kubectl could not list contexts"));
        }
        Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(String::from)
            .collect())
    }
}

#[cfg(test)]
pub mod fake {
    use super::*;
    use std::cell::RefCell;

    /// A kubectl that answers from a table instead of a cluster.
    pub struct FakeKubectl {
        responses: Vec<(Vec<String>, KubectlRun)>,
        default: Option<KubectlRun>,
        contexts: Vec<String>,
        pub calls: RefCell<Vec<(String, Vec<String>)>>,
    }

    impl Default for FakeKubectl {
        fn default() -> Self {
            Self::new()
        }
    }

    impl FakeKubectl {
        pub fn new() -> Self {
            FakeKubectl {
                responses: Vec::new(),
                default: None,
                contexts: Vec::new(),
                calls: RefCell::new(Vec::new()),
            }
        }

        /// Answer `run` when the arguments start with `prefix`.
        pub fn on(mut self, prefix: &[&str], response: KubectlRun) -> Self {
            self.responses
                .push((prefix.iter().map(|s| s.to_string()).collect(), response));
            self
        }

        pub fn otherwise(mut self, response: KubectlRun) -> Self {
            self.default = Some(response);
            self
        }

        pub fn with_contexts(mut self, contexts: &[&str]) -> Self {
            self.contexts = contexts.iter().map(|s| s.to_string()).collect();
            self
        }

        pub fn ran(&self, prefix: &[&str]) -> bool {
            self.calls
                .borrow()
                .iter()
                .any(|(_, args)| args.len() >= prefix.len() && args[..prefix.len()] == *prefix)
        }
    }

    impl Kubectl for FakeKubectl {
        fn run(&self, context: &str, args: &[&str]) -> std::io::Result<KubectlRun> {
            assert!(
                !context.trim().is_empty(),
                "kubectl was given an empty --context, which silently targets the \
                 operator's current cluster instead of the lab's"
            );
            let owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();
            self.calls
                .borrow_mut()
                .push((context.to_string(), owned.clone()));

            for (prefix, response) in &self.responses {
                if owned.len() >= prefix.len() && owned[..prefix.len()] == prefix[..] {
                    return Ok(response.clone());
                }
            }
            self.default.clone().ok_or_else(|| {
                std::io::Error::other(format!("FakeKubectl has no answer for {owned:?}"))
            })
        }

        fn run_streaming(&self, context: &str, args: &[&str]) -> std::io::Result<bool> {
            Ok(self.run(context, args)?.status_ok)
        }

        fn contexts(&self) -> std::io::Result<Vec<String>> {
            Ok(self.contexts.clone())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::FakeKubectl;
    use super::*;

    #[test]
    fn an_empty_context_trips_the_fake_rather_than_being_answered() {
        let k = FakeKubectl::new().otherwise(KubectlRun::ok(""));
        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = k.run("", &["get", "ns"]);
        }));
        assert!(
            panicked.is_err(),
            "every migrated step is protected from the empty-context bug by this"
        );
    }

    #[test]
    fn a_failing_kubectl_is_not_an_empty_result() {
        let k = FakeKubectl::new().otherwise(KubectlRun::failed("boom"));
        assert_eq!(k.stdout_of("app", &["get", "ns"]), None);
        assert_eq!(k.count_lines("app", &["get", "ns"]), None);
        assert_eq!(k.namespace_names("app"), None);
    }

    #[test]
    fn an_empty_result_is_not_a_failure() {
        let k = FakeKubectl::new().otherwise(KubectlRun::ok(""));
        assert_eq!(k.stdout_of("app", &["get", "ns"]), Some(String::new()));
        assert_eq!(k.count_lines("app", &["get", "ns"]), Some(0));
        assert_eq!(k.namespace_names("app"), Some(Vec::new()));
    }

    #[test]
    fn namespaces_come_back_split_on_whitespace() {
        let k = FakeKubectl::new().otherwise(KubectlRun::ok("default kube-system harbor"));
        assert_eq!(
            k.namespace_names("app"),
            Some(vec![
                "default".to_string(),
                "kube-system".to_string(),
                "harbor".to_string()
            ])
        );
    }

    #[test]
    fn blank_lines_do_not_count_as_resources() {
        let k = FakeKubectl::new().otherwise(KubectlRun::ok("a\n\n  \nb\n"));
        assert_eq!(k.count_lines("app", &["get", "pvc"]), Some(2));
    }

    #[test]
    fn a_cluster_that_answers_is_reachable_and_one_that_errors_is_not() {
        let up = FakeKubectl::new().otherwise(KubectlRun::ok("v1.31.0"));
        let down = FakeKubectl::new().otherwise(KubectlRun::failed("connection refused"));
        assert!(up.api_reachable("app"));
        assert!(!down.api_reachable("app"));
    }

    #[test]
    fn kubeconfig_membership_reads_the_context_list() {
        let k = FakeKubectl::new().with_contexts(&["k3d-app", "k3d-obs"]);
        assert!(k.context_in_kubeconfig("k3d-app"));
        assert!(!k.context_in_kubeconfig("k3d-gone"));
    }

    #[test]
    fn unparseable_json_is_no_resource_rather_than_a_panic() {
        let k = FakeKubectl::new().otherwise(KubectlRun::ok("not json"));
        assert!(k.resource_json("app", "ns/default").is_none());
    }

    #[test]
    fn the_first_matching_prefix_wins() {
        let k = FakeKubectl::new()
            .on(&["get", "ns"], KubectlRun::ok("namespaces"))
            .otherwise(KubectlRun::ok("anything else"));
        assert_eq!(k.stdout_of("app", &["get", "ns"]).unwrap(), "namespaces");
        assert_eq!(
            k.stdout_of("app", &["get", "pvc"]).unwrap(),
            "anything else"
        );
    }
}
