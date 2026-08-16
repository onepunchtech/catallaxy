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
fn verify_refuses_a_check_name_it_does_not_have() {
    cata()
        .args(["lab", "verify", "--check", "declared"])
        .assert()
        .failure()
        .stderr(contains("chainsaw"));
}

#[test]
fn verify_accepts_every_check_it_advertises() {
    for check in cata::verify::CHECK_NAMES {
        cata()
            .args(["lab", "verify", "--check", check, "--help"])
            .assert()
            .success();
    }
}

#[test]
fn topology_refuses_a_format_it_cannot_render() {
    cata()
        .args(["lab", "topology", "--format", "jsno"])
        .assert()
        .failure()
        .stderr(contains("json"));
}

#[test]
fn destroy_offers_the_same_safety_controls_as_up() {
    cata()
        .args(["lab", "destroy", "--help"])
        .assert()
        .success()
        .stdout(contains("--dry-run"))
        .stdout(contains("--up-to"));
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

// What a lab rendered and what its clusters are running are different
// questions, and only one of them sees what an operator created. Both have to
// be reachable or the second one is a thing nobody finds.
#[test]
fn images_offers_both_the_rendered_and_the_running_list() {
    cata()
        .args(["images", "--help"])
        .assert()
        .success()
        .stdout(contains("list"))
        .stdout(contains("actual"));
}

#[test]
fn images_actual_can_be_narrowed_to_one_cluster_and_to_surprises() {
    cata()
        .args(["images", "actual", "--help"])
        .assert()
        .success()
        .stdout(contains("--cluster"))
        .stdout(contains("--undeclared"));
}

#[test]
fn flake_flag_parses_before_subcommand_dispatch() {
    cata().args(["--flake", ".", "--help"]).assert().success();
}

#[test]
fn verbose_flag_is_accepted() {
    cata().args(["-v", "--help"]).assert().success();
}

#[test]
fn dns_refuses_to_set_up_and_tear_down_at_once() {
    cata()
        .args(["lab", "dns", "--setup", "--teardown", "some-lab"])
        .assert()
        .failure()
        .stderr(contains("opposite things"));
}
