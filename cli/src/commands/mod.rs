pub mod apply;
pub mod cli;
pub mod cluster;
pub mod diagnose;
pub mod docs;
pub mod generate;
pub mod images;
pub mod kubeconfig;
pub mod lab;
pub mod new;
pub mod pki;
pub mod secrets;

#[cfg(test)]
mod help_text {
    use clap::{Args, Command, Subcommand};

    fn undescribed(cmd: &Command, path: &str, out: &mut Vec<String>) {
        for arg in cmd.get_arguments() {
            if arg.get_help().is_none() {
                out.push(format!("{path} --{}", arg.get_id()));
            }
        }
        for sub in cmd.get_subcommands() {
            if sub.get_name() == "help" {
                continue;
            }
            let sub_path = format!("{path} {}", sub.get_name());
            if sub.get_about().is_none() {
                out.push(sub_path.clone());
            }
            undescribed(sub, &sub_path, out);
        }
    }

    fn roots() -> Vec<Command> {
        vec![
            super::lab::LabCommands::augment_subcommands(Command::new("lab")),
            super::cluster::ClusterCommands::augment_subcommands(Command::new("cluster")),
            super::secrets::SecretsCommands::augment_subcommands(Command::new("secrets")),
            super::pki::PkiCommands::augment_subcommands(Command::new("pki")),
            super::images::ImagesCommands::augment_subcommands(Command::new("images")),
            super::docs::DocsCommands::augment_subcommands(Command::new("docs")),
            super::kubeconfig::KubeconfigCommands::augment_subcommands(Command::new("kubeconfig")),
            super::apply::ApplyArgs::augment_args(Command::new("apply")),
            super::diagnose::DiagnoseArgs::augment_args(Command::new("diagnose")),
            super::generate::GenerateArgs::augment_args(Command::new("generate")),
        ]
    }

    #[test]
    fn every_subcommand_and_argument_is_described() {
        let mut missing = Vec::new();
        for root in roots() {
            let name = root.get_name().to_string();
            undescribed(&root, &name, &mut missing);
        }
        assert!(
            missing.is_empty(),
            "clap help text is the CLI's user-facing documentation and these have none:\n  {}",
            missing.join("\n  ")
        );
    }
}
