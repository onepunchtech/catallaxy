use clap::{Arg, Command};

use super::options::{anchor, escape_placeholders};

fn is_help(cmd: &Command) -> bool {
    cmd.get_name() == "help"
}

fn help_of(arg: &Arg) -> String {
    escape_placeholders(&arg.get_help().map(|h| h.to_string()).unwrap_or_default())
}

fn placeholder(arg: &Arg) -> String {
    arg.get_value_names()
        .and_then(|names| names.first().map(|n| n.to_string()))
        .unwrap_or_else(|| arg.get_id().to_string().to_uppercase())
}

fn flag_spelling(arg: &Arg) -> String {
    let mut parts = Vec::new();
    if let Some(short) = arg.get_short() {
        parts.push(format!("-{short}"));
    }
    if let Some(long) = arg.get_long() {
        parts.push(format!("--{long}"));
    }
    let mut spelling = parts.join(", ");
    if arg.get_action().takes_values() {
        spelling.push_str(&format!(" <{}>", placeholder(arg)));
    }
    spelling
}

fn usage(path: &str, cmd: &Command) -> String {
    let mut out = format!("cata {path}");
    if cmd.get_subcommands().filter(|s| !is_help(s)).count() > 0 {
        out.push_str(" <COMMAND>");
        return out;
    }
    if cmd.get_arguments().any(|a| a.get_long().is_some()) {
        out.push_str(" [OPTIONS]");
    }
    for arg in cmd.get_positionals() {
        let name = placeholder(arg);
        if arg.is_required_set() {
            out.push_str(&format!(" <{name}>"));
        } else {
            out.push_str(&format!(" [{name}]"));
        }
    }
    out
}

fn render_args(cmd: &Command) -> String {
    let positionals: Vec<&Arg> = cmd.get_positionals().collect();
    let flags: Vec<&Arg> = cmd
        .get_arguments()
        .filter(|a| a.get_long().is_some() && a.get_id() != "help" && a.get_id() != "version")
        .collect();

    let mut out = String::new();

    if !positionals.is_empty() {
        out.push_str("| Argument | Required | Meaning |\n| --- | --- | --- |\n");
        for arg in &positionals {
            out.push_str(&format!(
                "| `{}` | {} | {} |\n",
                placeholder(arg),
                if arg.is_required_set() { "yes" } else { "no" },
                help_of(arg)
            ));
        }
        out.push('\n');
    }

    if !flags.is_empty() {
        out.push_str("| Flag | Default | Meaning |\n| --- | --- | --- |\n");
        for arg in &flags {
            let default = arg
                .get_default_values()
                .first()
                .map(|v| format!("`{}`", v.to_string_lossy()))
                .unwrap_or_default();
            out.push_str(&format!(
                "| `{}` | {default} | {} |\n",
                flag_spelling(arg),
                help_of(arg)
            ));
        }
        out.push('\n');
    }

    out
}

fn render_leaf(path: &str, cmd: &Command, out: &mut String) {
    out.push_str(&format!("### `cata {path}` {{#{}}}\n\n", anchor(path)));
    if let Some(about) = cmd.get_about() {
        out.push_str(&format!("{}\n\n", escape_placeholders(&about.to_string())));
    }
    out.push_str(&format!("```\n{}\n```\n\n", usage(path, cmd)));
    out.push_str(&render_args(cmd));
}

fn walk(path: &str, cmd: &Command, out: &mut String) {
    let subs: Vec<&Command> = cmd.get_subcommands().filter(|s| !is_help(s)).collect();
    if subs.is_empty() {
        render_leaf(path, cmd, out);
        return;
    }
    for sub in subs {
        walk(&format!("{path} {}", sub.get_name()), sub, out);
    }
}

fn index(root: &Command) -> String {
    let mut out = String::from("| Command | Does |\n| --- | --- |\n");
    let mut rows: Vec<String> = Vec::new();
    for top in root.get_subcommands().filter(|s| !is_help(s)) {
        collect_index(top.get_name(), top, &mut rows);
    }
    for row in rows {
        out.push_str(&row);
    }
    out.push('\n');
    out
}

fn collect_index(path: &str, cmd: &Command, rows: &mut Vec<String>) {
    let subs: Vec<&Command> = cmd.get_subcommands().filter(|s| !is_help(s)).collect();
    if subs.is_empty() {
        rows.push(format!(
            "| [`cata {path}`](#{}) | {} |\n",
            anchor(path),
            escape_placeholders(&cmd.get_about().map(|a| a.to_string()).unwrap_or_default())
        ));
        return;
    }
    for sub in subs {
        collect_index(&format!("{path} {}", sub.get_name()), sub, rows);
    }
}

pub fn render(root: &Command) -> String {
    let mut out = String::from("# CLI Commands\n\n");
    out.push_str(
        "Every command and flag, generated from the parser. The judgement, \
         the flake fragment and what replaced the removed commands are in \
         [CLI](../cli.md).\n\n",
    );

    let globals: Vec<&Arg> = root
        .get_arguments()
        .filter(|a| a.get_long().is_some() && a.get_id() != "help" && a.get_id() != "version")
        .collect();
    if !globals.is_empty() {
        out.push_str("## Global flags\n\n");
        out.push_str("| Flag | Default | Meaning |\n| --- | --- | --- |\n");
        for arg in &globals {
            let default = arg
                .get_default_values()
                .first()
                .map(|v| format!("`{}`", v.to_string_lossy()))
                .unwrap_or_default();
            out.push_str(&format!(
                "| `{}` | {default} | {} |\n",
                flag_spelling(arg),
                help_of(arg)
            ));
        }
        out.push('\n');
    }

    out.push_str(&index(root));

    for top in root.get_subcommands().filter(|s| !is_help(s)) {
        out.push_str(&format!("## `cata {}`\n\n", top.get_name()));
        if let Some(about) = top.get_about() {
            out.push_str(&format!("{}\n\n", escape_placeholders(&about.to_string())));
        }
        walk(top.get_name(), top, &mut out);
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::{Arg, ArgAction};

    fn fixture() -> Command {
        Command::new("cata")
            .arg(
                Arg::new("flake")
                    .long("flake")
                    .default_value(".")
                    .value_name("REF")
                    .help("Flake to evaluate"),
            )
            .subcommand(
                Command::new("lab")
                    .about("Lab-level operations")
                    .subcommand(
                        Command::new("up")
                            .about("Run the deploy plan")
                            .arg(Arg::new("name").help("Lab to act on"))
                            .arg(
                                Arg::new("dry-run")
                                    .long("dry-run")
                                    .action(ArgAction::SetTrue)
                                    .help("Print what would happen"),
                            ),
                    ),
            )
    }

    #[test]
    fn leaf_commands_get_an_anchor_and_usage() {
        let page = render(&fixture());
        assert!(page.contains("### `cata lab up` {#lab-up}"));
        assert!(page.contains("```\ncata lab up [OPTIONS] [NAME]\n```"));
    }

    #[test]
    fn the_index_links_every_leaf() {
        let page = render(&fixture());
        assert!(page.contains("| [`cata lab up`](#lab-up) | Run the deploy plan |"));
    }

    #[test]
    fn global_flags_are_listed_once_with_their_default() {
        let page = render(&fixture());
        assert!(page.contains("## Global flags"));
        assert!(page.contains("| `--flake <REF>` | `.` | Flake to evaluate |"));
    }

    #[test]
    fn positionals_and_flags_are_tabulated() {
        let page = render(&fixture());
        assert!(page.contains("| `NAME` | no | Lab to act on |"));
        assert!(page.contains("| `--dry-run` |  | Print what would happen |"));
    }

    #[test]
    fn the_help_subcommand_is_not_documented() {
        let cmd = Command::new("cata").subcommand(Command::new("help").about("Print help"));
        assert!(!render(&cmd).contains("cata help"));
    }
}
