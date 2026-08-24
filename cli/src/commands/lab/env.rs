use anyhow::{Result, bail};

use crate::host::state::lab_kubeconfig_path;
use crate::io::trust::{self, Outcome};

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum Shell {
    Posix,
    Fish,
    Json,
}

fn emit(shell: Shell, pairs: &[(&'static str, std::ffi::OsString)]) {
    match shell {
        Shell::Posix => {
            for (k, v) in pairs {
                println!("export {k}={};", shell_quote(&v.to_string_lossy()));
            }
        }
        Shell::Fish => {
            for (k, v) in pairs {
                println!("set -gx {k} {};", shell_quote(&v.to_string_lossy()));
            }
        }
        Shell::Json => {}
    }
}

pub fn env(lab_name: &str, shell: Shell, unset: bool) -> Result<()> {
    let bundle = trust::bundle_path(lab_name);
    let lab_ca = trust::lab_ca_path(lab_name);

    // The lab's clusters live in its own kubeconfig rather than in
    // ~/.kube/config, so this is what makes a bare `kubectl` reach them. Set
    // outside the CA branch below on purpose: a lab serving plain HTTP has no
    // CA and still has clusters, and that case used to get nothing at all.
    let kubeconfig = crate::io::kubeconfig::env_pairs(&lab_kubeconfig_path(lab_name));

    let keys: Vec<&str> = kubeconfig
        .iter()
        .map(|(k, _)| *k)
        .chain(
            trust::env_pairs(&bundle, &lab_ca)
                .into_iter()
                .map(|(k, _)| k),
        )
        .collect();

    if unset {
        for k in &keys {
            match shell {
                Shell::Posix => println!("unset {k};"),
                Shell::Fish => println!("set -e {k};"),
                Shell::Json => {}
            }
        }
        if shell == Shell::Json {
            println!("{}", serde_json::json!({ "unset": keys }));
        }
        return Ok(());
    }

    emit(shell, &kubeconfig);

    match trust::ensure_bundle(lab_name)? {
        Outcome::Ready(path) => {
            let pairs = trust::env_pairs(&path, &lab_ca);
            match shell {
                Shell::Posix => {
                    for (k, v) in &pairs {
                        println!("export {k}={};", shell_quote(&v.to_string_lossy()));
                    }
                }
                Shell::Fish => {
                    for (k, v) in &pairs {
                        println!("set -gx {k} {};", shell_quote(&v.to_string_lossy()));
                    }
                }
                Shell::Json => {
                    let map: serde_json::Map<String, serde_json::Value> = kubeconfig
                        .iter()
                        .chain(pairs.iter())
                        .map(|(k, v)| ((*k).to_string(), v.to_string_lossy().into()))
                        .collect();
                    println!("{}", serde_json::Value::Object(map));
                }
            }
            Ok(())
        }
        // Not an error any more: KUBECONFIG is already out, and it is the
        // half that a lab serving plain HTTP actually needs. Failing here
        // would mean `eval "$(cata lab env ...)"` returned non-zero for every
        // lab with TLS off, having already printed something useful.
        Outcome::NoLabCa => {
            if shell == Shell::Json {
                let map: serde_json::Map<String, serde_json::Value> = kubeconfig
                    .iter()
                    .map(|(k, v)| ((*k).to_string(), v.to_string_lossy().into()))
                    .collect();
                println!("{}", serde_json::Value::Object(map));
            }
            eprintln!(
                "note: lab '{lab_name}' has no CA at {}, so only KUBECONFIG was set. \
                 A lab that serves plain HTTP has no CA and needs none.",
                lab_ca.display()
            );
            Ok(())
        }
        Outcome::NoSystemRoots => bail!(
            "found lab '{lab_name}'s CA, but no public CA bundle to merge it with.\n    \
             Exporting the lab CA alone would break every public HTTPS call in \
             this shell, so nothing was written.\n    \
             Install `cata` through nix (it supplies one), or point \
             $CATALLAXY_SYSTEM_CA_BUNDLE at your system roots."
        ),
    }
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_paths_containing_spaces_and_quotes() {
        assert_eq!(shell_quote("/home/a b/ca.crt"), "'/home/a b/ca.crt'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
    }
}
