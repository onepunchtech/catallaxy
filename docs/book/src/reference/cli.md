# CLI

`cata` evaluates your lab, renders manifests, and executes the plan.

Every command, flag and default is in [Commands](./cli/commands.md),
generated from the parser. This page is what the parser cannot tell you.

## The flake fragment

```bash
cata [--flake <REF>] [-v|--verbose] <COMMAND>
```

The fragment names the lab or cluster the command acts on, the same shape
`nix build .#foo` takes:

```bash
cata --flake .#<lab> lab up
cata --flake github:you/infra#prod lab plan
```

Commands that act on every lab take no fragment:

```bash
cata --flake . lab list
```

Every lab-scoped command also accepts the name positionally
(`cata --flake . lab up my-lab.local`), which is occasionally useful in a
script looping over several labs against one flake. The fragment form is
what the rest of these docs use.

The CLI resolves two flake attributes:

```
legacyPackages.<system>.labs.<lab-name>          the evaluated config
legacyPackages.<system>.labPackages.<lab-name>   the rendered manifests
```

See [Flake Outputs](./flake-outputs.md).

## `down` is not `destroy`

`lab down` stops things and keeps state, so `lab up` restarts them.
`lab destroy` runs the teardown plan and deletes cloud resources. For a
local k3d lab the difference is a few seconds; for a cloud lab it is a bill.

## `--up-to` takes a step kind

Not a step name:

```bash
cata --flake .#<lab> lab up --up-to=create-cluster
```

It stops after the **last** step of that kind, and an unknown kind is a hard
error rather than a silent no-op. The kinds are in
[Plan Step Kinds](./step-kinds.md).

## `lint` and `verify` are a pair

`lab lint` reads rendered manifests and needs no cluster. `lab verify` reads
a running lab: apiservers, host services, rollouts, and every hostname the
lab routes. Both exit non-zero on an error diagnostic and both take
`--json`. See [Lint Rules](./lint.md) and
[Verifying a Running Lab](./verify.md).

## Snapshotting a plan

`lab plan --stable` prints deterministic text: no colour, no emoji, no
descriptions, store hashes normalized. Each line is the step's kind, its
name, and whatever params and policy depart from their defaults.
`--from-file` reads plan JSON instead of evaluating, which is what makes the
snapshot checks runnable inside a Nix build sandbox, and `--diff` compares
against a baseline and exits non-zero on mismatch.

## `lab ops` passes everything through

```bash
cata --flake .#<lab> lab ops -- trust setup
cata --flake .#<lab> lab ops idm init-user lab-admin
```

Ops commands are declared by the floes a lab enables, so the set differs per
lab. Run `lab ops` with no sub-command to list what yours offers.

## Trusting the lab CA

| Where               | How                                                       | Privileges             |
| ------------------- | --------------------------------------------------------- | ---------------------- |
| Tools `cata` spawns | automatic (`trust-bundle` step)                           | none                   |
| Your shell          | `eval "$(cata lab env <lab>)"`, or the lab's dev shell    | none                   |
| Browsers            | `cata lab ops -- trust browser`                           | none                   |
| The whole machine   | `lab.trust.installIntoHostStore = true`, or `trust setup` | sudo / `nixos-rebuild` |

`trust browser` writes only user-owned stores: `~/.pki/nssdb` for the
Chromium family, and every Firefox profile's `cert9.db`. Note the asymmetry:
Chromium shares **one** NSS database per user, so `--user-data-dir` does not
isolate certificates, while Firefox's store is per profile.
`--firefox-profile <dir>` targets one profile and creates it if absent,
which gives a demo its own throwaway browser profile:

```bash
cata lab ops -- trust browser --firefox-profile /tmp/demo-profile
firefox --profile /tmp/demo-profile https://grafana.<zone>
```

Restart the browser afterwards; it reads the store at startup.
`trust teardown` removes the lab from every store it can find.

`lab env` gives your current shell the same CA trust the CLI hands the tools
it spawns, without touching your machine's trust store:

```bash
eval "$(cata lab env <lab>)"
curl https://grafana.<zone>          # trusted here
```

It reads only the lab's state directory, with no `nix eval`, so it is fast
enough for a `shellHook`, and works even when the flake does not evaluate.
Entering the lab's own dev shell does the same for you:

```bash
nix develop '.#"homelab.local"'      # quotes: lab names contain dots
```

The full picture is in [TLS and the Lab CA](../using/tls.md).

## `secrets` names a store, not a file

`secrets edit`, `decrypt` and `rotate` take a store name from
`lab.secrets.stores`, or a path to any encrypted file. See
[Secrets](../using/secrets.md).

## `generate` is a maintenance command

It regenerates the typed Kubernetes schemas committed under
`modules/lab/cluster/lib/kubernetes/generated/`. Run it after bumping a
chart whose CRDs changed.

## Removed commands

If you have older notes:

| Was                                       | Now                                   |
| ----------------------------------------- | ------------------------------------- |
| `cata lab init`                           | `cata lab up --up-to=create-cluster`  |
| `cata lab trust --setup`                  | `cata lab ops -- trust setup`         |
| `cata lab trust --teardown`               | `cata lab ops -- trust teardown`      |
| `cata lab trust --export`                 | `cata lab ops -- trust export`        |
| `cata kubeconfig sync`                    | `cata cluster kubeconfig sync`        |
| `cata lab up --phase/--component/--force` | removed. They were parsed and ignored |
| `cata apply --sequential`                 | removed. It was parsed and ignored    |
