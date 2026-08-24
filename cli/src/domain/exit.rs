/// A command asking for a specific exit code, having already said its piece.
///
/// Travels as an `anyhow::Error` so a command can return it through the same
/// `?` as everything else; `main` recognises it and exits with the code rather
/// than printing it. `std::process::exit` here would skip the destructors that
/// erase decrypted secrets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExitWith(pub u8);

impl ExitWith {
    pub fn code(self) -> u8 {
        self.0
    }
}

impl std::fmt::Display for ExitWith {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "exiting with status {}", self.0)
    }
}

impl std::error::Error for ExitWith {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_survives_the_trip_through_anyhow() {
        let err: anyhow::Error = ExitWith(3).into();
        assert_eq!(err.downcast_ref::<ExitWith>().map(|e| e.code()), Some(3));
    }

    #[test]
    fn an_ordinary_error_is_not_mistaken_for_one() {
        let err = anyhow::anyhow!("the cluster did not answer");
        assert!(err.downcast_ref::<ExitWith>().is_none());
    }

    #[test]
    fn it_survives_being_given_context() {
        use anyhow::Context;
        let err = Err::<(), _>(anyhow::Error::from(ExitWith(1)))
            .context("while diffing")
            .unwrap_err();
        assert_eq!(err.downcast_ref::<ExitWith>().map(|e| e.code()), Some(1));
    }
}
