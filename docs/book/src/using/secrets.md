# Secrets

A secret has to survive being committed to git, being decrypted on your
machine, and ending up as a Kubernetes Secret in the right namespace of the
right cluster. Those are three different problems and most setups solve them
with three different tools that don't know about each other.

Catallaxy declares all three in one place. You say what the secret is, and
where it needs to land. The encryption and the plumbing are derived.

## Three levels

| Level              | Declared at               | Is                                          |
| ------------------ | ------------------------- | ------------------------------------------- |
| **Store**          | `lab.secrets.stores.<n>`  | where the values live, chosen by `backend`  |
| **Managed secret** | `lab.secrets.managed.<n>` | named keys that live in a store             |
| **Projection**     | `secrets.projections.<n>` | those keys, copied into a Kubernetes Secret |

The store is where the values are kept. The managed secret is what is kept
there. The projection is where a copy of it goes.

A store's `backend` decides the first of those. `sops` is an encrypted file
in git at `secrets/<lab>/<store>.enc.yaml`. `env` is a set of environment
variables, which is what a lab uses when it has to stand up somewhere that
holds no decryption key, CI being the case that motivated it.

## Declaring one

```nix
lab.secrets.stores.app = { backend = "sops"; };

lab.secrets.managed.postgres = {
  store = "app";
  keys = {
    password = { generator = "alphanumeric"; length = 32; };
    username = { };
  };
};
```

A key with a `generator` gets minted for you. `base64`, `hex`,
`alphanumeric` and `uuid` are available. A key without one is a key you type
in yourself, which is what you want for an API token somebody else issued.

```bash
cata --flake .#<lab> secrets generate     # mint the generated keys
cata --flake .#<lab> secrets edit app     # fill in the rest in $EDITOR
```

`secrets generate` writes the store files of every `sops` backed store. It
skips stores that already exist, so re-running it is safe; pass `--force`
when you actually mean to regenerate. `--example` prints the plaintext shape
without writing anything, which is how you find keys you have not filled in
yet.

Encryption is SOPS, and the recipients come from `.sops.yaml` at the repo
root, keyed by path. That file is the one piece not declared in Nix, because
it is what SOPS itself reads.

## Taking values from the environment

A `sops` store needs a decryption key on the machine. A runner that has none
cannot open it, which is the whole of the problem, so a store can instead
read its values from the environment:

```nix
lab.secrets.stores.app = { backend = "env"; };
lab.secrets.envFile = "examples/labs/gitops/envs/ci.env";

lab.secrets.managed.session-key = {
  store = "app";
  keys.secret = { generator = "base64"; length = 32; };
};
```

The variable name is derived, never declared:
`CATA_SECRET_<STORE>__<SECRET>__<KEY>`, uppercased, with every character
that is not a letter or a digit replaced by an underscore. The store `app`,
secret `session-key` and key `secret` above is
`CATA_SECRET_APP__SESSION_KEY__SECRET`. Two underscores separate the three
parts, so a store called `a_b` cannot collide with a secret called `b_c`.
There is nothing to keep in sync, and `secrets list` prints the names.

`lab.secrets.envFile` names a file that sets those variables, as a path
relative to the flake root. Catallaxy never reads it. The environment is the
interface, and the file is one way to fill it, named where a runner can find
it:

```bash
set -a; . ./examples/labs/gitops/envs/ci.env; set +a
```

That is what `nix run .#e2e -- <lab>` does before it stands a lab up, and it
is why a lab whose values come from the environment and which names no
`envFile` is reported as not self-contained by `nix eval .#e2eLabs`. Values
that arrive from somewhere the lab does not describe are not derivable.

The path is relative rather than a Nix path (`./ci.env`) on purpose. A Nix
path resolves to the flake's source in the store, and under Determinate
Nix's lazy trees that source is never written to disk, so the runner would
be handed a path that does not exist. The repository is where the file
actually is, and the relative form is also the argument to `git add`.

Write the file with the command that knows the names:

```bash
cata --flake .#<lab> secrets generate --format env > ci.env
```

It prints one `VAR='value'` line per key and writes nothing itself. Commit
the file only when the values are throwaway, which for a CI lab they are:
every key is generated, and the lab is destroyed at the end of the run.

## Getting it into a cluster

A projection is per cluster, because the same secret often belongs in more
than one and they do not have to agree on the namespace:

```nix
secrets.projections.postgres-app = {
  source = "postgres";
  namespace = "apps";
  keys = {
    POSTGRES_PASSWORD = { from = "password"; };
    POSTGRES_USER = { from = "username"; };
  };
};
```

`from` names the key in the managed secret, and the attribute name is the
key in the Kubernetes Secret. `transform` handles the cases where the
consumer wants a different encoding: `base64`, or `json-wrap` to bury the
value inside a JSON object because some chart expects a blob.

Getting either name wrong is an eval error, not a broken pod. The assertion
tells you which projection, which key, and lists the keys that do exist.

Consume it through `ref` rather than repeating the name:

```nix
envFrom = [ config.secrets.projections.postgres-app.ref.envFrom ];
```

## Getting it onto disk

Some secrets are needed before any cluster exists. The lab CA is the obvious
one: HAProxy has to load a certificate to start, and that happens well
before a cluster is up to hold a Secret.

```nix
lab.secrets.managed.lab-ca = {
  store = "trust";
  kind = "ca";
  hostPaths = {
    "ca.crt" = "$LAB_STATE_DIR/proxy/ca.crt";
    "ca.key" = "$LAB_STATE_DIR/proxy/ca.key";
  };
};
```

`hostPaths` entries are written during `cata lab up`'s preflight, after
decryption succeeds and before any service starts. `*.crt` files get 0644
because they are public PEM, everything else gets 0600. Re-runs skip files
whose contents already match.

`kind = "ca"` is a special case worth knowing about. A cert and its key have
to be minted together, so generating them as two independent random strings
does not work. Setting `kind = "ca"` implies the keys `ca.crt` and `ca.key`,
and `secrets generate` mints the pair (P-256, ten years) rather than running
a generator per key. `secrets init-intermediate <name>` signs a second CA
with the root already in the store. See [TLS and the Lab CA](./tls.md).

## What runs when

`ensure-secrets` runs early in the plan and fails if a declared store is not
readable yet: no file on disk for a `sops` store, an unset or empty variable
for an `env` one. Either way it names what is missing and how to supply it.
It is a check, not a mutation, so it never surprises you by writing a secret
you did not ask for.

## Commands

| Command                         | Does                                           |
| ------------------------------- | ---------------------------------------------- |
| `secrets generate [LAB]`        | mint values for generator-backed keys and CAs  |
| `secrets generate --format env` | print the `VAR=value` lines an env store reads |
| `secrets init-intermediate <N>` | sign an intermediate CA with the lab's root    |
| `secrets edit <STORE>`          | decrypt, open in `$EDITOR`, re-encrypt         |
| `secrets list [LAB]`            | managed secrets and their status               |
| `secrets decrypt <STORE>`       | decrypt to stdout                              |
| `secrets rotate <STORE>`        | re-encrypt to the current set of recipients    |

`<STORE>` takes a store name or a path to any encrypted file.
