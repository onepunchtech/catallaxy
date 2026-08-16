use std::path::Path;
use std::process::Command;

use anyhow::Result;

use crate::io::process::{prepare_env, run_status};
use std::process::Stdio;

const COMMIT_IDENTITY_NAME: &str = "catallaxy";
const COMMIT_IDENTITY_EMAIL: &str = "catallaxy@invalid";

fn command() -> Command {
    let mut cmd = Command::new("git");
    prepare_env(&mut cmd);
    cmd.env("GIT_AUTHOR_NAME", COMMIT_IDENTITY_NAME)
        .env("GIT_AUTHOR_EMAIL", COMMIT_IDENTITY_EMAIL)
        .env("GIT_COMMITTER_NAME", COMMIT_IDENTITY_NAME)
        .env("GIT_COMMITTER_EMAIL", COMMIT_IDENTITY_EMAIL);
    cmd
}

pub fn open_github_pull_request(
    clone_dir: &Path,
    title: &str,
    body: &str,
    base: &str,
    head: &str,
) -> Result<std::process::ExitStatus> {
    run_status(Command::new("gh").args(["-C"]).arg(clone_dir).args([
        "pr", "create", "--title", title, "--body", body, "--base", base, "--head", head,
    ]))
}

pub fn open_gitlab_merge_request(
    clone_dir: &Path,
    title: &str,
    description: &str,
    target_branch: &str,
    source_branch: &str,
) -> Result<std::process::ExitStatus> {
    run_status(Command::new("glab").args(["-C"]).arg(clone_dir).args([
        "mr",
        "create",
        "--title",
        title,
        "--description",
        description,
        "--target-branch",
        target_branch,
        "--source-branch",
        source_branch,
    ]))
}

pub fn clone_shallow(
    repo: &str,
    branch: &str,
    into: &Path,
) -> std::io::Result<std::process::ExitStatus> {
    command()
        .args(["clone", "--depth", "1", "--branch", branch, repo])
        .arg(into)
        .stdout(Stdio::null())
        .status()
}

pub fn clone(repo: &str, into: &Path) -> std::io::Result<std::process::ExitStatus> {
    command()
        .args(["clone", repo])
        .arg(into)
        .stdout(Stdio::null())
        .status()
}

fn in_repo(clone_dir: &Path, args: &[&str]) -> Command {
    let mut cmd = command();
    cmd.args(["-C"]).arg(clone_dir).args(args);
    cmd
}

pub fn create_branch(clone_dir: &Path, branch: &str) -> std::io::Result<std::process::ExitStatus> {
    in_repo(clone_dir, &["checkout", "-b", branch])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
}

pub fn stage_all(clone_dir: &Path) -> std::io::Result<std::process::ExitStatus> {
    in_repo(clone_dir, &["add", "-A"]).status()
}

pub fn staged_tree_is_clean(clone_dir: &Path) -> std::io::Result<std::process::ExitStatus> {
    in_repo(clone_dir, &["diff", "--cached", "--quiet"]).status()
}

pub fn commit(clone_dir: &Path, message: &str) -> std::io::Result<std::process::ExitStatus> {
    in_repo(clone_dir, &["commit", "-m", message])
        .stdout(Stdio::null())
        .status()
}

pub fn push(
    clone_dir: &Path,
    remote: &str,
    branch: &str,
) -> std::io::Result<std::process::ExitStatus> {
    in_repo(clone_dir, &["push", remote, branch]).status()
}
