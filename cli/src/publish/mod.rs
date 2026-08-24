use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;

/// `Ok(None)` means the lab configured no credential. Every other failure is
/// an error: a lab that asked for one and did not get it must not fall back to
/// an anonymous push, which fails later as an unexplained git error.
fn resolve_publish_auth(lab: &serde_json::Value) -> Result<Option<(String, String)>> {
    let Some(cred) = lab.pointer("/cd/git/credentialFromKubeSecret") else {
        return Ok(None);
    };
    if cred.is_null() {
        return Ok(None);
    }

    let field = |k: &str| -> Result<String> {
        cred.get(k)
            .and_then(|v| v.as_str())
            .map(String::from)
            .with_context(|| {
                format!("cd.git.credentialFromKubeSecret is set but has no string `{k}`")
            })
    };

    let context = field("context")?;
    let namespace = field("namespace")?;
    let name = field("name")?;
    let username = field("username")?;
    let key = cred.get("key").and_then(|v| v.as_str()).unwrap_or("token");

    let jsonpath = format!("jsonpath={{.data.{key}}}");
    let out = crate::io::kubectl::output(
        &context,
        &["-n", &namespace, "get", "secret", &name, "-o", &jsonpath],
    )
    .with_context(|| format!("reading credential Secret {namespace}/{name} on '{context}'"))?;

    if !out.status.success() {
        bail!(
            "could not read credential Secret {namespace}/{name} on '{context}': {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }

    let b64 = String::from_utf8(out.stdout)
        .context("the credential Secret's value is not valid UTF-8")?;
    let b64 = b64.trim();
    if b64.is_empty() {
        bail!("credential Secret {namespace}/{name} has no key `{key}`");
    }

    use base64::Engine as _;
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .with_context(|| format!("key `{key}` of {namespace}/{name} is not base64"))?;
    let token = String::from_utf8(decoded)
        .with_context(|| format!("key `{key}` of {namespace}/{name} is not valid UTF-8"))?;

    Ok(Some((username, token)))
}

fn maybe_embed_publish_auth(repo: &str, lab: &serde_json::Value) -> Result<String> {
    if !repo.starts_with("https://") {
        return Ok(repo.to_string());
    }
    match resolve_publish_auth(lab)? {
        Some((user, token)) => {
            let rest = &repo["https://".len()..];
            let token_esc = token.replace('@', "%40").replace(':', "%3A");
            let user_esc = user.replace('@', "%40").replace(':', "%3A");
            Ok(format!("https://{user_esc}:{token_esc}@{rest}"))
        }
        None => Ok(repo.to_string()),
    }
}

pub async fn publish(
    ctx: &CataContext,
    name: &str,
    pr: bool,
    message: Option<String>,
    dry_run: bool,
) -> Result<()> {
    let lab = crate::io::nix::get_lab_config(ctx, name)?;

    let git_cfg = lab.pointer("/cd/git");
    let repo = git_cfg.and_then(|g| g["repo"].as_str()).unwrap_or("");

    if repo.is_empty() {
        bail!("No git repo configured. Set lab.cd.git.repo in your lab config.");
    }

    let branch = git_cfg.and_then(|g| g["branch"].as_str()).unwrap_or("main");
    let repo_path = git_cfg.and_then(|g| g["path"].as_str()).unwrap_or("");
    let provider = git_cfg
        .and_then(|g| g["provider"].as_str())
        .unwrap_or("github");

    let effective_repo = maybe_embed_publish_auth(repo, &lab)?;
    let pr_enabled = pr
        || git_cfg
            .and_then(|g| g["prEnabled"].as_bool())
            .unwrap_or(false);
    let pr_base = git_cfg
        .and_then(|g| g["prBaseBranch"].as_str())
        .unwrap_or("main");

    println!(
        "{} Publishing manifests for lab '{name}'",
        style("catallaxy").cyan().bold()
    );

    println!("{} Building lab manifests...", style(">>>").cyan());
    let package_path = crate::io::nix::build_lab_package(ctx, name)?;

    let manifests_src = format!("{package_path}/manifests");
    if !std::path::Path::new(&manifests_src).exists() {
        bail!("No manifests found at {manifests_src}");
    }

    if dry_run {
        println!("{} Dry run: would publish to:", style(">>>").yellow());
        println!("  Repo: {repo}");
        println!("  Branch: {branch}");
        println!(
            "  Path: {}",
            if repo_path.is_empty() { "/" } else { repo_path }
        );
        println!("  PR: {pr_enabled}");
        println!();
        println!("  Manifests: {manifests_src}");

        crate::io::fs::list_yaml_files(&manifests_src);
        return Ok(());
    }

    let tmp_dir = tempfile::tempdir().context("Failed to create temp directory")?;
    let clone_dir = tmp_dir.path().join("repo");
    clone_repo(&effective_repo, repo, branch, &clone_dir)?;

    let target_dir = if repo_path.is_empty() {
        clone_dir.clone()
    } else {
        clone_dir.join(repo_path)
    };

    let work_branch = if pr_enabled {
        Some(checkout_work_branch(&clone_dir, name)?)
    } else {
        None
    };

    copy_manifests(&manifests_src, &package_path, &target_dir)?;

    if !commit_manifests(&clone_dir, message, name)? {
        if pr_enabled {
            println!(
                "{} No pull request opened: the rendered manifests already match \
                 {repo} on '{branch}', so there is nothing to propose.",
                style(">>>").green(),
            );
        }
        return Ok(());
    }

    let push_branch = work_branch.as_deref().unwrap_or(branch);
    push_manifests(&clone_dir, repo, push_branch)?;

    if pr_enabled {
        let work_branch = work_branch
            .as_deref()
            .expect("work_branch is Some when pr_enabled is true");
        open_pull_request(&clone_dir, name, provider, pr_base, work_branch)?;
    }

    println!("{} Manifests published to {}", style(">>>").green(), repo);

    Ok(())
}

fn clone_repo(
    effective_repo: &str,
    repo: &str,
    branch: &str,
    clone_dir: &std::path::Path,
) -> Result<()> {
    println!("{} Cloning {}...", style(">>>").cyan(), repo);

    let status = crate::io::git::clone_shallow(effective_repo, branch, clone_dir)
        .context("Failed to clone git repo")?;

    if !status.success() {
        let status =
            crate::io::git::clone(effective_repo, clone_dir).context("Failed to clone git repo")?;

        if !status.success() {
            bail!("Failed to clone {repo}");
        }
    }
    Ok(())
}

fn checkout_work_branch(clone_dir: &std::path::Path, name: &str) -> Result<String> {
    let branch_name = format!("catallaxy/{name}/{}", chrono_simple_timestamp());
    let status = crate::io::git::create_branch(clone_dir, &branch_name)?;
    if !status.success() {
        bail!("Failed to create branch {branch_name}");
    }
    Ok(branch_name)
}

fn copy_manifests(
    manifests_src: &str,
    package_path: &str,
    target_dir: &std::path::Path,
) -> Result<()> {
    let manifests_target = target_dir.join("manifests");
    if manifests_target.exists() {
        crate::io::fs::remove_dir_all(&manifests_target)?;
    }

    println!("{} Copying manifests...", style(">>>").cyan());

    crate::io::fs::copy_tree_dereferencing(manifests_src, target_dir)?;

    let metadata_src = format!("{package_path}/metadata.json");
    if std::path::Path::new(&metadata_src).exists() {
        crate::io::fs::copy(&metadata_src, target_dir.join("metadata.json"))?;
    }
    Ok(())
}

fn commit_manifests(
    clone_dir: &std::path::Path,
    message: Option<String>,
    name: &str,
) -> Result<bool> {
    let commit_msg =
        message.unwrap_or_else(|| format!("chore(catallaxy): update manifests for lab '{name}'"));

    let status = crate::io::git::stage_all(clone_dir)?;
    if !status.success() {
        bail!("git add failed");
    }

    let diff_status = crate::io::git::staged_tree_is_clean(clone_dir)?;

    if diff_status.success() {
        println!(
            "{} No changes to publish, manifests are up to date",
            style(">>>").green()
        );
        return Ok(false);
    }

    let status = crate::io::git::commit(clone_dir, &commit_msg)?;
    if !status.success() {
        bail!("git commit failed");
    }

    Ok(true)
}

fn push_manifests(clone_dir: &std::path::Path, repo: &str, push_branch: &str) -> Result<()> {
    println!(
        "{} Pushing to {} (branch: {})...",
        style(">>>").cyan(),
        repo,
        push_branch
    );

    let status = crate::io::git::push(clone_dir, "origin", push_branch)?;
    if !status.success() {
        bail!("git push failed");
    }

    Ok(())
}

fn open_pull_request(
    clone_dir: &std::path::Path,
    name: &str,
    provider: &str,
    pr_base: &str,
    work_branch: &str,
) -> Result<()> {
    println!(
        "{} Creating PR: {} → {}...",
        style(">>>").cyan(),
        work_branch,
        pr_base
    );

    let pr_title = format!("Update manifests for lab '{name}'");
    let pr_body = format!("Automated manifest update from `cata lab publish`.\n\nLab: {name}");

    let pr_result = match provider {
        "github" => crate::io::git::open_github_pull_request(
            clone_dir,
            &pr_title,
            &pr_body,
            pr_base,
            work_branch,
        ),
        "gitlab" => crate::io::git::open_gitlab_merge_request(
            clone_dir,
            &pr_title,
            &pr_body,
            pr_base,
            work_branch,
        ),
        _ => {
            println!(
                "{} PR creation not yet supported for provider '{}'. Push succeeded, create PR manually.",
                style(">>>").yellow(),
                provider
            );
            return Ok(());
        }
    };

    match pr_result {
        Ok(s) if s.success() => {
            println!("{} PR created successfully", style(">>>").green());
        }
        _ => {
            println!(
                "{} PR creation may have failed. Push succeeded, check manually.",
                style(">>>").yellow()
            );
        }
    }

    Ok(())
}

fn chrono_simple_timestamp() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{secs}")
}
