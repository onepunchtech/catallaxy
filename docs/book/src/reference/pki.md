# Client Certificates

`cluster.apiserver.pki` gives a cluster client-certificate authentication:
each person gets a certificate whose Common Name becomes their Kubernetes
username and whose Organization fields become their groups. The private key
can live on a YubiKey, so it cannot be copied off the machine.

This is authentication for **humans reaching the apiserver**. It is not the
lab CA that signs ingress certificates; that is
[TLS and the Lab CA](../using/tls.md).

## Declaring who gets in

```nix
cluster.apiserver.pki = {
  enable = true;

  users.alice = {
    commonName = "alice@example.com";
    organizations = [ "platform-admins" ];
  };

  rbac.platform-admins = {
    organization = "platform-admins";
    clusterRole = "cluster-admin";
  };
};
```

The username the apiserver sees is `commonName`, and the groups are
`organizations`. Kubernetes has no user objects, so `rbac` is how a group
becomes a permission: it binds an Organization to a ClusterRole.

Every option is in the generated
[cluster options reference](./options/cluster.md).

## The commands

```bash
cata --flake .#<lab> pki init                    # mint the cluster's client CA
cata --flake .#<lab> pki issue alice             # issue alice a certificate
cata --flake .#<lab> pki list                    # CA and certificate status
cata --flake .#<lab> pki kubeconfig alice        # a kubeconfig using it
cata --flake .#<lab> pki provision alice         # write it to a YubiKey
```

Each takes the cluster as an argument when the lab has more than one; with
one cluster it is inferred. The CA and the issued certificates live under
`~/.local/share/catallaxy/pki/<cluster>/`.

`pki init` is a one-time step per cluster and `--force` replaces the CA,
which invalidates every certificate it signed. `pki issue` is per person and
also takes `--force` to reissue.

`pki kubeconfig` writes to stdout by default, so it can be piped or merged;
`-o <path>` writes a file instead.

## The apiserver has to trust the CA

Issuing a certificate is only half of it. The apiserver needs
`--client-ca-file` pointing at the CA that signed it, which for a k3d
cluster means the CA file is mounted into the node at creation time. That
means the order is:

```bash
cata --flake .#<lab> pki init      # first: the CA must exist
cata --flake .#<lab> lab up        # then: the cluster mounts it
```

`lab up` refuses to create a cluster whose declared mounts have no file
behind them rather than starting an apiserver that cannot read its own
client CA, so getting this order wrong is an error and not a silent failure.

## YubiKeys

`pki provision` writes an already-issued certificate and its key into a PIV
slot. Declare the device's policy on the user:

```nix
users.alice.yubikey = {
  serialNumber = "12345678";  # targets one specific device
  slot = "9a";                # 9a authentication, 9c signing
  touchPolicy = "always";     # tap for every use
  pinPolicy = "once";         # PIN once per session
};
```

`touchPolicy = "always"` means a physical tap for every API call, which is
the point of the exercise for a production cluster and tiresome for a lab.
`cached` taps once per 15 seconds.

Run `pki issue` before `pki provision`: provisioning moves an existing
certificate onto the device, it does not mint one.
