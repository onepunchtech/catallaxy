use anyhow::{Result, bail};
use base64::Engine;
use rand::Rng;

/// The most bytes of entropy a generated secret may ask for.
///
/// High enough that no real secret hits it, low enough that a typo'd length
/// cannot ask for an allocation that aborts the process.
const MAX_LENGTH: u64 = 4096;

fn entropy_length(generator: &str, length: Option<u64>) -> Result<usize> {
    let len =
        length.ok_or_else(|| anyhow::anyhow!("the {generator} generator requires a length"))?;

    if len == 0 {
        bail!(
            "the {generator} generator was asked for a length of 0, which mints an \
             empty secret. Set a length on the key in `lab.secrets.managed`"
        );
    }
    if len > MAX_LENGTH {
        bail!(
            "the {generator} generator was asked for a length of {len}, above the \
             {MAX_LENGTH} byte limit. Set a length on the key in `lab.secrets.managed`"
        );
    }

    Ok(len as usize)
}

fn random_bytes(len: usize) -> Vec<u8> {
    let mut bytes = vec![0u8; len];
    rand::thread_rng().fill(&mut bytes[..]);
    bytes
}

pub fn generate_value(generator: &str, length: Option<u64>) -> Result<String> {
    match generator {
        "base64" => Ok(base64::engine::general_purpose::STANDARD
            .encode(random_bytes(entropy_length(generator, length)?))),
        "hex" => Ok(hex::encode(&random_bytes(entropy_length(
            generator, length,
        )?))),
        "alphanumeric" => {
            let len = entropy_length(generator, length)?;
            Ok(rand::thread_rng()
                .sample_iter(&rand::distributions::Alphanumeric)
                .take(len)
                .map(char::from)
                .collect())
        }
        "uuid" => Ok(uuid::Uuid::new_v4().to_string()),
        _ => bail!("Unknown generator: {generator}"),
    }
}

mod hex {
    pub fn encode(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ENTROPY_GENERATORS: [&str; 3] = ["base64", "hex", "alphanumeric"];

    #[test]
    fn a_length_of_zero_is_refused_rather_than_minting_an_empty_secret() {
        for generator in ENTROPY_GENERATORS {
            let err =
                generate_value(generator, Some(0)).expect_err("a length of 0 must be refused");
            assert!(
                err.to_string().contains("empty secret"),
                "{generator}: {err}"
            );
        }
    }

    #[test]
    fn a_length_beyond_the_limit_is_refused_rather_than_allocated() {
        for generator in ENTROPY_GENERATORS {
            let err = generate_value(generator, Some(10_000_000_000))
                .expect_err("an enormous length must be refused");
            assert!(err.to_string().contains("limit"), "{generator}: {err}");
        }
    }

    #[test]
    fn a_missing_length_is_refused_for_every_generator_that_needs_one() {
        for generator in ENTROPY_GENERATORS {
            assert!(generate_value(generator, None).is_err(), "{generator}");
        }
    }

    #[test]
    fn uuid_needs_no_length() {
        assert_eq!(generate_value("uuid", None).unwrap().len(), 36);
    }

    #[test]
    fn an_unknown_generator_is_refused() {
        assert!(generate_value("rot13", Some(16)).is_err());
    }

    #[test]
    fn each_generator_produces_the_width_its_encoding_implies() {
        assert_eq!(generate_value("hex", Some(16)).unwrap().len(), 32);
        assert_eq!(generate_value("alphanumeric", Some(24)).unwrap().len(), 24);
        assert!(generate_value("base64", Some(32)).unwrap().len() >= 32);
    }

    #[test]
    fn two_values_from_one_generator_differ() {
        for generator in ENTROPY_GENERATORS {
            assert_ne!(
                generate_value(generator, Some(32)).unwrap(),
                generate_value(generator, Some(32)).unwrap(),
                "{generator} produced the same value twice"
            );
        }
    }

    #[test]
    fn the_boundary_lengths_are_accepted() {
        for generator in ENTROPY_GENERATORS {
            assert!(generate_value(generator, Some(1)).is_ok(), "{generator}");
            assert!(
                generate_value(generator, Some(MAX_LENGTH)).is_ok(),
                "{generator}"
            );
        }
    }
}
