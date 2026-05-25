//! Secret value generators.

use anyhow::{Result, bail};
use base64::Engine;
use rand::Rng;

pub fn generate_value(generator: &str, length: Option<u64>) -> Result<String> {
    match generator {
        "base64" => {
            let len =
                length.ok_or_else(|| anyhow::anyhow!("base64 generator requires length"))? as usize;
            let mut bytes = vec![0u8; len];
            rand::thread_rng().fill(&mut bytes[..]);
            Ok(base64::engine::general_purpose::STANDARD.encode(&bytes))
        }
        "hex" => {
            let len =
                length.ok_or_else(|| anyhow::anyhow!("hex generator requires length"))? as usize;
            let mut bytes = vec![0u8; len];
            rand::thread_rng().fill(&mut bytes[..]);
            Ok(hex::encode(&bytes))
        }
        "alphanumeric" => {
            let len = length
                .ok_or_else(|| anyhow::anyhow!("alphanumeric generator requires length"))?
                as usize;
            let value: String = rand::thread_rng()
                .sample_iter(&rand::distributions::Alphanumeric)
                .take(len)
                .map(char::from)
                .collect();
            Ok(value)
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
