//! The one place a kube context name is checked before a tool is told to use
//! it.
//!
//! kubectl, and every tool that forwards `--context` to it, reads an empty
//! value as *unset* and falls back to the kubeconfig's `current-context`. So a
//! lab whose context never resolved does not fail: it runs against whatever
//! cluster the operator happens to be pointed at. `lab status` reported such a
//! lab as reachable because some unrelated live cluster answered.
//!
//! Nothing outside `io/` builds a `--context` argument, and a lint keeps it
//! that way.

/// The context name, or an error explaining what would have happened.
///
/// # Errors
///
/// If `context` is empty or only whitespace. The message says what the tool
/// would have targeted instead, because the failure this prevents is silent.
pub fn require_named(context: &str) -> std::io::Result<&str> {
    if context.trim().is_empty() {
        return Err(std::io::Error::other(
            "a kube tool was asked for an empty --context. That reads as unset \
             and falls back to the kubeconfig's current-context, which would \
             target whatever cluster you are pointed at rather than the lab's. \
             The lab's plan is missing a context for this cluster; run \
             `cata lab plan` to see what it resolved.",
        ));
    }
    Ok(context)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_context_is_refused_rather_than_meaning_the_current_one() {
        for context in ["", " ", "\t", "\n", "  \t "] {
            let err = require_named(context).expect_err("an empty context must be refused");
            assert!(
                err.to_string().contains("current-context"),
                "the error should say what the tool would have done instead: {err}"
            );
        }
    }

    #[test]
    fn a_named_context_passes_through_unchanged() {
        assert_eq!(require_named("k3d-app").unwrap(), "k3d-app");
    }
}
