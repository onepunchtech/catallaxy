# Secrets

A secret has to survive being committed to git, being decrypted on your
machine, and ending up as a Kubernetes Secret in the right namespace of the
right cluster. Those are three different problems and most setups solve them
with three different tools that don't know about each other.

Catallaxy declares all three in one place. You say what the secret is, and
where it needs to land. The encryption and the plumbing are derived.

## Three levels

| Level              | Declared at               | Is                                               |
| ------------------ | ------------------------- | ------------------------------------------------ |
| **Store**          | `lab.secrets.stores.<n>`  | one encrypted file, `secrets/<lab>/<n>.enc.yaml` |
| **Managed secret** | `lab.secrets.managed.<n>` | named keys that live in a store                  |
| **Projection**     | `secrets.projections.<n>` | those keys, copied into a Kubernetes Secret      |

The store is the file. The managed secret is what is in the file. The
projection is where a copy of it goes.

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

`secrets generate` writes the store file. It skips stores that already
exist, so re-running it is safe; pass `--force` when you actually mean to
regenerate. `--example` prints the plaintext shape without writing anything,
which is how you find keys you have not filled in yet.

Encryption is SOPS, and the recipients come from `.sops.yaml` at the repo
root, keyed by path. That file is the one piece not declared in Nix, because
it is what SOPS itself reads.

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
does not work. Setting `kind = "ca"` implies the keys `ca.crt` and `ca.key`
and hands the minting to `cata lab ops -- trust init-ca`. See
[TLS and the Lab CA](./tls.md).

## What runs when

`ensure-secrets` runs early in the plan and fails if a declared store has no
file on disk yet, with the two commands to fix it. It is a check, not a
mutation, so it never surprises you by writing a secret you did not ask for.

## Commands

| Command                   | Does                                        |
| ------------------------- | ------------------------------------------- |
| `secrets generate [LAB]`  | mint values for generator-backed keys       |
| `secrets edit <STORE>`    | decrypt, open in `$EDITOR`, re-encrypt      |
| `secrets list [LAB]`      | managed secrets and their status            |
| `secrets decrypt <STORE>` | decrypt to stdout                           |
| `secrets rotate <STORE>`  | re-encrypt to the current set of recipients |

`<STORE>` takes a store name or a path to any encrypted file.
