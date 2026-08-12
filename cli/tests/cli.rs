use assert_cmd::Command;
use predicates::prelude::PredicateBooleanExt;
use predicates::str::contains;

fn cata() -> Command {
    Command::cargo_bin("cata").expect("cata binary is built by cargo")
}

#[test]
fn help_lists_top_level_subcommands() {
    cata()
        .arg("--help")
        .assert()
        .success()
        .stdout(contains("cluster"))
        .stdout(contains("lab"))
        .stdout(contains("apply"))
        .stdout(contains("diagnose"))
        .stdout(contains("secrets"));
}

#[test]
fn top_level_subcommands_and_global_flags_are_described() {
    cata()
        .arg("--help")
        .assert()
        .success()
        .stdout(contains("Lab-level operations"))
        .stdout(contains("Per-cluster operations"))
        .stdout(contains("Manage the encrypted secret stores"))
        .stdout(contains("Flake to evaluate"))
        .stdout(contains("Verbose output"));
}

#[test]
fn version_prints_a_semver_string() {
    cata()
        .arg("--version")
        .assert()
        .success()
        .stdout(predicates::str::is_match(r"^cata \d+\.\d+\.\d+\n$").unwrap());
}

#[test]
fn lab_help_lists_subcommands() {
    cata()
        .args(["lab", "--help"])
        .assert()
        .success()
        .stdout(contains("list"))
        .stdout(contains("up"))
        .stdout(contains("down"))
        .stdout(contains("destroy"))
        .stdout(contains("plan"))
        .stdout(contains("apply"));
}

#[test]
fn unknown_subcommand_exits_non_zero() {
    cata()
        .arg("nonexistent-subcommand")
        .assert()
        .failure()
        .stderr(contains("unrecognized subcommand").or(contains("unexpected argument")));
}

#[test]
fn secrets_help_mentions_edit_generate() {
    cata()
        .args(["secrets", "--help"])
        .assert()
        .success()
        .stdout(contains("edit"))
        .stdout(contains("generate"));
}

#[test]
fn secrets_generate_offers_both_store_formats() {
    cata()
        .args(["secrets", "generate", "--help"])
        .assert()
        .success()
        .stdout(contains("--format"))
        .stdout(contains("sops"))
        .stdout(contains("env"));
}

#[test]
fn images_help_lists_subcommands() {
    cata()
        .args(["images", "--help"])
        .assert()
        .success()
        .stdout(contains("list").or(contains("warm")).or(contains("mirror")));
}

#[test]
fn flake_flag_parses_before_subcommand_dispatch() {
    cata().args(["--flake", ".", "--help"]).assert().success();
}

#[test]
fn verbose_flag_is_accepted() {
    cata().args(["-v", "--help"]).assert().success();
}
