# Example labs

A ladder, not a template. Each lab here exists to show one more thing than
the last, and they are deliberately separate so you can read the one that
matches your problem instead of forking the biggest one and deleting what
you don't need.

| Lab                    | Clusters | Shows                                                                         |
| ---------------------- | -------- | ----------------------------------------------------------------------------- |
| [`minimal`](./minimal) | 1 (k3d)  | The whole model, small: a cluster, a gateway, one app, over plain HTTP        |
| [`homelab`](./homelab) | 2        | Aspects/clusters/envs layering, OIDC, observability, GitOps                   |
| [`mesh`](./mesh)       | 2        | An awkward requirement: a WireGuard-only mesh, plus the lab CA and host trust |

Each directory holds a `labs/default.nix` (the topology) plus one
`envs/<name>.nix` per environment. Lab names are `<dir>.<env>`, so
`minimal/envs/local.nix` becomes the lab `minimal.local`.

## Docker subnets

A docker network owns its subnet exclusively, so two labs on the same range
cannot be up at once; the second `lab up` fails at the network step with
"Pool overlaps with other one on this address space". Each example therefore
sets its own `lab.network.dockerSubnet`, rather than sharing the
`172.19.0.0/16` module default:

| Lab                    | Subnet          |
| ---------------------- | --------------- |
| `minimal.local`        | `172.20.0.0/16` |
| `mesh.local`           | `172.21.0.0/16` |
| `homelab.local`        | `172.22.0.0/16` |
| `homelab.gitops-local` | `172.23.0.0/16` |
| `gitops.local`         | `172.24.0.0/16` |

The `example-lab-subnets` flake check keeps these pairwise distinct. Your
own labs need the same treatment: pick a range no docker network on the host
already holds
(`docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'`),
and note that the lab's DNS server address and docker gateway are derived
from it.

## Secrets

One lab here holds a SOPS store and will not start without it: `mesh.local`,
whose root CA lives in it. No key is shipped in this repo; you encrypt to
your own.

`gitops.local` also has a secret, a session key, but its store is
`backend = "env"`: the values come from environment variables, and the lab
points `lab.secrets.envFile` at `gitops/envs/ci.env`, which is committed.
The steps below do not apply to it. Nothing to encrypt, nothing to fill in,
and `nix run .#e2e -- gitops.local` loads the file itself.

**1. Have an age key.** If you don't already:

```bash
age-keygen -o ~/.config/sops/age/keys.txt
```

sops reads that path by default, or whatever `SOPS_AGE_KEY_FILE` points at
if you set it. A YubiKey-backed identity (`age1yubikey1…`) works too, but
`lab up` decrypts on every run, so a touch-per-decrypt policy gets tiring
fast, so a plain key is the kinder choice for a lab CA.

**2. Write a `.sops.yaml`** at the repo root, naming the public half of that
key per lab. It is gitignored: it is yours, not the project's.

```yaml
creation_rules:
  - path_regex: secrets/mesh\.local/.*\.enc\.yaml$
    age: age1...your-public-key...
```

sops resolves rules by walking **up** from the file being encrypted and
stopping at the first `.sops.yaml` it finds, so one file at the repo root
covers labs driven from here and from the root alike, because `path_regex`
is a search, not an anchored match. If no rule matches you get "no matching
creation rules found", which is the failure to expect when a lab is missing
from the list.

**3. Fill the store.** `cata --flake .#mesh.local secrets generate`. Its
`trust` store holds a `kind = "ca"` secret, and the CLI mints the
certificate and its key together, which is the only way that composes.

For a `value` key, the same command mints the ones that declare a
`generator`, and `cata secrets edit <store>` is where you replace the
placeholder in the ones that do not.

## Mesh client ports

A lab that enables `floes.netbird` runs its own netbird daemon on the
operator's machine, isolated from the operator's personal one and from every
other lab's. Service name, socket, profile path and WireGuard interface are
all derived per lab and need no bookkeeping. The **UDP listen port** is the
one shared namespace with no per-lab default available:

| Lab          | `floes.netbird.client.wireguardPort` |
| ------------ | ------------------------------------ |
| `mesh.local` | `51830` (the option default)         |

netbird's own default is `51820`, which is the operator's personal daemon.
hence starting at `51830`. The `example-lab-mesh-ports` flake check keeps
these distinct as more labs enable the floe.

Two further constraints only bite when two mesh labs are up simultaneously:

- On a host **without** systemd-resolved, netbird rewrites
  `/etc/resolv.conf` and runs a stub resolver on a discovered address. Give
  each lab a distinct `client.dnsResolverAddress` there. (`/etc/resolv.conf`
  itself is still one file, so this is mitigated, not solved.)
- Two labs whose clusters both advertise the default `10.96.0.0/12` service
  subnet cannot both hold that route on one host. That is a routing fact,
  not a netbird option: give them distinct `cluster.network.serviceSubnet`
  values, the same way they need distinct docker subnets.

---

## `minimal.local`

One k3d cluster, `floes.gateway` for ingress, `floes.cert-manager` for a
self-signed CA, and one app declared through `floes.custom`. No secrets, no
identity, no cloud account.

```bash
cata --flake '.#minimal.local' lab plan     # see the plan before running it
cata --flake '.#minimal.local' lab up
cata --flake '.#minimal.local' lab verify
cata --flake '.#minimal.local' lab destroy

nix run .#e2e -- minimal.local             # or all of that in one go
```

`minimal/labs/default.nix` is the shortest complete statement of the model.

It is also one of the two labs CI stands up on every pull request, which is
why it enables nothing it does not need: two container images, one cluster.

---

## `gitops.local`

The shortest complete statement of the _gitops_ model: one k3d cluster with
cert-manager, a gateway, cnpg, Forgejo, ArgoCD and one app, and nothing
else.

```bash
nix run .#e2e -- gitops.local     # up, verify, up again, destroy, assert clean
```

Its plan reaches every step the handoff needs:
`bootstrap-argocd-kubectl-ssa` installs ArgoCD, `bootstrap-forgejo-repos`
waits for the org and repo to exist, `publish-manifests` pushes the rendered
tree into the in-cluster Forgejo, and `apply-root-application` hands the
cluster over.

It also carries a generated secret, projected into a cluster namespace and
read by a preflight hook, which is what covers `ensure-secrets`,
`secrets.projections` and `run-script`'s `env` injection end to end.

`homelab.gitops-local` reaches the same four steps and pulls 39 images to do
it, because it is also carrying observability, a registry, backups and
identity. This one pulls 12. That difference is why it exists: it is the lab
CI runs on every pull request to keep the gitops path honest, and the lab to
read if that path is what you are trying to understand.

---

## `homelab.local`

Two k3d clusters (`core` and `obs`) composed from reusable _aspects_:
networking, identity (Kanidm OIDC), monitoring, GitOps, source control,
registry, backups. The layering pattern is visible here: `clusters/*.nix`
say what a cluster is, `aspects/*.nix` say what a capability is, and
`envs/*.nix` say where it runs.

```bash
cata --flake '.#homelab.local' lab up
cata --flake '.#homelab.local' lab topology --format table
cata --flake '.#homelab.local' lab ops idm init-user lab-admin
```

It also carries one of each headline extension point, so you have a working
reference rather than a snippet:

- `lab.policy.exposure.defaultTier`: one lab-wide statement every floe's
  `gateway.tier` inherits.
- `lab.steps.verify-lab-dns`: a lab-authored plan step spliced between
  `dns-setup` and `create-cluster`.
- `lab.lint.checks.no-latest-tag`: a lab-authored lint rule that runs under
  `cata lab lint` next to the built-in ones.

---

## `homelab.gitops-local`

Same topology as `homelab.local`, but `lab.cd.strategy = "argocd"`. The
install-target set is applied imperatively so ArgoCD and Forgejo exist,
`cata lab publish` pushes the rendered manifests into the in-cluster
Forgejo, and ArgoCD reconciles from there.

This is the gitops path at full size, with everything a real lab carries
around it. `gitops.local` above is the same path with nothing else attached.

---

## `mesh.local`

Two clusters whose services are reachable only from a mesh VPN. It exists to
show what a genuinely awkward requirement looks like when it has to be
expressed in the same vocabulary as everything else: a lab-wide exposure
policy, a step that moves a credential between clusters, a step that runs
work which is not applying a manifest, and a two-tier CA so a mesh-only
service still has TLS a browser accepts.

```bash
cata --flake '.#mesh.local' lab plan
```

Deliberately _not_ the recommended shape for a normal lab. `homelab` is
that. [`mesh/README.md`](./mesh) walks through each mechanism it uses and
why.

---

## Plan snapshots

Every lab here has a committed plan fixture under
[`tests/plan-snapshots/`](./tests/plan-snapshots). `nix flake check` diffs
the generated plan against it, so any planner change that alters ordering,
step fields, or step count shows up as a reviewable diff rather than at
`cata lab up` time. Refresh one with:

```bash
cata --flake .#<lab> lab plan --stable [--teardown] \
  > examples/labs/tests/plan-snapshots/<lab>.<direction>.expected.txt
```
