//! What kapp says about an app's last reconcile.
//!
//! `kapp list --json` has no typed status column. Its `description` field is
//! the same sentence kapp prints for a human, so there is no structured value
//! to read instead — unlike most of what this CLI consumes, the prose *is*
//! the interface kapp offers.
//!
//! What can be fixed is where that prose is read. It used to be read at the
//! point of display, with a chain of `contains` that asked about success
//! before failure: a description carrying both words rendered green. Reading
//! it in one place makes the precedence a decision rather than an accident,
//! puts it under test, and gives the display sites a value to match on.

/// The three things a status report can show about a kapp app.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KappStatus {
    Succeeded,
    Failed,
    /// Reconciling, or a description this build does not recognise.
    Pending,
}

impl KappStatus {
    /// Classify one kapp `description`.
    ///
    /// Failure is tested before success, because a description that mentions
    /// both is reporting a failure — the success it also names is the one it
    /// is superseding.
    ///
    /// Anything unrecognised is [`KappStatus::Pending`], never
    /// [`KappStatus::Succeeded`]: an app this build cannot classify is not
    /// evidence that anything worked.
    #[must_use]
    pub fn classify(description: &str) -> Self {
        let text = description.trim().to_ascii_lowercase();

        if text.contains("fail") || text.contains("error") {
            Self::Failed
        } else if text.contains("succeeded") {
            Self::Succeeded
        } else {
            Self::Pending
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_the_descriptions_kapp_emits() {
        assert_eq!(
            KappStatus::classify("Reconcile succeeded"),
            KappStatus::Succeeded
        );
        assert_eq!(KappStatus::classify("Reconcile failed"), KappStatus::Failed);
        assert_eq!(
            KappStatus::classify("Reconcile in progress"),
            KappStatus::Pending
        );
        assert_eq!(KappStatus::classify("Delete failed"), KappStatus::Failed);
        assert_eq!(KappStatus::classify("Deleting"), KappStatus::Pending);
    }

    #[test]
    fn case_and_padding_do_not_change_the_answer() {
        assert_eq!(
            KappStatus::classify("  RECONCILE SUCCEEDED  "),
            KappStatus::Succeeded
        );
    }

    /// The bug this type exists to remove: the old display-site chain asked
    /// `contains("Succeeded")` first, so this rendered green.
    #[test]
    fn a_failure_that_also_names_a_success_is_a_failure() {
        assert_eq!(
            KappStatus::classify("Reconcile failed (previously Succeeded)"),
            KappStatus::Failed
        );
    }

    #[test]
    fn an_unrecognised_description_is_never_success() {
        assert_eq!(KappStatus::classify(""), KappStatus::Pending);
        assert_eq!(KappStatus::classify("unknown"), KappStatus::Pending);
        assert_eq!(
            KappStatus::classify("something kapp has not said before"),
            KappStatus::Pending
        );
    }

    #[test]
    fn an_error_is_a_failure_even_without_the_word_failed() {
        assert_eq!(
            KappStatus::classify("Reconcile error: timed out"),
            KappStatus::Failed
        );
    }
}
