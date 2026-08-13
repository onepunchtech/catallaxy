# Changelog

All notable changes to this project will be documented in this file.

The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **The cloud teardown path has a plan snapshot.** Nothing exercised it:
  none of the five example labs provision a cluster from another, `e2eLabs`
  is those same five, and `lib/tests/plan-graph.nix` checks `topoSort`
  against synthetic steps rather than a lab's real plan. So
  `release-cluster-cloud-resources`, `delete-managed-resource`,
  `wait-for-cluster-gone` and the pivot chain that feeds them had no test at
  all, on the one path whose failure mode is billable infrastructure nobody
  deletes.

  `examples/labs/tests/cloud-teardown.nix` is a lab that exists only to be
  evaluated: a bootstrap cluster provisioning two Crossplane clusters, one
  of them needing an external-name discovery binary, plus a
  self-provisioning cluster to reach the pivot and the wait-for-gone step
  that only the self case emits. Its deploy and teardown plans are
  snapshotted like the example labs', so it is checked without pretending to
  be a lab anyone can run. It is not an example: `discoverExampleLabs` does
  not see it, so it stays out of `cata lab list`, the docs and the e2e set.

  It earns its keep: deleting the edge that orders releasing a cluster's
  LoadBalancers and volumes before deleting the Cluster CR that owns them
  reorders the snapshot and fails the check, which is the mistake that would
  otherwise leak resources silently.

- **`nix flake check` now fails on a Rust warning, and on a lint
  suppression.** `cli-clippy` runs
  `cargo clippy --all-targets -- --deny warnings`, and
  `cli-no-lint-suppressions` fails if any `#[allow(...)]` or
  `#[expect(...)]` appears under `cli/`. The second exists because the first
  cannot see what a suppression covers: an `#[allow]` hides the warning from
  clippy exactly as it hid it from a human.

  Nine suppressions came out to get there. Three file-level
  `#![allow(unused_imports)]` were hiding 21 unused imports across
  `commands/lab/{apply,down,orchestrate}.rs`; four `#[allow(dead_code)]`
  were hiding three dead fields, and one of the four was hiding nothing at
  all; two `#[allow(clippy::too_many_arguments)]` were hiding a 12-argument
  and a 10-argument function. With them gone the crate had 123 findings, now
  zero: parameter structs for the seven over-long argument lists, a
  `SecretsByStore` alias for the three complex types, a real `FromStr` impl
  for `TopologyFormat`, and roughly 40 functions split out of 21 that ran
  past the 100-line limit the crate opts into.

- **A secret store can take its values from the environment.**
  `lab.secrets.stores.<n>.backend = "env"` reads one variable per key, named
  `CATA_SECRET_<STORE>__<SECRET>__<KEY>`, uppercased with every character
  that is not a letter or a digit replaced by an underscore. The name is
  derived, so there is nothing to declare and nothing to keep in sync; two
  underscores between the parts keep store `a_b` from colliding with secret
  `b_c`. `lab.secrets.envFile` names a file that sets them, as a path
  relative to the flake root, which `nix run .#e2e` loads before it stands
  the lab up. Catallaxy never reads that file: the environment is the
  interface, and the file is one way to fill it, named where a runner can
  find it.

  A relative path rather than a Nix path, because a Nix path resolves to the
  flake's source in the store, and Determinate Nix's lazy trees never write
  that source to disk. The runner was handed
  `/nix/store/<hash>-source/examples/labs/gitops/envs/ci.env` and found
  nothing there, on a file that is committed and present in the checkout.
  The repository is where the file actually is, and the relative form is
  also what a human can act on: it is the argument to `git add`.

  This is what CI needed. `.sops.yaml` and `secrets/` are both gitignored,
  so a fresh checkout can open no sops store, and every e2e run of
  `gitops.local` died at `cp: cannot stat '.sops.yaml'`. `gitops.local` now
  keeps its `app` store in the environment and commits the dummy values at
  `examples/labs/gitops/envs/ci.env`. They are throwaway by construction:
  every key is generated and the lab is destroyed at the end of the run.

  `cata secrets generate --format env` prints the `VAR='value'` lines an env
  store reads and writes nothing, which is how that file is regenerated when
  a lab's keys change. `secrets list` prints the derived names and whether
  they are set, rather than a `.enc.yaml` path that will never exist.

- **The CLI mints the lab CA.** `cata secrets generate` mints a
  `kind = "ca"` secret's certificate and key together with rcgen, the same
  way `cata pki init` already did, and
  `cata secrets init-intermediate <name>` signs a second CA with the root
  already in the store. Both work against either backend. `kind = "ca"` now
  always carries `ca.crt` and `ca.key`, which the option docs claimed but
  nothing implemented, so a lab no longer has to name them.

  This replaces `cata lab ops -- trust {init-ca,init-intermediate}`, two
  shell scripts over openssl, sops and yq. They copied the plaintext YAML,
  CA private key and all, into `secrets/<lab>/.init-ca.staging.enc.yaml` at
  umask permissions before encrypting it, purely so that sops's `path_regex`
  would match. `secrets generate` had already solved that with
  `--filename-override` and a 0600 temporary file. They also hardcoded
  `secrets/$lab/$store.enc.yaml` relative to the working directory, ignored
  the store's backend, and closed by telling you to `git add` a path this
  repo gitignores.

### Fixed

- **`cata diagnose` prints floe health again, and reports on the cluster it
  was asked about.** `print_component_health` read `config["components"]`, a
  key `cliConfig` stopped emitting when components became floes, so the
  lookup missed on every cluster and the section silently never appeared.
  Separately, `diagnose` carried its own copy of the kube-context resolver
  with the `runtimeContexts` clause dropped, so in a lab that pivots a
  cluster it dialled whatever the provisioner-baked context still reached.

- **`cata kubeconfig show` reports the context a cluster actually uses.** It
  derived the name itself, handled only k3d, and ignored the `kubeContext`
  the module system computes, so a Talos or Crossplane cluster was listed
  under its bare cluster name and then reported "not reachable" whether or
  not it was.

- **The lab proxy routes a floe that names its hostname under `gateway`.**
  `modules/lab/host/proxy.nix` built its HAProxy host map from each floe's
  top-level `domain`, so `floes.prometheus` and `floes.otel-collector`,
  which declare theirs at `gateway.domain`, were never given a backend. A
  request to `prometheus-rw.<zone>` reached HAProxy's default backend and
  came back 503 without ever leaving the host, which is what
  `homelab.local`'s verify had been failing on. The map now takes
  `gateway.domain` when it is set and the top-level `domain` otherwise.

  `example-lab-routed-hosts-are-proxied` keeps it honest: for every example
  lab it compares the hostnames with a public route inside a cluster against
  the hostnames the proxy has a backend for, and fails naming any that are
  routed but unreachable. Reverting the one-line fix makes it name
  `prometheus-rw.homelab.test` on both homelab labs.

- **`cata lab verify` probes a host where its route actually routes.** It
  asked every public host for `/`. `prometheus-rw.<zone>` matches only
  `PathPrefix: /api/v1/write`, so the probe asked for a path the gateway is
  right to refuse, and `homelab.local` failed verify on every run.
  `cluster.out.exposedHosts` now carries each route's path prefixes and the
  check uses the first one. 405 joins 401 and 403 as an answer: a write-only
  endpoint replies 405 to the GET this check makes, and only the workload
  itself can.

- **`publish-manifests` no longer needs the operator's git identity.** It
  commits into the lab's own Forgejo, so it now identifies itself as
  `catallaxy <catallaxy@invalid>` through `GIT_AUTHOR_*` and
  `GIT_COMMITTER_*` rather than falling back to `git config`. On a fresh
  runner there is none, and the step died with "Author identity unknown"
  after the lab was already up. A machine-made commit should not depend on
  who happens to be logged in.

### Removed

- **`cata cluster kubeconfig sync` is gone.** It read its list of workload
  clusters from `floes.cluster-api.clusters`, an option that does not exist:
  the cluster-api floe describes the shape of a workload cluster
  (`controlPlane`, `workers`, CIDRs) and never carried a list of them. The
  lookup missed every time, so the command could only ever fail. It was the
  last remnant of CAPI as a provisioner, a concept `cluster.provisioner`
  dropped when it settled on `k3d | talos | crossplane | external`, and the
  same vestige as the `Capi` variant removed from the CLI's provisioner enum
  above.

  Nothing replaces it because nothing needs to: the planner already emits a
  `sync-kubeconfig` step per provisioning cluster, with the target list
  derived from the provisioner graph rather than hand-written, ordered after
  provisioning and skipped when the cluster already answers.
  `io::kubectl::get_capi_kubeconfig`, `io::clusterctl::is_cluster_ready` and
  `io::clusterctl::wait_cluster_ready` went with it, having had no other
  caller, as did a `--timeout` parser that turned anything it could not read
  (`5h`, say) into ten minutes without saying so.

- **`cata lab ops -- trust init-ca` and `trust init-intermediate` are
  gone**, replaced by the two `cata secrets` commands above. `trust setup`,
  `browser`, `teardown` and `export` are unchanged. A CA minted by the old
  script keeps working; nothing rereads it. The new one is P-256 rather than
  RSA-4096, because that is what rcgen generates and what the rest of the
  CLI's PKI already uses; `secrets generate --force` rotates if you would
  rather have the new one.

- **`nix run .#e2e` no longer mints an age key or rewrites `.sops.yaml`.**
  It used to merge a throwaway rule into the repo's own file and restore it
  on exit, which never worked in CI (there is no file to merge into) and
  edited a developer's real `.sops.yaml` when run by hand. The runner now
  loads the lab's `envFile` and nothing else.

### Changed

- **The teardown reconcile is a step in the plan, not something the executor
  did on the way past.** `cata lab destroy` called into Crossplane before
  running the plan, annotating live managed resources and toggling
  `crossplane.io/paused` to make their controllers reclaim them. It ran on
  every teardown, printed as it went, and appeared nowhere in
  `cata lab plan --teardown`, so the one command whose promise is that you
  can read what will happen omitted the part that touches cloud state.

  The planner now emits `reconcile-managed-resource` per deletable target,
  between releasing that cluster's LoadBalancers and deleting the Cluster CR
  that owns them, which is where it belongs and where it used to run by
  accident of being first. It is a step like any other: it prints in the
  plan, `--up-to` can stop before it, and the ordering is a graph edge
  rather than a line at the top of `execute`.

  It also stops re-deriving its own work. It had scanned the step list for
  `delete-managed-resource` entries and grouped them by context to decide
  what to reconcile, which is the planner's job done twice; the planner
  passes it a target now.

- **`cata lab plan` refuses a step the executor would refuse.** The command
  and the executor each parsed the plan their own way, and only the executor
  checked that a step can run in the direction it was found in. A teardown
  step sitting in the deploy plan printed as a normal line and then failed
  at `lab up`, which is the one thing "read the plan first" is supposed to
  rule out. Both now call the same check, so what prints is what runs.

  The check applies only when the plan came from a lab. `--from-file` takes
  the plan as a bare array, and `--teardown` then selects nothing: there is
  no direction in the file to check a step against, so asserting one would
  reject a plan that is perfectly valid in the direction it was exported
  from.

  `Direction` moved to `domain` and `runs_in` takes it, rather than a `&str`
  matched as `"teardown" => …, _ => deploy`. Every caller that passed
  `"deployment"` and every caller that passed `"deploy"` had been agreeing
  by accident: both fell through to the same arm, and so would a typo.

- **The host-side modules moved out of `commands/` into `host/`.**
  `services.rs`, `pki.rs`, `state.rs` and `dns.rs` sat under
  `commands/lab/`, but their callers were plan steps and the verifier, not
  commands: only `dns` had a CLI surface at all, and that is now a thin
  `lab dns` over `host::dns`. `dns.rs` also split, because half of it was
  not DNS: `host/network.rs` takes the macOS routing and Colima VM
  firewalling, which had been living under a name about resolvers.

- **Privileged writes stage a file and `install` it, rather than piping into
  a shell.** Configuring the resolver built a shell script by interpolating
  the drop-in path into `set -e; mkdir -p …; cat > …; rm -f …`, ran it as
  `sudo sh -c`, and piped the content in on stdin. It now writes the content
  to a temporary file and runs `sudo install -m 0644`, `sudo mkdir`,
  `sudo rm` and `sudo systemctl` as separate argument vectors, so no shell
  parses a path. The zone check stays as a check that a zone looks like a
  hostname, which is what it was really asserting.

  Those calls go through a new `io::process::run_interactive`, which applies
  the lab CA and honours `--verbose` like the other helpers but leaves stdin
  attached. `run_streaming` and `run_capture` both null stdin, so neither
  could carry a `sudo` password prompt, and neither can serve a step that
  declares `policy.interactive`. That gap is why two call sites had been
  hand-calling `io::trust::apply` before spawning.

- **`cata lab dns --setup --teardown` is an error** instead of silently
  tearing down. The two flags asked for opposite things and the first branch
  won.

- **`commands/lab/orchestrate.rs` is gone, split by what its parts were
  for.** Nothing under `commands/` ever called it: every caller was a plan
  step or the executor, so it was plan infrastructure filed under the
  command tree, and its name said only that it did several things. Its
  Crossplane half (connection secrets, kubeconfig sync, the paused-toggle
  reconcile) is `crossplane/`; image publishing is `images/`; importing the
  lab CA into a cluster is `host/pki.rs`, alongside `host/state.rs` moved
  out of `commands/lab/`; stripping finalizers off terminating namespaces is
  `io::kubectl`, which is what it always was.

  `apply_cluster_components` went with it. It was a wrapper that printed one
  line and forwarded to `apply`, through a `ClusterComponents` struct
  identical in shape to the `ApplyRequest` it built, so the two callers now
  call `apply` directly.

  The nineteen subprocesses those parts ran are now issued through
  `io::process`, so they carry the lab CA in their environment and appear
  under `--verbose` like every other command the CLI runs. One of them,
  `crane push`, already called `io::trust::apply` by hand, which is the sort
  of local patch that stops being needed once the seam is used.

- **The evaluated lab is parsed as a total type, and the CLI supplies no
  defaults for it.** `LabSpec` and `ClusterSpec` now model every field
  `lab.out.cliConfig` emits, each required except the three Nix genuinely
  emits as null (`dnsInfo`, `registryPort`, `opsToolPath`). A field that
  does not parse is an error naming the field rather than a value the CLI
  invents, which is what the interpreter split already claimed: the
  definition is in Nix, the actions are in Rust.

  Thirty-odd `unwrap_or` fallbacks came out with it, each a second copy of a
  module-system default. Six for `cd.strategy`, plus the colima sizes, the
  k3d flags, both provisioner cluster names, `controlPlanes` / `workers`,
  and the DNS host, port and zone. Two had already drifted apart from the
  Nix they duplicated: the talos branch defaulted `workers` to 1 where k3d
  defaulted it to 0, and `lab dns` fell back to port 5353 while the constant
  deciding whether labs share one resolver drop-in was 5354, so a lab that
  omitted the port quietly got a per-zone file. A third was never a legal
  value at all: `cd.bootstrap` fell back to `"kapp"`, which its own enum
  (`kubectl-ssa | helm | none`) does not permit.

  `ProvisionerKind` now matches `cluster.provisioner` exactly. It carried a
  `Capi` variant Nix never emits, lacked the `external` Nix does, and mapped
  anything unrecognised to `Unknown`, so an external cluster matched neither
  arm of any decision made on it.

- **One kube-context resolver, and it does not guess.** Five had drifted:
  `apply`, `diagnose`, `kubeconfig`, `cluster` and the shared one in
  `lab/state.rs`, each with a different fallback chain ending in a name the
  CLI made up, such as `k3d-catallaxy-<cluster>`. They now share one lookup
  against `runtimeContexts`, which the planner populates for every cluster
  and whose own option documentation says callers should prefer it over
  `cluster.ref.kubeContext` precisely because the baked context goes stale
  after a pivot. A cluster with no entry is an error naming the clusters
  that have one, rather than a guess that fails later against the wrong
  cluster.

- **The plan executor works from typed values end to end.** `StepContext`
  carries a `LabSpec` rather than raw JSON, so the step implementations read
  fields instead of digging with `pointer()`, and `cata lab plan` reads
  `deploymentPlan` / `teardownPlan` off the type rather than by string key.
  Two models of the same JSON went away with it: `LabSecrets` merged into
  the `SecretsSpec` that already described those fields, and `io::ssa` now
  takes the cluster, lab name and secrets it needs rather than a cluster
  config with the lab's secrets grafted onto it.

  The command layer followed: `diagnose`, `lab status`, `lab topology` and
  `cluster` read the lab through the same type, so the JSON-shaped accessor
  that existed only for them is gone and `runtimeContexts` has exactly one
  reader. `pointer()` calls across the crate went from 68 to 26, none of
  them now in the plan or the domain.

  `ApplyArgs` split into the flags a user types and an `ApplyRequest` an
  internal caller passes. It had been both at once, four clap arguments
  beside four `#[arg(skip)]` fields, which clippy noticed only once a
  `LabSpec` in one of them made the top-level command enum large. The
  request borrows what it needs, so applying a lab no longer clones the
  whole lab once per cluster.

- **`nix develop` no longer builds the CLI to open.** The default shell
  listed `packages.cataWrapped`, so entering it built `cata` first. When the
  CLI did not compile you could not get into the shell that carries the
  cargo you need to fix it, which is the one moment you need it. The shell
  also shipped a `cata` built from the last good tree next to the source you
  were editing, so running `cata` after a change silently ran the old
  binary.

  The dev shell now offers `cata-dev` only, which is `cargo run` against the
  working tree, and `nix run .#cata` remains for the released one. Lab
  shells are unchanged and still carry `cata`: `nix develop .#<lab>` runs
  `cata lab env` in its `shellHook` to trust the lab CA, so the binary has
  to be there.

- **A lab whose managed secrets live outside an `env` store is no longer
  e2e-eligible**, and `nix eval .#e2eLabs` says so in a sentence naming the
  secret, its store and the backend. A machine with no credentials cannot
  open a sops store, so claiming otherwise put the failure in the middle of
  a CI run instead of in the eligibility output. A lab with env-backed
  secrets and no `lab.secrets.envFile` is ineligible for the same reason:
  the values would have to arrive from somewhere the lab does not describe.

  The rule those two replace, "these hold material nothing can generate", is
  gone. A CA is generated material now, and every other case it caught was a
  secret in a sops store, which the first rule already names. `mesh.local`
  is down from three reasons to two, and the one that remains is its
  interactive netbird join.

- **A projection whose store cannot be read is now an error.** It used to
  print a red line and carry on, so a deploy could report success with the
  Secret absent from the cluster.

- **`lab.secrets.managed.<n>.store` must name a declared store.** There was
  no assertion, so a typo silently fell back to sops behaviour. A downstream
  lab carrying one now fails eval, naming the stores that do exist.

- **`flake.nix` is 172 lines instead of 1097.** It had grown to hold every
  check inline, most of them the same eight-line `runCommand` wrapper around
  a list of failures, repeated thirty times. The flake now declares inputs
  and wires outputs together, and the bodies live under `nix/`: `checks/`
  split by subject, plus `treefmt.nix` and `devshell.nix`. Every flake
  output is unchanged, the same 62 checks by the same names.

  The 23 floe isolation checks stay an explicit list, the way floes and step
  kinds are registered rather than discovered. Two assertions keep the list
  honest in both directions: a test file in `lib/tests/floes/` that no check
  runs fails eval naming the file, and a registered name with no file fails
  eval naming the name. The registry stays the source of truth, without the
  failure mode a hand-maintained registry usually carries, which is a test
  that silently never runs.

## [0.7.0] - 2026-08-11

### Added

- **Floes assert their own correctness, and `cata lab verify` runs it.** A
  floe declares Chainsaw assertions at `floes.<n>.verify.<check>`, beside
  the `readyProbe` it already writes, and every lab enabling that floe
  inherits them. argocd asserts its Applications reached Synced and Healthy,
  forgejo that its bootstrap Job succeeded, cert-manager that every
  ClusterIssuer is Ready, gateway that every Gateway was programmed.
  `gitops.local` declares none of those and gets all five, which is the
  point: coverage grows as floes are written rather than as example labs are
  hand-edited.

  The assertions are declared in Nix and rendered to a Chainsaw `Test` per
  cluster by `lib/render/chainsaw.nix`, alongside the kapp and argocd
  renderers, so they stay derived from the lab rather than hand-written
  beside it. `lab.verify.checks.<n>.command`, the shell dialect from the
  previous release, is removed: Chainsaw's own `script` and `command`
  operations are the escape hatch, so there is one vocabulary for declared
  checks rather than two.

  `expect` is Chainsaw's `assert` and means **at least one** matching
  resource, which is verified behaviour and not what most checks want.
  `reject` is `error`, and is how "every one of these is fine" is said:
  assert that none of them is not fine. `verifyTypes.conditionIsNot` and
  `fieldIsNot` build those expressions, because JMESPath's `|` binds looser
  than `&&` and the obvious spelling parses as a pipeline that quietly
  evaluates to nonsense.

  Verify is read-only by construction: the rendered tests pin a namespace
  and set `skipDelete`, and an eval-time assertion refuses any operation
  other than `assert` and `error`, so running it against a lab you care
  about is never a question you have to think about.

- **`cata lab verify` checks a lab that is running.** `lab lint` reads
  rendered manifests and needs no cluster; verify reads live state. It asks
  every cluster whether its apiserver answers, every host service whether
  its ready probe passes, every workload in a lab-owned namespace whether it
  rolled out, and every hostname the lab routes whether it answers. A lab
  adds its own with `lab.verify.checks.<n>`, in the same shape as
  `lab.lint.checks`. `--json` for a caller, `--check` for one at a time,
  non-zero exit on an error diagnostic.

  The endpoint probe is the part nothing else covers: it goes out through
  the lab's ingress, gets routed by hostname, and comes back through a
  workload over TLS signed by the lab's CA. The host list comes from the
  `HTTPRoute` and `TLSRoute` resources the bundles declare
  (`cluster.out.exposedHosts`), not from each floe's `domain`, which misses
  `minimal.local` entirely because its only route belongs to a custom app.
  Internal-tier hosts are mesh-only and are skipped rather than failed.

- **End-to-end CI.** `.github/workflows/e2e.yml` stands a lab up on a
  runner, verifies it, tears it down and asserts nothing survived.
  `minimal.local` and the new `gitops.local` run on every pull request;
  `homelab.local` and `homelab.gitops-local` run nightly and on demand.

  Which labs it _can_ run is derived rather than listed.
  `lab.out.selfContained` says whether a lab needs anything CI cannot
  supply, and why not when it does, so a lab that grows a cloud cluster or
  an ungeneratable secret leaves the matrix on its own. Which of those run
  on a pull request is `PULL_REQUEST_LABS` in the workflow, stated once next
  to the triggers.

  The cost is managed rather than assumed. The lab's zot registry volume is
  cached per lab and keyed on its `images.txt`, which turns `warm-cache`
  into digest-present no-ops and takes the full run off Docker Hub's
  anonymous pull limit. The full run reclaims runner disk first, every job
  carries a timeout, and each writes its own timings and cache size into the
  run summary.

- **`gitops.local`, the smallest lab that does gitops.** One k3d cluster
  with cert-manager, a gateway, cnpg, Forgejo, ArgoCD and one app. It
  reaches `bootstrap-argocd-kubectl-ssa`, `bootstrap-forgejo-repos`,
  `publish-manifests` and `apply-root-application` with 12 container images;
  `homelab.gitops-local` reaches the same four with 39, because it is also
  carrying observability, a registry, backups and identity.

- **`nix run .#e2e -- <lab>`** runs the whole cycle: generate any secret
  store the plan needs, up, verify, up again to prove that changes nothing,
  destroy, and assert nothing survived. CI runs the same script, so the two
  cannot drift. With no argument it lists the labs it can stand up and the
  reason for each one it cannot. It refuses to start when another lab is
  already running, because the host services take fixed container names and
  ports.

- **`cata lab status --json`**, so a caller can assert on lab state instead
  of grepping a table.

- **`gitops.local` covers the secrets path.** A managed secret whose key is
  generated, projected into a cluster namespace, and read by a `run-script`
  preflight through `params.env`, with a verify check asserting the
  projected Secret landed. That covers `ensure-secrets`, key generation,
  `secrets.projections`, `run-script` and its `env` injection, taking the
  per-pull-request tier from 18 of 31 step kinds to 20.

### Removed

- **The `homelab.cloud` example lab.** It described DOKS clusters
  provisioned through Crossplane with Cloudflare DNS and ACME certificates,
  and nobody could run it without a DigitalOcean account, a Cloudflare zone
  and two API tokens. An example nothing in CI stands up and few readers can
  try is documentation with an eval check attached, so it is gone until
  there is an account behind it. `examples/labs/homelab/clusters/mgmt.nix`
  went with it, having no other user. The pivot chain it illustrated is
  described in the book under Understanding → Pivot, and the `crossplane`
  floe and every cloud step kind are unchanged.

- **`apply_gitops`, an unreachable stub in `cata lab apply`.** It was routed
  to for the `argocd` and `fleet` deploy strategies, printed what it would
  have done and returned success without doing it. It was also dead: the
  guard above it already refuses those strategies unless `--force` is
  passed, and `--force` applies through kapp, so nothing ever reached the
  stub. Both strategies now share that one refusal, which points at
  `cata lab publish`, where the git handoff is actually implemented.

### Fixed

- **`remove-network` no longer tears down host DNS on the side.** It did
  both, so a step named for one thing quietly did another, which is why the
  teardown asymmetry was invisible: `lab up` wrote a resolver drop-in from
  `dns-setup` and `lab destroy` removed it from a step called "remove lab
  Docker network". The DNS half is now the `dns-teardown` step, emitted only
  when `lab.dns.configureHost` put something there to remove.

- **`cata lab up --dry-run` no longer changes anything.** It created k3d
  clusters and executed hook binaries. `run_one` never gated on `dry_run`
  before dispatching; it only forced `attempts = 1` and skipped the
  reachability probe, and 14 of 31 handlers had no `dry_run` check at all,
  including `create-cluster` (which took no `dry_run` parameter) and
  `run-script` (which spawned unconditionally).

  The gate now lives in one place, and the default is inverted: a step is
  skipped unless its kind declares itself read-only, rather than executed
  unless the handler remembered to check. Only `wait-for-resources`,
  `wait-for-cluster-gone` and `verify-argocd-reachable` are read-only. The
  match is exhaustive, so a new kind has to decide.

### Changed, breaking

- **The e2e eligibility predicate names what it cannot create.**
  `lab.out.selfContained` rejected a lab for having any sops store, which
  conflated a store holding a pasted-in API token with one holding values
  the CLI generates. It now rejects only the material nothing can generate:
  a secret of `kind = "ca"`, which an ops command mints, or a key with no
  `generator`, which somebody types in. The reason names the secret and the
  key rather than the store.

  No verdict changed, which is the point: `mesh.local` still fails on
  `lab-ca` and its interactive step. What it unblocks is covering the
  secrets path in a lab that was already eligible.

- **`lab up` no longer edits anything outside the lab.** Pointing this
  machine's resolver at the lab's DNS is now `lab.dns.configureHost`, off by
  default, the way `lab.trust.installIntoHostStore` already was and for the
  same reason: it needs `sudo` and it writes configuration outside the lab,
  which is a poor default for a command whose job is to be reversible.

  `cata lab dns --setup` is unchanged for a one-off, and a lab you live in
  sets the option. Labs that do gain a `dns-teardown` step, so `lab destroy`
  removes what `lab up` wrote instead of leaving the resolver pointed at a
  nameserver that is no longer running.

  Nothing needs it to reach the lab. `cata lab verify` pins each hostname to
  the proxy's published address, and by hand it is
  `curl --resolve <host>:80:127.0.0.1`.

  Of the examples, `minimal.local` and `gitops.local` leave it off, so a
  full stand-up touches nothing but docker. `homelab.*` and `mesh.local`
  turn it on, which is what they mean.

- **`reference/step-kinds.md` is generated from the registry.** It was a
  hand-maintained table of every kind's required and optional param names,
  which is exactly the thing that goes stale: it still described an
  `idempotency` field that no longer existed, and listed `lifecycleName` as
  a `run-script` param after the field had moved. The page is now rendered
  from `modules/lab/planner/kinds/` into the book at build time, alongside
  the option pages, so each kind's params, types, defaults and descriptions
  come from the one place that defines them.

- **The planner knows about clusters and hosts, not about individual
  floes.** `lib/eval/` had grown DigitalOcean CRD names, a Crossplane
  external-name discoverer,
  `floes.crossplane.digitalocean.kubernetesClusters`,
  `floes.cluster-api.clusters`, `floes.harbor.domain`, `floes.argocd.enable`
  and `floes.forgejo.bootstrap.enable`. Every one of them was the planner
  reading a floe's private configuration, which is the thing floes are
  forbidden from doing to each other.

  Two new per-cluster capabilities replace the reads:

  `cluster.provisions` is keyed by the lab cluster this one brings into
  existence, and carries what the teardown needs to delete it:
  `resourceKind`, `resourceName`, `externalNameDiscoveryBin`. The crossplane
  floe fills in the DOKS values; the cluster-api floe declares its clusters
  with no `resourceKind`, since it tears them down with its own script. The
  planner derives the bootstrap chain (kubeconfig sync, self-provisioning,
  pivot) and the cloud teardown shape from that alone.

  This fixes a latent bug: `cloudDestroyFor` ran over every provisioning
  cluster and hardcoded the DigitalOcean CRD, so a cluster-api lab would
  have been handed `delete-managed-resource` steps naming a kind it does not
  have.

  `cluster.registryDomains` is what a registry floe publishes and what
  `publish-images` routes on. harbor and zot both set it; before, only
  harbor's `domain` was consulted, so a zot-hosted registry never matched.

  `floes.crossplane.externalNameDiscoverers` is removed. Its only remaining
  reader was the lab package's symlink farm, which now walks
  `cluster.provisions`.

- **argocd and forgejo emit their own plan steps.** The four
  `bootstrap-argocd-*` / `verify-argocd-reachable` variants and
  `apply-root-application` move to the argocd floe, and
  `bootstrap-forgejo-repos` to forgejo's. `deployment-plan.nix` no longer
  branches on `lab.cd.bootstrap` or asks whether a floe is enabled.

  `publish-manifests` stays in the framework, since pushing to the gitops
  repo is `lab.cd`, but it orders itself on a new lab-scope `lab/git-ready`
  token that any bootstrap publishes, rather than enumerating the clusters
  that have argocd. It is now emitted whenever `lab.cd.git.repo` is set,
  which is the condition its handler actually requires.

  Step names change: a step a cluster declares is keyed `<cluster>-<name>`,
  so `bootstrap-argocd-core` is now `core-bootstrap-argocd`. Plan order,
  kinds and params are identical across all ten example snapshots.

- **A malformed `lab.network.dockerSubnet` fails eval.** `gatewayOf`
  silently returned `172.19.0.1` for anything that was not a dotted quad, so
  a typo in one lab's subnet produced a docker network on another lab's
  gateway.

- **A floe's `steps` are typed in isolation checks too.**
  `lib/floe/eval-floe.nix` declared them `attrsOf attrs`, so a floe's own
  check could not catch what the real evaluation would reject.

- **`lab.clusters.<c>.lifecycle.preDeploy` is removed.** It was a second way
  to declare a `run-script` step, with its own `name`, `description`, `bin`
  and `env`, ordered against its siblings by an integer `order` field. That
  ordinal was the last phase-like ordering left in the system, and it could
  not express anything the graph could not: the emitter turned each hook
  into a `run-script` step publishing `lab/preflight-ok` anyway.

  A preflight is now a step like any other, so it can also anchor on
  something, which `order` never let it do:

  ```nix
  steps.validate-doks-versions = {
    kind = "run-script";
    direction = "deploy";
    provides = [ t.lab.preflightOk ];
    before = t.wantsAll [ t.lab.secrets t.lab.services ];
    params = { bin = "${validator}/bin/validate"; env = [ ... ]; };
  };
  ```

  `lifecycle.preProvision` is unrelated and stays: it runs inside
  provisioning, not as a plan step.

- **A bare step name is no longer an anchor.** `after` / `before` take
  `provides:<token>`, `kind:<kind>`, `kind:<kind>:<cluster>` and the
  `optional:` form of each. The assertion that used to catch a step naming
  another module's step is gone, because the grammar no longer has a way to
  express it.

  The framework had been the worst offender: `optional:setup-services`,
  `optional:trust-bundle`, `optional:cert-generate`,
  `optional:create-cluster-<c>`, `optional:remove-services` and
  `optional:wait-cluster-gone-<c>` were exactly what it forbade labs from
  writing. Each is now the token the target already published.

- **`lib.planTokens` is the token vocabulary.** `t.lab.<name>` and
  `t.cluster <name>` carry the framework's own token strings, and `t.needs`
  / `t.wants` build the hard and soft anchor forms, so a typo is an eval
  error at the definition rather than an edge that silently never forms.

- **`host/lab-reachable` replaces enumerating the steps that dial the lab.**
  A lab whose endpoints only resolve once the operator joins a mesh used to
  have to list every step that touches one, in both directions:

  ```nix
  after  = [ "optional:ensure-secrets" "optional:setup-services" "optional:warm-cache"
             "optional:kind:bootstrap-argocd-kubectl-ssa" "optional:kind:bootstrap-argocd-helm"
             "optional:kind:verify-argocd-reachable" ];
  before = [ "optional:kind:publish-images" "optional:kind:publish-manifests"
             "optional:kind:bootstrap-forgejo-repos" "optional:kind:apply-root-application"
             "optional:kind:cross-cluster-secret-copy" ];
  ```

  That list is environment-sensitive by construction: a pivoting environment
  grows four steps the local one does not have, and the sort happily hoisted
  the hook into the gap, ahead of the cluster that was going to run the
  mesh. Whether a kind dials a lab endpoint from the host is a property of
  the kind, so it is now `dialsLabEndpoints` in the registry, and the
  planner derives the soft edge. The publisher writes
  `provides = [ t.lab.reachable ]` and nothing else.

  The kinds that bring the lab up are deliberately excluded: a step cannot
  both make the lab reachable and wait for it to be reachable.

- **A plan step is an envelope around typed params.**
  `lab.out.deploymentPlan` and `teardownPlan` stop being a flat record of
  every field any kind might want and become
  `{ name; origin; kind; description; cluster; policy; params; }`. The old
  `stepType` declared about forty five nullable options, so the module
  system materialised all of them on every step:
  `bootstrap=false ephemeral=false` appeared on all thirty one steps of a
  plan that has one `deploy-manifests`. `ephemeral` was read once, by the
  plan renderer, and was always false.

  `policy` collects what applies to any step regardless of kind, and each of
  its fields comes from somewhere it did not belong:

  | `policy` field           | Was                                                   |
  | ------------------------ | ----------------------------------------------------- |
  | `onFailure`              | `failurePolicy`, lowered to `continueOnFailure`       |
  | `interactive`            | `params.interactive` on `run-script` only             |
  | `skipIfClusterReachable` | `skipIfReachable`, both a top-level field and a param |
  | `retry`                  | a second table in `cli/src/domain/step_kind.rs`       |

  `skipIfReachable` was honoured for four kinds because the executor matched
  on those four variants; it is now policy the executor reads once, for any
  step. `retry` comes off the wire, so the Rust table that duplicated the
  registry is gone.

  The lowered step carries `name`, which it never did, so
  `params.lifecycleName` is deleted. Every `run-script` author had been
  writing it out by hand to duplicate the attr key, because that key was the
  one thing the plan did not ship.

  `scope` collapses from `{ cluster; lab; }` to `scope = "lab" | "cluster"`,
  and only exists on a cluster's `steps`, since a lab-scope step has no
  cluster to choose. The cluster fold fills in a separate `cluster` field,
  which is what `kind:<k>:<cluster>` anchors match and what a kind's
  `kubeContext` param now defaults from, for every kind rather than for
  `run-script` alone.

  `delete-managed-resource.kind` and `wait-for-cluster-gone.kind` are
  renamed to `resourceKind`: the wire format tags params with the step kind,
  so a param called `kind` overwrote the tag. A registry assertion now
  refuses the name.

  `cata lab plan --stable` renders the envelope, so plan snapshots name each
  step and show only the params and policy that depart from their defaults.
  All ten example snapshots keep the same steps in the same order.

- **The positional planner assertions are gone.**
  `modules/lab/planner/assertions.nix` re-derived ordering facts by
  comparing list indices in the already-lowered plan, and each of its five
  checks was either already a graph edge or is now a structural guarantee.
  `checkTeardownReleaseBeforeDelete` restated the
  `cluster/<t>/cloud-released` edge. `checkPostPivotKubeContext` and
  `checkBootstrapSkipIfReachable` demanded fields that the planner now
  derives rather than asks each emitter to remember. `checkStepUniqueness`
  restated attr-key uniqueness. The `<lab>-planner-assertions` flake checks
  go with it.

- **`lab.steps.<n>.idempotency` is removed.** It was mandatory, with no
  default, so every author had to write it; it was set at 38 sites; and
  `lowerStep` never emitted it. The CLI recomputed the retry class from a
  table keyed on the kind, and the two had already diverged: the framework
  asked for `idempotent` on a non-self `create-cluster` while the CLI
  classified it `OneShot`. Deleting it moves no value, which the untouched
  plan snapshots prove. Retry policy is runtime behaviour and now lives only
  where the retries happen.

  Whether a non-self `create-cluster` should be retried is a real question
  this change deliberately does not answer; it only stops the two sides
  disagreeing in writing.

- **`params` is typed by the kind that will read it.** Each kind is one file
  under `modules/lab/planner/kinds/`, declaring its params as real options
  with types, defaults and descriptions, alongside the directions it runs
  in, its idempotency class and whether it is dry-run safe.
  `lab.steps.<n>.params` takes its type from `lab.steps.<n>.kind`, so a
  misspelled field, a missing required one and a wrongly typed value are all
  module-system errors naming the exact option path.

  This replaces `modules/lab/planner/kinds.nix` and
  `modules/lab/planner/params.nix`, which recorded directions and param
  _names_ with no types, and the three planner assertions that read them.
  `params` was a free-form attrset, so a param meant for another kind used
  to be accepted by Nix, serialised, and then silently discarded by serde.

  It found one on its first run: `bootstrap-forgejo-repos` had been passing
  `waitTimeoutSeconds = 600`, which that step has no field for. The handler
  hardcodes 600, so the two agreed by coincidence and nobody noticed the
  value was inert. The declaration is gone; making that timeout configurable
  is a separate change.

  A kind that runs in more than one direction (`run-script`,
  `destroy-cluster`) now has to say which; the rest default from the
  registry.

  The registry and the CLI's `PlanStep` enum are held together by
  `checks.step-kinds-conformance` and the tests in
  `cli/src/domain/step_kind_conformance.rs`: the check regenerates
  `cli/tests/fixtures/step-kinds.json` from the Nix registry and diffs it,
  and the tests assert that every kind, every required param, every optional
  param, every idempotency class, every direction and every dry-run flag
  agrees with the Rust side. Six hand-maintained lists of kinds had nothing
  keeping them honest.

- **Framework plan steps order themselves by token, not by name.** Every
  hard ordering anchor in `lib/eval/deployment-plan.nix` and
  `teardown-plan.nix` was a step-name string literal; all 19 are now
  `provides:` tokens or a `kind:` anchor, and a new assertion rejects any
  step that anchors on a step another module declares. The message names the
  token to use instead, since the check knows what the target publishes.

  Two sites had been resolving the graph by hand:

  ```nix
  predecessor = if isSelfProvisioning c then "pivot-${c.name}" else "create-cluster-${c.name}";
  after = map (c: if forgejoBootstrapEnabled c
                  then "bootstrap-forgejo-${c.name}" else "bootstrap-argocd-${c.name}") …;
  ```

  Both are gone. `create-cluster` and `pivot` now both publish
  `cluster/<c>/reachable`; argocd and forgejo both publish
  `cluster/<c>/git-ready`; and the teardown steps that read a sibling
  emitter's key set use `optional:kind:destroy-cluster`. Plan snapshots are
  byte-identical across the whole migration, which is the proof the DAG
  computes the order it always did.

  Three out-of-framework anchors had to move with it, all found by the new
  assertion rather than by inspection: netbird's mesh-join step, the homelab
  lab's DNS check, and the mesh lab's cross-cluster secret copy.

- **The internal plan IR is no longer published as API.** `lab.out.*`, the
  JSON record handed to the CLI, and the lowered `stepType` behind it now
  carry `internal = true`, so `nixosOptionsDoc` filters them. `lab.md` drops
  from 285 options to 164 and from 124 undescribed entries to 18. Values are
  unchanged: all five example labs render byte-identical manifests.

  `internal` had been used exactly once in the whole tree, which is why 42%
  of the lab option page was a JSON record nobody sets.

- **`lib.floe.oidc` is removed.** OIDC scope-contract assertions move to
  `lib/contracts/oidc`, reached as a `contracts` module argument the way
  `k8sHelpers` already is, rather than through the floe framework's public
  API. `lib/floe/` is the mechanism for authoring floes; it should not also
  be where application-protocol helpers accumulate, or LDAP and SMTP
  contracts land there next.

  No deprecation alias. The helper was never IdP-agnostic in practice, since
  every one of its four callers reconstructed `grantedScopes` and
  `idpEnabled` from `config.floes.kanidm.exports` by hand, and its signature
  changes in the same release. An out-of-tree floe calling
  `lib.floe.oidc.mkScopeAssertion` takes `contracts.oidc.mkScopeAssertion`
  instead, which now arrives as a module argument and needs no flake input
  threaded into the floe module.

- **The OIDC client record is a shared type, and the identity provider is
  swappable.** `contracts.oidc.clientsType` is what kanidm's
  `exports.oauth2Clients` now is, and consumers take one of its values
  through a new `floes.<n>.oidc.client` option (`dashboard.oidc.client` on
  netbird) defaulting to kanidm's export. Assign any floe's equivalent
  export to run against a different provider: the default names kanidm, the
  type does not.

  This deletes a preamble that was byte-identical in grafana, forgejo, zot
  and harbor, in which each consumer rebuilt two facts the producer owns:

  ```nix
  idpClients = config.floes.kanidm.exports.oauth2Clients or { };
  idpDeclaresClient = builtins.hasAttr cfg.oidc.clientId idpClients;
  grantedScopes = if idpDeclaresClient then idpClients.${cfg.oidc.clientId}.grantedScopes else [ ];
  idpEnabled = cfg.oidc.enable && (peers.kanidm.identity != null) && idpDeclaresClient;
  ```

  `client == null` now answers the whole question, because
  `exports.oauth2Clients` is `{ }` when the provider is off, so the lookup
  is null whether nothing publishes clients or nothing publishes _this_
  client. That is strictly stronger than the conjunction it replaces, which
  passed when kanidm was enabled but had never declared the client, a state
  that previously surfaced only as a 404 at login. zot's and harbor's
  "requires floes.kanidm to be enabled" guards accordingly become "no
  identity provider publishes an OAuth2 client named `<id>`".

  Rendered manifests are unchanged across all five example labs; only those
  two guard messages in `metadata.json` differ.

- **`exports` is the floe API, and `peers` is how you read it.** `mkFloe`
  now injects a `peers` module argument holding every _other_ floe's
  `exports` and nothing else, so reaching into a peer's internals takes a
  deliberate `config.floes.<x>.<internal>` rather than being the path of
  least resistance. What a floe does not export, nothing may depend on;
  whether to publish a fact is the upstream floe's call.

  This came out of four deploy failures in two days that shared one shape, a
  consumer gated on predicate P where the producer was gated on P ∧ Q. The
  clearest case: forgejo and kanidm each reconstructed "does the lab CA
  bundle exist" by ANDing `floes.trust-manager.enable` with
  `floes.cert-manager.selfSignedCA.enable`, a predicate only cert-manager
  can compute, and got it wrong in both; every consumer of the bundle sat in
  `MountVolume.SetUp failed ... configmap "lab-ca-bundle" not found`.

- **Name-valued exports are now typed references carrying existence and
  ordering.** `floes.cert-manager.exports.caBundleConfigMap` / `caBundleKey`
  / `caBundleSecret` / `caBundleReadyProbe` collapse into `exports.caBundle`
  and `exports.caBundleSecret`, each `null` or a record of
  `{ name; key; readyToken; readyProbe; }` (shape in `lib/floe/refs.nix`,
  shared by producer and consumers).

  `null` means nothing will create it, so a consumer null-checks one value
  instead of deriving a second predicate. `readyToken` is the install-DAG
  edge, so mounting the bundle and ordering behind whatever produces it are
  one decision rather than two that can disagree.

  Consumer options follow:
  `floes.{harbor,zot,otel-collector,netbird} .tls.caBundleConfigMap` +
  `.caBundleKey` become `.tls.caBundle`,
  `floes.argocd.oidc.caBundleConfigMap` + `.caBundleKey` become
  `.oidc.caBundle`, and `floes.grafana.oidc.tlsCaBundleConfigMap` becomes
  `.oidc.tlsCaBundle`. Each defaults to cert-manager's reference, so a lab
  that took the default can delete its wiring: `homelab`'s three
  `if config.floes.cert-manager.selfSignedCA.enable then ... else null`
  blocks were that same half-right predicate, restated at lab level, and are
  gone.

- **Every producer floe now publishes a nullable capability**, and consumers
  ask that instead of reading a peer's `.enable`: `cert-manager.issuance`,
  `gateway.routing`, `kanidm.identity`, `kaniop.operator`, `cnpg.operator`,
  `loki.logIngest`, `prometheus.metrics`, `tempo.traceIngest`,
  `reloader.watching`, `trust-manager.bundleDistribution`.

  "Is cert-manager enabled" was always a proxy for "can I get a
  certificate", and only cert-manager can answer that; it is enabled and
  still issues nothing without an issuer, exactly as trust-manager is
  enabled and distributes nothing without a Bundle. 19 cross-floe reads of
  peer internals are gone; the remaining `config.floes.<x>.*` reads are
  floes reading themselves.

- **Capabilities carry the install-DAG tokens**, so consumers stop spelling
  peer token strings: 13 bundles hardcoded `"cert-manager/webhook/ready"`,
  10 `"gateway/public/ready"`. Use `refs.needs <cap> "<field>"` in
  `requires` and `refs.orderAfter` in `after` (`after` takes anchors, where
  a token needs a `provides:` prefix; the wrapper handles it). No
  capability, no edge: a hard anchor naming a token nothing provides fails
  eval, so the edge now appears exactly when there is something to wait for.
  This also retires most `optional:provides:` anchors, which were
  approximating the same thing.

- **kanidm exports `claimValues` and `scopeMapGroups`** per OAuth2 client.
  netbird was reading `floes.kanidm.oauth2Clients.<id>.claimMap`; kanidm's
  input options, not its interface, and re-implementing the flattening to
  validate its own group config.

- **`components` are now `floes`.**
  `modules/lab/cluster/components/<category>/<name>.nix` became
  `modules/lab/cluster/floes/<name>/{default.nix,options.nix}`, and
  `components.<n>.*` became `floes.<n>.*`. Only `components.oidc` and
  `components.pki-auth` remain in the old namespace.
- **A floe's `.ref` is now a typed `.exports` submodule.** Every field must
  declare a `default`, enforced by `checks.floe-exports-defaults`. Renamed
  from `provides` so that word means exactly one thing: the readiness tokens
  a _bundle_ publishes.
- **Phases no longer determine install order.** The phase compat shim is
  deleted. Ordering comes from the bundle DAG. Phases survive as an
  organizational label and the on-disk directory prefix.
- **`lab.cd.bootstrap` defaults to `kubectl-ssa`,** and `"kapp"` is removed
  from the enum: the planner has not supported it since the argocd rework,
  so the previous default threw on evaluation.
- **Removed `lab.crossClusterSecrets`.** Declare a `lab.steps.<n>` entry
  with `kind = "cross-cluster-secret-copy"`.
- **Removed `lab.lifecycle.deploy`.** Use `lab.steps.<n>` with
  `kind = "run-script"`.
- **Removed `cata lab init`** (use `cata lab up --up-to=create-cluster`),
  **`cata lab trust`** (use `cata lab ops -- trust <cmd>`), and
  **`cata kubeconfig sync`** (use `cata cluster kubeconfig sync`).
- **Removed `cata lab up --phase`, `--component`, `--force`**: all three
  were parsed and ignored.
- **`cata lab up` no longer touches the host trust store.** The
  `host-trust-install` step is replaced on the default path by
  `trust-bundle`, which writes a merged CA bundle (the host's public roots
  **plus** this lab's CA) to
  `~/.local/share/catallaxy/labs/<lab>/trust/bundle.crt` and hands it to
  every tool the CLI spawns via `SSL_CERT_FILE`, `CURL_CA_BUNDLE`,
  `GIT_SSL_CAINFO`, `REQUESTS_CA_BUNDLE`, `NIX_SSL_CERT_FILE` and
  `NODE_EXTRA_CA_CERTS`. Examples, demos and CI now come up with no `sudo`,
  no `update-ca-certificates`, and on NixOS no `nixos-rebuild`; that last
  one used to be a hard stop mid-`lab up`.

  Set `lab.trust.installIntoHostStore = true` to restore the old in-plan
  host installation, which is what a long-lived lab wants.

  `trust-bundle` keeps `provides = [ "host/trust" ]`, so anchors on the
  token are unaffected; anchors on the step _name_ need updating.

  **Platform split, stated plainly:** Go's `crypto/x509` on macOS reads the
  keychain and ignores `SSL_CERT_FILE`, so on a Mac this covers curl, git
  and other OpenSSL-based tools but **not** `crane` or `netbird`. Mac
  operators still want `cata lab ops -- trust setup` for those. Linux and
  NixOS are fully covered.

- **Removed `cluster.lifecycle.teardown`.** A floe declares cleanup as a
  `cluster.steps.<n>` entry with `direction = "teardown"`, in the same DSL
  as every other step, so it gets real `after` / `before` / `provides`
  instead of an `order` integer inside one opaque `teardown-hooks` step.
  Each hook is now its own visible, individually-named plan step. The
  `teardown-hooks` step kind and its CLI handler are gone with it.

  Note for anyone who set `waitTimeout` on a hook: **the CLI never read
  it.** It was declared, lowered into the cluster JSON, and ignored, so
  nothing changes by its removal.

- **netbird moves from 0.73.1 to 0.74.3.** `floes.netbird.version` now
  follows `floes.netbird.client.package`, which defaults to `pkgs.netbird`,
  and all four server image tags derive from that, so adopting the default
  moves management, signal, relay and the in-cluster agent together. All
  four tags were confirmed present on the registry before the switch. Pin
  `floes.netbird.version` (and a matching `client.package`) to stay put.
- **netbird's host-side login no longer manages netbird profiles.** Profiles
  existed to multiplex N labs through one shared daemon, and produced the
  `profile name ambiguous` failures that needed a two-pass drain to recover
  from: duplicate registrations accumulated on disk, `profile remove <name>`
  was itself ambiguous once two shared a name, and each retry added another.
  A per-lab daemon with an explicit `--config` has one profile by
  construction, so roughly 250 lines of that machinery are gone along with
  the failure mode. `netbird up` on NixOS also stops dead-ending: the daemon
  is a detached `service run`, not a systemd unit, so it no longer demands
  `services.netbird.enable` and a `nixos-rebuild` first.
- **Removed `cataCharts.netbird`**; the Jaconi chart, declared with a
  maintained `chartHash` and never referenced. The floe renders its own
  management/signal/relay manifests, and `netbird/default.nix` explains why
  that will not change. `cataCharts.netbird-operator` is untouched.

### Added

- **The generated option pages are navigable and linkable.** Each opens with
  an index table of every option on it, groups entries by prefix under `##`
  headings, and gives every option a stable anchor (`awaitRollout` becomes
  `#awaitrollout`), so prose can deep-link instead of restating a schema.
  Two options that would slugify to the same anchor fail the build rather
  than silently shadowing one another.

  `bundles.*` and `lab.steps.*` now get their own pages rather than sitting
  inside a 212-option wall, and the hand-written schema tables that existed
  because there was nowhere to link have gone: `reference/bundles.md` is now
  "Writing a Bundle" and carries only the judgement, and `step-kinds.md`
  drops its "Declaring a step" block.

- **`cata --help` is the source of the CLI reference.**
  `reference/cli/commands.md` is generated by walking the clap parser, so
  every command, positional, flag and default comes from the code that
  parses them. `reference/cli.md` keeps only what the parser cannot say: how
  the flake fragment works, why `down` is not `destroy`, `--up-to` taking a
  kind rather than a name, and the four ways to trust the lab CA. It went
  from 1525 words to roughly 700, and the command tables it used to restate
  by hand are gone.

- **`checks.option-descriptions`** diffs the set of options with no
  `description` against a committed baseline, so the list can only shrink. A
  new undescribed option fails the build naming it.

- **`checks.docs-option-links`** fails when prose links an option anchor the
  generator did not emit, and **`checks.docs-options-nav`** fails when
  SUMMARY links a generated page that does not exist. The book previously
  copied a hardcoded list of option pages, so a new page would have been
  spliced into the nav and silently rendered empty.

- **`ready-probe` lint rule**: resolves every bundle's `readyProbe` target
  against the rendered manifests. A probe naming an object nothing produces
  is not a fast failure: the executor blocks on `kubectl wait --for=create`
  for the probe's whole timeout and then fails the deploy, which is how
  `deployment/seaweedfs-master` (a StatefulSet) and
  `deployment/otel-collector` (the floe's name, not the chart's) each cost
  ten minutes before erroring.

  The rule reads `.wave-meta`, which the renderer already writes beside the
  YAML, and reuses the probe types from `cli/src/io/ssa.rs` rather than
  restating the DSL. It reports a target rendered under a different kind
  unconditionally, and a target missing entirely only when the bundle
  contains no CustomResource or Job that could mint it after apply, so
  prometheus-operator's StatefulSet and netbird's Job-minted Secrets do not
  trip it. Derived from the manifests; no list of blessed names.

- **`checks.floe-boundary`**: fails eval when a floe reads
  `config.floes.<other>.<anything-but-exports>`. The rule it enforces:
  exports is the API, and what a floe does not export, nothing may depend
  on. Reports the file, the path read, and what to do instead.

- **`checkStepPreconditions` planner assertion**: fails eval when a plan
  step is emitted whose handler validates static config at runtime.
  `publish-manifests` refuses to run without `lab.cd.git.repo`, a check its
  handler made _after_ an otherwise successful deploy.

- **`cata lab ops -- trust browser`**: trust the lab CA in your browsers
  with no sudo. Writes only user-owned stores: `~/.pki/nssdb` for the
  Chromium family and every Firefox profile's `cert9.db` (including snap and
  flatpak locations). `--firefox-profile <dir>` targets one profile and
  creates it if absent, so a demo can have a throwaway browser profile. This
  was previously buried inside `trust setup`, which also wants root for the
  system store and on NixOS exits non-zero, so the browser half, the one
  part needing no privileges, could not be run on its own.

  Chromium shares a single NSS database per user, so `--user-data-dir` does
  not isolate certificates; only Firefox's store is per profile.

- **`cata lab env <lab>`**: shell exports that give your own shell the lab's
  CA trust, with no host changes: `eval "$(cata lab env mesh.local)"`. Reads
  only the lab's state directory (no `nix eval`), so it is fast enough for a
  `shellHook` and works when the flake does not evaluate.
  `--shell fish|json`, `--unset`.
- **A dev shell per lab.** `nix develop '.#"mesh.local"'` gives that lab's
  CA trust, `CATALLAXY_LAB` / `CATALLAXY_FLAKE` preset so a bare
  `cata lab up` knows which lab it is for, and the host-side tools its floes
  pin; netbird's per-lab client is the first. Built by
  `legacyPackages.mkLabShell`, wired into this flake, `examples/labs`, and
  the consumer template. Floes contribute via `cluster.shell.packages`.
  (Quotes required: lab names contain dots, which nix reads as attribute
  separators.)
- **`cluster.steps.<n>`: floes declare plan steps.** `lab.steps`' own
  docstring already said floes contribute entries there, but none could,
  inside a cluster submodule `config` is the cluster, so `lab.steps` was
  unreachable. Floes had two fixed-anchor hook lists instead, and anything
  needing its own `provides` token had to be hand-written into every
  consuming lab. A cluster-scope `steps` option of the identical
  `declaredStepType` is folded into `lab.steps` as `<cluster>-<name>`, with
  `scope.cluster` defaulted and collisions asserted.
- **`floes.netbird` declares its own mesh join / leave steps**, so a lab
  that enables the floe no longer hand-writes a netbird-named `run-script`
  step to get the operator onto the mesh. `mesh.local` lost 55 lines and
  every mention of netbird from its step list. The join acts rather than
  instructs; it starts this lab's daemon and runs the SSO login, exiting
  immediately when already connected, which is only safe now that the binary
  and the daemon belong to the lab.
- **`cata lab ops -- netbird status`**, which asks _this lab's_ daemon. A
  bare `netbird status` answers about the operator's own.
- **`floes.netbird.client.*`: the lab supplies the operator's netbird.**
  `client.package` (default `pkgs.netbird`) plus its own `serviceName`,
  `interfaceName`, `wireguardPort`, `daemonAddr`, `configFile`, `logFile`,
  `pidFile`, `dnsResolverAddress` and `extraUpArgs`, all defaulted per lab
  off `lab.contextPrefix`, so this lab's daemon shares no namespace with the
  operator's personal netbird or with another lab's. The version-coupling
  arrow is reversed: a lab used to pin the host, and now the lab's own
  package pins the lab.
- **`floes.netbird.versionCheck`** and an eval-time assertion comparing the
  host client's version against the management image tag at major.minor. A
  skewed pair fails by hanging during registration with no error, so the
  check moved from a runtime preflight twenty minutes into `lab up` to a
  `nix eval` failure that names both options. A floating or digest-pinned
  management tag can't be compared, and emits a warning saying so instead of
  passing quietly.
- **`failurePolicy` on a declared step** (`fatal` | `continue`). `fatal`
  aborts the plan, which is right for a precondition; `continue` records the
  failure and carries on, which is what cleanup wants; one cluster's failed
  teardown should not strand the rest of the lab.
- **`run-script` steps get `KUBECONTEXT`** when cluster-scoped, resolved
  from `lab.out.runtimeContexts`, so a script on a self-provisioning cluster
  talks to the post-pivot context rather than the bootstrap the pivot
  destroyed. It also reports a missing store path the way the teardown
  handler used to, instead of a bare ENOENT.
- **`mkFloe`**: the floe primitive: identity, typed `exports`, `requires`
  (floe names, asserted at eval), `drift`, and an option surface split
  across `default.nix` and `options.nix`.
- **`evalFloe`**, evaluate one floe against a fixture cluster with stubbed
  upstreams. 18 in-tree isolation checks, plus `floe-hello` and
  `floe-consumer` proving the out-of-tree path.
- **The install DAG.** Bundles carry `after` / `requires` / `provides` /
  `readyProbe` / `includeInBootstrap` / `owner.{bootstrap,steady}`. Waves
  are computed. Structural auto-edges for Namespace→workload, CR→CRD,
  ExternalSecret→SecretStore.
- **`lab.steps`**, user-defined plan steps over 32 built-in kinds, with
  anchors, `direction`, `idempotency`, `scope` and `skipIfReachable`.
- **Plan and manifest snapshot testing**. `cata lab plan --stable`,
  `--from-file`, `--diff`, and `cata lab plan-manifests`.
- **`lab.policy.exposure.defaultTier`**: a lab-wide default every floe's
  `gateway.tier` inherits.
- **Drift declarations**. `floes.<n>.drift.expected` and `cluster.drift.*`,
  with `managedBy` preferred over `fields`.
- **Two-tier PKI**.
  `cata lab ops -- trust {init-ca,init-intermediate,setup,teardown,export}`,
  `lab.secrets.managed.<n>.kind = "ca"` and `hostPaths`.
- **`cert-manager.exports.internalIssuerRef`**, for `*.svc` names, which
  ACME cannot issue for.
- **`cluster.lifecycle.{preDeploy,preProvision,teardown}`** hooks.
- **`cata lab topology`** (`table|json|mermaid|dot`, `--live`).
- **New floes:** `harbor`, `reloader`.
- **`floes.netbird.management.enable`**, peer-only mode, for a cluster that
  joins an existing mesh and advertises its routes but runs no control
  plane. `operator.enable` follows it. netbird's `mkFloe` `requires` moved
  into conditional module-body assertions, since a peer needs neither an
  identity provider nor a gateway.
- **Planner assertions** as flake checks, post-pivot contexts, bootstrap
  `skipIfReachable`, release-before-delete, teardown contexts, step
  uniqueness.
- **`checks.docs`, `checks.docs-summary`, `checks.template-consumer`**: the
  book, its nav, and the scaffold now fail a PR rather than post-merge.
- **A ladder of example labs**. `minimal`, `homelab`, `mesh`, with plan
  snapshots for each.

### Changed

- **The example lab `homelab.prod` is now `homelab.cloud`, and
  `homelab.staging` is removed.** `staging` was `homelab.local`'s topology
  with `argocd.ha` and three otel gateway replicas; a settings delta, not a
  new thing the ladder demonstrated, and it cost a full k3d lab's worth of
  eval and two plan snapshots to say so. `cloud` names what the remaining
  lab actually shows: the Crossplane/DOKS bootstrap-and-pivot, as against
  the two all-k3d labs beside it.

  Rename your invocations (`cata --flake '.#homelab.cloud' …`), the SOPS
  `path_regex` in `.sops.yaml`, and any `secrets/homelab.prod/` directory,
  which the lab now looks for at `secrets/homelab.cloud/`. `homelab.cloud`
  keeps `172.25.0.0/16`, so `172.24.0.0/16` is now free for a new lab.

- **`cata lab destroy` no longer purges external-dns records for
  docker-provisioned clusters (k3d, talos).** What the purge protects is the
  _zone_, not the cluster, and a local lab's zone is the lab's own
  `catallaxy-dns` Knot container: `remove-services` removes it moments
  later, and the next `lab up` rewrites the zone file back to the Nix seed.
  Draining records that are about to be deleted along with their server cost
  60s per cluster; `homelab.local` teardown drops from six steps to four and
  finishes about two minutes sooner.

  A docker-provisioned cluster pointed at a zone that _does_ outlive the lab
  (k3d + Cloudflare) will now leak stale records. No example lab has that
  shape; if one appears, the gate has to key off the provider target rather
  than the cluster host.

- **The purge that does still run waits on external-dns instead of sleeping
  a fixed 60s.** It scrapes `external_dns_source_endpoints_total` and
  `external_dns_controller_last_sync_timestamp_seconds` through the
  apiserver proxy, returning as soon as a sync completes against the emptied
  cluster: seconds, given `triggerLoopOnEvent` defaults on. The deadline
  derives from `floes.external-dns.interval`; if metrics are unreachable it
  falls back to the old fixed wait.

### Fixed

- **`cata --help` describes every command and flag again.** The pass that
  removed comments from the codebase also removed clap's `///` doc comments,
  which were not commentary but the CLI's help text, leaving every
  subcommand and flag blank. Help text is now written as explicit
  `#[command(about)]` / `#[arg(help)]` attributes, so it is data rather than
  something a comment sweep can silently delete, and a unit test fails when
  any subcommand or argument has none.

  Three strings were wrong where the reference doc and the code disagreed,
  and the code won: `secrets encrypt --output` defaults to `<FILE>.enc.yaml`
  rather than stdout, and the positional on `secrets generate` /
  `secrets list` is resolved as a lab name despite being called `CLUSTER`.

- **`cata apply --sequential` is gone.** It was parsed, always passed as
  `false` by every internal caller, and never read.

- **`examples/labs/mesh` ships a demo page in each cluster.** The apps
  cluster served a one-line `http-echo` body reading "reachable only from
  the mesh", which is indistinguishable from an error page at a glance; it
  looks like a refusal rather than the success it is. Both clusters now
  serve a small static site naming the host, the cluster and the internal
  gateway that delivered it, so which half of the mesh answered is obvious.

  `ops.internal.mesh.test` on mgmt and `hello.internal.mesh.test` on apps
  exercise both netbird Networks and both router groups, rather than
  demonstrating one cluster and asserting the other works. A third,
  `welcome.mesh.test`, is public-tier in the apps cluster: it sits beside
  `hello` and differs only in tier, so the contrast is visible in one place
  , and it is the only thing exercising the host ingress into the apps
  cluster, which nothing covered before.

- **`netbird up` offered the OIDC provider exactly one loopback callback
  URL, so a browser login that succeeded had nowhere to land.** The PKCE
  callback listener binds the port named by the redirect URL, and netbird
  avoids collisions by walking `RedirectURLs` for the first free one
  (`client/internal/auth/pkce_flow.go:47-58`). The floe hardcoded a single
  `http://localhost:53000/`, which disabled that mechanism, and 53000 is
  netbird's own default; the port the operator's personal daemon holds
  during any login it attempts. Netbird also probes the port with a dial and
  binds it later, so a retry re-collides with the listener the previous
  attempt is still shutting down.

  Result on `mesh.local`: the daemon looped several times a second on
  `waiting for browser login failed: listen tcp :53000: bind: address already in use`
  while the operator completed the login in the browser successfully,
  repeatedly, with no callback listener to return to and no message saying
  so.

  `floes.netbird.client.callbackPorts` now names the candidate ports
  (default `[ 53010 53011 53012 53013 ]`, off netbird's default for the same
  reason `wireguardPort` is off 51820), and
  `floes.netbird.exports.oauthRedirectUrls` publishes the URLs built from
  them. The management config offers all of them and the IdP client
  registers all of them, both derived from that one export rather than
  restating the literal: `examples/labs/mesh` no longer spells
  `http://localhost:53000/` in its kanidm client.

- **A rejected netbird API call now fails the deploy instead of being
  discarded.** The provisioning Job used `curl -sf` throughout, which throws
  away the response body on 4xx, and logged `creating NetworkResource …`
  before knowing whether the call worked. A rejected create therefore
  produced a success-looking log line, an exit code of 0, and a half
  provisioned mesh that `lab up` reported as fine.

  Mutating calls go through one helper that keeps the status and body, and
  prints netbird's own message on failure,
  `resource with name X already exists` is what was being thrown away. Calls
  that are genuinely best-effort, such as deleting a policy that may already
  be gone, say so explicitly rather than sharing the silent path. Logging
  happens after the call, not before.

  The Job also reads its resources back before configuring policies and
  fails if any it was asked to provision is absent, so "provisioned" means
  "checked present" rather than "no error was noticed".

  And the bundle now waits for those Jobs to reach `condition=complete` and
  publishes `netbird/routing/ready`. Previously it applied them and moved
  on, so a routing Job could fail on every attempt while `cata lab up`
  reported the whole deploy successful and the mesh had no policies or
  nameserver at all.

- **`floes.netbird.routing` now declares Networks, not one Network.**
  `routing.networks.<name> = { routerGroup; resources; }` replaces the
  `networkName` / `routerGroup` / `resources` scalars, and the provisioning
  Job and its reconcile CronJob are emitted per network.

  Resource names are namespaced with the network name, because netbird's
  uniqueness check is `AccountID + Name` and ignores the network
  (`networks/resources/manager.go:113`). Two networks each holding an
  `internal-gateway` silently lost one of them: the second create is
  rejected and the provisioning Job's `curl -sf` swallows it, so the address
  simply had no route and the name did not resolve.

  This is forced by netbird's model rather than a preference: see below. A
  lab routing resources in more than one cluster declares one Network per
  cluster, each with a router group its own agent joins, which needs a setup
  key per cluster since the key's `autoGroups` is what places a peer in the
  group. `examples/labs/mesh` does exactly that: `routers-mgmt` and
  `routers-apps`, fed by `cluster-router-mgmt` and `cluster-router-apps`.

- **A netbird Network's resources must all be reachable from its routing
  peers.** Routing peers are redundant paths to the same resource set; the
  docs describe assigning several "for high availability", and equal metrics
  "balance traffic by latency", which
  `NetworkResource.ToRoute(peer, router)` implements by emitting one route
  per resource-and-router pair under a shared `NetID`. Putting two clusters'
  resources in one Network with both cluster agents in one router group
  therefore load-balances traffic across a router that can reach the target
  and one that cannot, which presents as flaky rather than broken.

  Both clusters are routed, each by its own agent, so mgmt-side services get
  mesh-only access on the same terms as apps-side ones.

- **Joining the mesh took every public lab name down with it.** netbird was
  pushed the whole lab zone (`dnsDomains = [ dns.zone … ]`), so a joined
  peer got `Domains=~mesh.test` on the netbird link. That is more specific
  than catallaxy's own `~test` resolved drop-in, so netbird won the entire
  zone and forwarded it to cluster CoreDNS: leaving `idm.mesh.test` NXDOMAIN
  on the host the moment you joined.

  The two tiers need different answers for the same name: the host ingress
  for public names, the internal gateway ClusterIP for mesh-only ones. New
  `lab.dns.internalZone` (default `internal.<zone>`) gives them separate
  suffixes, and netbird is pushed only that. Resolvers prefer the most
  specific routing domain, so `idm.mesh.test` and `hello.internal.mesh.test`
  now both resolve at the same time. A name _prefix_ cannot do this,
  resolvers match suffixes, never prefixes.

  **The gateway owns that zone and publishes it.** It owns the internal tier
  it creates the internal Gateway and ClusterIP, and floes register
  `internalHostnames` with it, so `floes.gateway.internal.domain` is the one
  place it is stated, surfaced as `exports.internalDomain`. Consumers derive
  rather than restate: `floes.netbird.routing.dnsDomains` defaults to that
  zone plus `svc.cluster.local`, and CoreDNS reads the same export.
  `routing.resolverIP` likewise derives from the cluster's service CIDR
  instead of being hand-computed per lab. `examples/labs/mesh` now names no
  DNS domain and no resolver IP at all; a lab restating the zone into
  netbird was how the two could disagree in the first place.

  **The lab's wildcard no longer swallows the internal tier.** Knot serves
  `* IN A <ingress>` so every host-facing name resolves, and a DNS wildcard
  matches at any depth (RFC 4592), so `*.<zone>` answered for
  `svc.internal.<zone>` too, handing back the ingress address for a name
  only the mesh can reach. Off the mesh that turned a clean NXDOMAIN into a
  503 from a gateway with no such route; on it, the wrong answer masked the
  mesh one. The zone now carries a node at the internal label, which makes
  it a closer encloser and stops wildcard synthesis below it.

  **The internal zone spans the lab, so every cluster's CoreDNS answers for
  all of it.** A mesh peer is handed one resolver; the management cluster's
  , and a name registered in another cluster NXDOMAIN'd there, which left
  the mesh demo's one internal service unreachable over the mesh it was
  demonstrating. Each name keeps its owning cluster's internal gateway
  address, which every mesh peer can route to because the router agents
  advertise those service CIDRs.

  Follows through to `coredns-internal.nix` (one server block per zone,
  internal hostnames only under the internal one), the gateway wildcard
  certificate (`*.<zone>` matches a single label, so `*.internal.<zone>` is
  a separate SAN), and `lab.proxy`, which no longer publishes internal-tier
  services at the host edge at all; it had no tier filter, so an internal
  service got a Host ACL that forwarded to the public Gateway and 404'd.

- **A netbird agent with an https management URL and no CA bundle is now an
  eval error.** `floes.netbird.tls.caBundle` defaults to cert-manager's
  export, which is null unless trust-manager runs in that cluster, and every
  consumer treats null as "opt out". `examples/labs/mesh/clusters/apps.nix`
  enabled cert-manager without trust-manager, so the router agent mounted no
  CA, failed TLS to `https://nb.mesh.test` with `certificate verify failed`,
  never registered, and left the mesh with no router peer: silently. The lab
  CA itself was always correct: `import_lab_ca` seeds the one root into
  every cluster, so cluster issuers already chain to it.

- **`lab destroy` left the netbird daemon running whenever the daemon was
  already unhealthy.** `netbird-mesh-leave` released the profile before
  stopping the daemon, and the profile-release pipeline carried no
  `|| true`. Under `set -euo pipefail` a wedged or already-gone daemon made
  `netbird profile list` fail, the pipeline failed, the script aborted, and
  the daemon stop, interface delete and state-dir removal never ran. The
  step is `continueOnFailure`, so teardown reported success and the next
  `lab up` stacked another daemon on top.

  The calls were also unbounded, and `netbird`'s CLI is known to hang
  against a wedged daemon, which stranded teardown the same way.

  Every best-effort call is now time-bounded and cannot abort the step, so
  stopping the daemon is always reached. Removing the daemon is what
  teardown is for; releasing the profile first is a courtesy that must never
  prevent it.

- **A cold daemon no longer prints a failure the operator should ignore.**
  `netbird up` gives the engine ~50s and a freshly started daemon needs ~60s
  for its signal channel, so it printed
  `daemon up failed: … DeadlineExceeded` on a join that then succeeded
  seconds later.

  `up`'s stderr is now captured and replayed only when the join really
  fails, so nothing is judged by matching on message text and nothing is
  lost; a genuine failure prints everything `up` said, verbatim, above the
  daemon log. The SSO URL is unaffected: netbird writes it to stdout.

- **The mesh join reported "Waiting for you to finish the browser login"
  long after the operator had finished it.** The callback lands in seconds,
  but `netbird up` then spends up to a minute or two registering the peer,
  dialing the relay and waiting for the engine, and the heartbeat claimed
  the operator was the holdup for that whole stretch. The obvious reading is
  that the login was not noticed, which sent this investigation down the
  wrong path more than once.

  The daemon logs the moment the callback lands, so the step now watches for
  it and switches to `Bringing the mesh up…` once the peer is registered,
  stating plainly that nothing further is needed.

- **The lab ingress closed every idle connection after 30 seconds, which
  broke netbird's control plane permanently.** `lab.proxy` generated HAProxy
  `timeout client 30s` / `timeout server 30s`, and a netbird signal stream
  is idle by design; a peer registers and then waits for connection
  candidates that may be minutes away. HAProxy tore the connection down
  every 30s, and because the close is orderly the client reported whatever
  it was waiting for rather than a timeout:
  `didn't receive a registration header from the Signal server`, once every
  30s, with the mesh never coming up.

  This is why the symptom survived fixing the signal route port and the
  `h2c` marking; both were real defects, but neither was this one. A
  standard gRPC client succeeded against the same endpoint at the same
  moment, because short-lived probes never crossed the boundary.

  New `lab.proxy.idleTimeout` (default `1h`) drives `timeout client`,
  `timeout server` and `timeout tunnel`. It bounds inactivity, not request
  duration, so it affects only how long a working idle stream may live, gRPC
  control planes, WebSockets, SSE and `kubectl logs -f` alike.

- **`cata lab up` automatically retried the interactive mesh join, which
  invalidated the login the operator was completing.** The executor retries
  any `Idempotent` step three times, and the join is genuinely idempotent,
  re-running it by hand is safe. But each attempt issues a fresh browser
  login URL, so an unattended retry defeats the step it is retrying.

  Steps now declare `interactive`, orthogonal to `idempotency`, and the
  executor runs them exactly once. A failed join asks the operator to re-run
  rather than racing them.

- **The mesh-join step re-issued SSO login URLs underneath the operator who
  was mid-login.** The netbird daemon keeps exactly one authorization flow
  (`s.oauthAuthFlow`, which `client/server/server.go:609` reads to derive
  the wait deadline), and each `netbird up` replaces it. The join script
  looped up to `NETBIRD_SSO_ATTEMPTS` (default 3) fresh `up` invocations, so
  a login the operator was part-way through could be superseded by the
  script itself. The observed signature: the browser shows netbird's success
  page: only rendered after a matching `state` and a completed code
  exchange: while the daemon reports
  `waiting for browser login failed: context deadline exceeded`, and
  management records no peer registration at all.

  There is now one login flow per run. Re-issuing never bought time: the
  window is a hardcoded `n = 300` in `client/internal/auth/pkce_flow.go` and
  cannot be extended, so a second URL only invalidated the first. On failure
  the step re-runs at the operator's discretion, with a fresh terminal.

- **A failed join now prints the daemon's own log.** The reason has always
  been in the journal and never on screen, so every diagnosis started by
  going to fetch it. `context deadline exceeded` (no callback reached the
  flow) and `PKCE authorization flow failed` (one reached it and failed) are
  different faults and are now distinguishable in place. New
  `floes.netbird.client.logLevel` (default `info`) raises the daemon to
  `debug`, which is what reports the callback port a flow bound and whether
  a request arrived.

- **`floes.netbird.sso.forcePrompt`** (default `false`) stops forcing
  re-authentication on every join. `pkce_flow.go:104-106` appends
  `prompt=login` unless `DisablePromptLogin` is set, and the floe hardcoded
  `DisablePromptLogin = false`, so a live IdP session was ignored and full
  credential entry, password manager and MFA included, had to fit inside the
  fixed 300s window before the callback could even be issued.

- **Removed a preflight check that could not fail.** `grep -c` exits
  non-zero on zero matches, so `disc_hit=$(… | grep -Eic … || echo 0)`
  produced the string `"0\n0"`, which never equalled `"0"`; the
  OIDC-discovery assertion printed `ok (0 hits)` through every failed join.
  It was also asserting the wrong thing: management is configured with
  `AuthKeysLocation`, so it does not perform discovery.

- **The signal Service's primary port was not marked `h2c`, so the gateway
  spoke HTTP/1.1 to a gRPC backend.** Signal's `grpc-compat` port carried
  `appProtocol = "kubernetes.io/h2c"` and the primary port did not, so
  routing to the primary port left agents unable to open the Signal Exchange
  stream: `didn't receive a registration header from the Signal server`,
  after a join that had otherwise fully succeeded. Management had the
  marking on its port 80 all along, which is why its gRPC worked. A test now
  asserts that the Service port each gRPC route targets is `h2c`, for
  management and signal alike.

- **`floes.netbird.exports.signalPort` advertised 10000, netbird's legacy
  bare-gRPC compat listener, rather than 80, the primary one.** Signal runs
  both: `--port 80` serves gRPC over HTTP with the WebSocket proxy, and
  because that port is not 10000 it also starts the old listener to hold up
  agents already connected on the previous default
  (`signal/cmd/run.go:154-157`). A consumer pairing the export with
  `signalHost` dialed the compatibility path for a new connection. The
  export is now 80, and its description says which listener is which.

  The signal ports are single bindings used by the container args, the
  container ports, the Service and the route, so the primary port cannot
  drift between what signal is told to serve and what is routed to it, which
  it had, the route having pointed at 10000 while signal served 80. The
  `grpc-compat` Service port stays.

- **`floes.cert-manager.exports.caBundleConfigMap` advertised
  `lab-ca-bundle` whenever the self-signed CA was on, but the Bundle CR that
  materialises that ConfigMap is only emitted when trust-manager is _also_
  on.** With self-signed CA + no trust-manager, every consumer defaulting
  off the export (netbird, harbor, zot, otel-collector, argocd) mounted a
  ConfigMap nobody creates and sat in
  `MountVolume.SetUp failed ... configmap "lab-ca-bundle" not found`. The
  export, and `caBundleSecret` / `caBundleReadyProbe`, now track the
  Bundle's own condition. `forgejo` and `kanidm` no longer fall back to the
  literal name when the export is null.
- **`floes.reloader.exports` fields had no defaults**, violating the rule
  `checks.floe-exports-defaults` exists to enforce; that check covers a
  hand-picked set of floes and never looked at reloader. Reading any of them
  on a cluster where reloader was off threw "option was accessed but has no
  value defined". `mkPatches` now defaults to the identity of "patch
  nothing", so a consumer can splice the call unconditionally.

- **The `reference` check is now an error, and carries no name lists.** It
  resolved mounts against `RUNTIME_MANAGED_RESOURCES = ["lab-ca-bundle"]`,
  the exact object whose absence caused the FailedMount: plus suffix
  matching on `-tls` / `-cert` and a hardcoded `argocd-redis`, all at
  `Warning`, among 27 other warnings. Every exemption is now read off the
  manifests or the lab:
  - the name is in `runtimeMaterialised` (cluster metadata, harvested from
    the mountable references floes export): some floe declared it exists;
  - a `Certificate` in that namespace declares it as `spec.secretName`, a
    cnpg `Cluster` named `X` implies `X-app`, a netbird `SetupKey` named `X`
    implies `setup-key-X`;
  - a Job or CronJob in the namespace can mint it (harbor's bootstrap
    Secrets, argocd's redis password);
  - a `cross-cluster-secret-copy` step delivers it (`copiedInSecrets`, new
    in cluster metadata); the same category as projections, since the CLI
    writes it at deploy time and no manifest scan can see it.

  All five example labs pass with zero reference errors.

- **`optional: true` is honoured on `envFrom` and `env[].valueFrom`.**
  Kubernetes starts a pod whose optional reference is missing; the check
  only honoured the flag on volumes, so seaweedfs's optional external-DB
  credentials (`secret-seaweedfs-db`) read as a broken reference.

- **No floe that mounted `lab-ca-bundle` declared a DAG edge to the bundle
  that creates it.** otel-collector had no `requires` at all, so it landed
  in an early wave: trust-manager is two waves later, and cert-manager's
  Bundle CR later still. Its gateway pod therefore mounted a ConfigMap that
  did not exist yet, and since an unresolvable volume keeps a pod out of
  `Running` entirely, the rollout wait never returned and the whole deploy
  stalled behind it (observed: 3h in `ContainerCreating`, nothing past that
  wave ever applied: including the trust-manager that would have created the
  ConfigMap). `otel-collector`, `harbor`, `zot`, `argocd`, `forgejo` and
  `netbird` now require `cert-manager/default-issuer/ready` whenever they
  mount the bundle.
- **Two `readyProbe`s named workloads that no chart ever creates**, so each
  spent its whole timeout in `kubectl wait --for=create` and then failed the
  deploy. seaweedfs probed `deployment/seaweedfs-master`: master, volume and
  filer are StatefulSets, and `seaweedfs-s3` is the chart's only Deployment;
  it now probes the S3 gateway its `seaweedfs/s3/ready` token actually
  promises. otel-collector probed `deployment/otel-collector`, the floe's
  name rather than the chart's `<release>-opentelemetry-collector`.
- **`publish-manifests` and `apply-root-application` were emitted for any
  lab with the argocd floe enabled, including labs that do no gitops at
  all.** With `lab.cd.git.repo` unset (its default), the publish step's own
  handler refuses to run ("requires lab.cd.git.repo to be set"), so a fully
  successful deploy failed on its last step. Both now require a configured
  repo. `homelab.{local,cloud}` install argocd without a manifests repo and
  lose both steps; a lab that wants the gitops handoff sets
  `lab.cd.git.repo` (and `lab.cd.argocd.repoUrl`), as `homelab.gitops-local`
  does.
- **`bootstrap-forgejo-repos` was emitted for every argocd-enabled cluster,
  including those whose forgejo never creates the Job it waits for.**
  `floes.forgejo.bootstrap.enable` defaults off, so the step polled a label
  selector nothing would ever match, burned its retries and failed the
  deploy with everything healthy. It is now emitted only when that toggle is
  on; `publish-manifests` and `apply-root-application` fall back to
  anchoring on `bootstrap-argocd-<cluster>`.

  Labs that do gitops through an in-cluster forgejo
  (`lab.cd.git.provider = "forgejo"`) want
  `floes.forgejo.bootstrap.enable = true`; without it nothing creates the
  manifests repo or the argocd repo-credential Secret, and
  `publish-manifests` pushes to a repo that does not exist.
  `homelab.gitops-local` now enables it, declares the
  `infrastructure/manifests` org + repo and argocd's deploy key, and points
  `lab.cd.argocd.repoUrl` at the in-cluster SSH Service the Job writes into
  that credential Secret. It pointed at the HTTPS gateway URL before, which
  argocd would never have matched to the Secret; it keys credentials on the
  exact URL string.

- `evalFloe`'s fixture cluster declared only `phases`, so any floe writing
  `lifecycle` / `ops` / `secrets` / `assertions` failed its isolation check.
- `checkStepUniqueness` keyed on six fields a `run-script` step leaves null,
  reporting a false duplicate for any plan with two script steps.
- `_module.args.lab` advertised `ingress`, an option that stopped existing
  when `lab.ingress` became `lab.proxy`.
- Lint checks that failed to _execute_ were counted as passing.
- Option-doc generation routed on a dead `components.` prefix, emitting
  twelve empty category pages and one enormous cluster page.
- `nix develop` did not put `cata` on `PATH`.
- `templates/consumer` did not evaluate.
- **`trust teardown` never removed anything from Firefox**, and its
  `runtimeInputs` was `nss` rather than `nss.tools`, so `certutil` was
  absent and even the Chromium-family removal silently no-opped behind its
  `|| true`. It now uses the right package and clears every store `browser`
  writes. On macOS it also deletes both keychain nicknames, since the CN
  differs between a locally-minted and a SOPS-minted CA.
- **`crane push` no longer replaces the root pool with the lab CA alone.**
  `publish-images` set `SSL_CERT_FILE` to the bare `proxy/ca.crt`, which
  _replaces_ rather than extends the trusted roots, so a push that touched
  anything public (a redirect to an external blob store, an auth challenge
  against a public IdP) had no roots left to verify it with. Verified: that
  file alone fails a plain `curl https://github.com`. It now uses the merged
  bundle.
- **`cata images mirror` had no lab CA trust at all**, so `crane copy` to a
  lab-zone registry only worked if the operator had installed the CA into
  their host store. It gets the bundle like every other spawned tool.
- **Host DNS setup no longer asks for a password on every lab cycle.** The
  systemd-resolved drop-in was written per zone and deleted again on
  teardown, so each `lab up` / `lab destroy` round trip re-elevated to
  rewrite a byte-identical file. Labs whose zone is under `.test` and whose
  resolver is the default `127.0.0.1:5354`, so every local lab now shares
  one `/etc/systemd/resolved.conf.d/catallaxy-test.conf` routing `~test`,
  installed once and left in place. Labs on another zone or port keep their
  own, more specific, drop-in, which still wins under systemd's
  longest-match rule. Setup also elevates once rather than three times.
- **`floes.custom` pinned its HTTPRoutes to the gateway's `https` listener**
  even in labs with `gateway.tls.enable = false`, where that listener does
  not exist. The route sat at `NoMatchingParent`, the gateway reported
  `attachedRoutes: 0`, and every request 404'd although both app and gateway
  were healthy. The section name now follows the new
  `floes.gateway.exports.terminatingListenerName`.
- **`provisioner.k3d.noServiceLB` now defaults to `false`.** Klipper is the
  only LoadBalancer implementation a stock k3d cluster has, so the previous
  `true` default left every LoadBalancer Service at `<pending>` with no
  events unless the lab remembered to opt out. The symptom appeared far from
  the cause: the gateway floe probes `.status.addresses`, which Traefik
  copies off its Service, so `lab up` blocked for the probe's full 10m and
  then failed. `minimal.local` hit exactly this.
- Every example lab inherited the same `lab.network.dockerSubnet` default
  (`172.19.0.0/16`), so bringing up a second one failed at
  `docker-network-create` with "Pool overlaps with other one on this address
  space". Each example now claims its own /16 (`172.20` – `172.25`), and the
  new `example-lab-subnets` flake check keeps them pairwise distinct.

### Documentation

- **`Floes` opens with a feature table against Helm charts.** The page
  argued the case one paragraph at a time, so the shape of the difference,
  templating, typing, an interface, ordering, readiness, guard rails,
  testing, distribution, only emerged after reading all of it. Ten rows say
  it at a glance, and a closing note that a floe wraps an upstream chart
  rather than replacing it.

- **The book is restructured into five sections, and cut back to four
  curated pages.** `Concepts`, `Floes`, `Guides` and `Contributing` are
  gone; `Understanding Catallaxy` is now `The Model` and `How It Works`, and
  `Using Catallaxy` is `Configure a Lab` and `Write a Floe`. `Start Here`
  and the generated `Reference` are unchanged in shape, and a single
  `Contributing` page moves under `Project`. Deleted pages remain in git
  history, to be restored individually when a topic earns a page of its own.
  The mesh case study moves to `examples/labs/mesh/README.md`.
- The book is rewritten around floes: new Concepts, Floes, and Guides
  sections, 34 new pages, and per-floe generated option references.
- `llms.txt` and `llms-full.txt` are generated from the book and published
  with it.

## [0.6.0] - 2026-06-05

### Added

- **ACME/Let's Encrypt TLS:** full support for public CA certificates via
  cert-manager DNS01 challenges with Cloudflare
- **External-DNS with Cloudflare:** auto-create DNS records in Cloudflare
  zones from Gateway HTTPRoutes
- **Bootstrap & pivot:** self-provisioning cluster detection in planner. K3d
  bootstrap → cloud migration via Crossplane or CAPI
- **Secrets cache:** SOPS decryption cached in memory across all cluster
  deployments during `lab up`
- **Projections in metadata:** `metadata.json` includes per-cluster
  projections and lab-level secrets for package-driven injection
- **Phase ordering assertions:** Nix validates projection phase ≤ component
  phase in the same namespace
- **`projection-ref` lint check:** validates secretKeyRef names match
  declared projections with correct phase/namespace
- **`image-pin` lint check:** warns on `:latest` tags, errors on missing
  digests when `requireDigest` enabled, checks registry allow-lists
- **Image management:** `lab.images.pins` for declarative image pinning with
  optional digest. `lab.images.allowedRegistries` policy
- **`cata images` command:** `list`, `mirror`, `prefetch` for managing
  container images with crane
- **Pod Security Standards:** `cluster.security.podSecurity` applies PSA
  labels to lab namespaces
- **Network Policies:** `cluster.security.networkPolicies` generates
  default-deny per namespace
- **Audit Logging:** `cluster.security.auditLogging` adds API server audit
  flags for k3d
- **Extensibility:** `lib.mkComponent` helper, `lib.phases` constants,
  `lib.mkNetworkPolicy` helper
- **Consumer flake template:**
  `nix flake init -t github:onepunch/catallaxy#consumer`
- **Custom lint checks:** `lab.lint.checks` for user-defined property checks
  as shell commands
- **Stuck deployment restart:** auto-restarts deployments in
  `ProgressDeadlineExceeded` before kapp deploy
- **`cata-dev` alias:** devShell script for running CLI from source via
  `cargo run`
- **`cata secrets edit` by name:** resolve store name to file path instead
  of requiring full path

### Changed

- **Lab-aware manifest builds:** `apply` builds from lab package when lab
  name available, fixing cluster name collisions across labs
- **Projection-only phases:** phases with secret projections but no
  manifests preserved in rendered output
- **SOPS stderr inherit:** `decrypt_sops_store` inherits stdin/stderr so
  YubiKey plugins can prompt for PIN
- **Store path fallback:** checks both `secrets/` and
  `examples/labs/secrets/` for SOPS files
- **Ops tool build:** `lab ops` builds lab package first to ensure ops tool
  exists in store
- **Ops context templating:** ops scripts use `cluster.ref.kubeContext`
  instead of hardcoded context names
- **CNPG storage class:** defaults to `null` (cluster default) instead of
  hardcoded `local-path`
- **Conditional CA bundles:** `lab-ca-bundle` only created with self-signed
  CA. ACME uses `wellKnownCACertificates: "System"`
- **Kanidm ACME refs:** internal service refs use public URL when ACME
  active
- **Loki caches disabled:** chunks and results cache disabled by default to
  reduce memory
- **Renamed `CROSS_PHASE_RESOURCES`** to `RUNTIME_MANAGED_RESOURCES`.
  Projection-aware reference check

### Fixed

- External-dns `domainFilters` for Cloudflare (must be zone name, not
  subdomain)
- Kanidm Certificate excluding internal SAN when ACME enabled
- Gateway TLS issuerRef using `defaultIssuerRef` instead of hardcoded
  `lab-ca`
- BackendTLSPolicy using `wellKnownCACertificates: "System"` when no custom
  CA bundle

### Documentation

- Extending guide: writing custom components, bundle type reference,
  consumer flake setup
- Security reference: PSA, network policies, audit logging
- Image management reference: pins, policy, lint check
- Lint reference: all built-in checks, custom check authoring, Nix
  assertions
- Secrets management recipe: SOPS setup, YubiKey workflow, per-environment
  keys
- Operational runbook: troubleshooting, backup/restore, scaling
- Example labs README: step-by-step cloud setup guide

## [0.5.0] - 2026-05-25

### Added

- Initial release
- Declarative Kubernetes platform management via Nix modules
- Lab → Cluster → Component → Phase → Bundle architecture
- Built-in components: cert-manager, Cilium, Traefik, Prometheus, Grafana,
  Loki, Tempo, OTEL, ArgoCD, Forgejo, Kanidm, Zot, Velero, CNPG, SeaweedFS
- Crossplane and CAPI provisioners for cloud cluster management
- SOPS integration with 3-layer model (stores, managed secrets, projections)
- GitOps strategy with ArgoCD publish and PR workflow
- Lab ops commands for day-2 operations
- `cata lab lint` with 7 built-in checks
- k3d, Talos, and external provisioner support
