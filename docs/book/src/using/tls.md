# TLS and the Lab CA

Every service in a lab should be reachable over HTTPS with a certificate
that actually verifies. Let's Encrypt cannot help here: the names are not
public, and even where they are, a lab you tear down and rebuild ten times a
day will hit the rate limits by lunchtime.

So a lab has its own CA. One root, minted once, trusted everywhere in the
lab and nowhere else.

## Who terminates what

Two different things serve TLS and they get their certificates differently.

| Where                  | Serves                  | Certificate from                 |
| ---------------------- | ----------------------- | -------------------------------- |
| HAProxy, on your host  | `*.<zone>` from outside | the `cert-generate` step         |
| The in-cluster gateway | traffic already inside  | cert-manager, from the same root |

The host ingress is the part that has a chicken-and-egg problem. HAProxy has
to load a certificate before it will start, and that is long before any
cluster exists to run cert-manager. So `cert-generate` mints a leaf directly
from the lab CA on disk, with `CN=*.<zone>` and SANs for `*.<zone>` and
`<zone>`, and writes it to `$LAB_STATE_DIR/proxy/lab.pem`. It is idempotent
and skips if the file is already there.

Inside the cluster, cert-manager issues from the same root through the
`lab-ca` ClusterIssuer, so a pod verifying a certificate from the host
ingress and a pod verifying one from another pod are checking the same
signature.

## Getting the root

The CA is a managed secret with `kind = "ca"`, which means it lives
encrypted in SOPS and gets written to disk during preflight:

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

```bash
cata --flake .#<lab> lab ops -- trust init-ca
```

That mints the root, encrypts it into the store, and from then on every
machine that can decrypt the store gets the same CA. The CLI seeds it into
every cluster as `lab-ca-ca-secret` when the cluster is created, so each
`lab-ca` ClusterIssuer issues from that one root.

If you skip `init-ca`, `cert-generate` mints a throwaway local CA so the lab
still comes up. It says so when it does. That is fine for a solo demo and
wrong for anything shared, because nobody else can reproduce it.

For the bundle that consumers mount inside the cluster, enable
`floes.trust-manager`. cert-manager only emits the `lab-ca-bundle` ConfigMap
when trust-manager is there to distribute it, and every consumer treats a
missing bundle as "no CA configured" rather than as an error.

## Trusting it

This is the part that used to mean `sudo` and a rebuilt trust store. It does
not anymore.

| Who               | How                                     | Needs root |
| ----------------- | --------------------------------------- | ---------- |
| Tools `cata` runs | automatic, the `trust-bundle` step      | no         |
| Your shell        | `eval "$(cata lab env <lab>)"`          | no         |
| Your browsers     | `cata lab ops -- trust browser`         | no         |
| The whole machine | `lab.trust.installIntoHostStore = true` | yes        |

`trust-bundle` concatenates your system roots with the lab CA into
`~/.local/share/catallaxy/labs/<lab>/trust/bundle.crt`, then hands it to
every tool the CLI spawns through `SSL_CERT_FILE`, `CURL_CA_BUNDLE`,
`GIT_SSL_CAINFO`, `REQUESTS_CA_BUNDLE`, `NIX_SSL_CERT_FILE` and
`NODE_EXTRA_CA_CERTS`. Nothing on your machine is modified.

`cata lab env` gives your own shell the same thing. It reads only the lab's
state directory with no `nix eval`, so it is fast enough for a `shellHook`
and works even when the flake does not evaluate. The lab's dev shell does it
for you:

```bash
nix develop '.#"mylab.local"'      # quotes: lab names contain dots
```

Browsers keep their own stores, so they need `trust browser`. It writes
`~/.pki/nssdb` for the Chromium family and every Firefox profile's
`cert9.db`, all user-owned, no sudo. Note the asymmetry: Chromium shares one
NSS database per user, so `--user-data-dir` does not isolate certificates,
while Firefox's store is per profile. `--firefox-profile <dir>` targets one
profile and creates it if missing, which gives a demo a throwaway browser.

Restart the browser afterwards. It reads the store at startup.

## On macOS

Go's `crypto/x509` reads the keychain on macOS and ignores `SSL_CERT_FILE`.
So the bundle covers curl, git and other OpenSSL-based tools, but not Go
binaries like `crane` or `netbird`. Mac operators still want
`cata lab ops -- trust setup` for those. Linux and NixOS are fully covered
by the bundle.

## Turning it off

```nix
lab.proxy.tls.enable = false;
```

The ingress becomes a plaintext Host-header router, no certificate is
minted, and `cert-generate` and `host-trust-install` drop out of the plan.
That is what you want for an example that has to come up on any machine
without touching a trust store.
