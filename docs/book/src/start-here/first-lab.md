# Run the Example Lab

`minimal.local` is one k3d cluster, a gateway, and one app behind it.

Prerequisite: [Install](./install.md), then `nix develop`.

```bash
cata --flake . lab list
```

Lab names are `<lab>.<env>`. The environment suffix is part of the name, so
there is no lab called `homelab`.

## Look before you run

```bash
cata --flake .#minimal.local lab plan
```

`lab up` executes an ordered list of steps; `lab plan` prints it without
touching anything. Most of the early steps are host-side (a DNS server, a
TLS-terminating proxy, an image cache), because a lab includes host services
and not only cluster state.

```bash
cata --flake .#minimal.local lab lint
```

`lint` checks your tools, your configuration, and the _rendered_ manifests.
The author of a lab can write custom linting rules to make sure invariants
about your lab are not violated. For example a linting pass can catch a
Secret reference resolving to nothing, a custom resource with no CRD.

## Deploy

```bash
cata --flake .#minimal.local lab up
```

This command's job is to take the description of the lab in nix and turn it
into a real lab.

## Check it

```bash
cata --flake .#minimal.local lab verify
```

`verify` is to a running lab what `lint` is to a rendered one: it asks every
cluster whether its apiserver answers, every host service whether its ready
probe passes, every workload whether it rolled out, and every hostname the
lab routes whether it answers over the lab's own ingress and CA. It exits
non-zero when something does not, which is what makes it usable from a
script.

It reaches `podinfo.minimal.test` without your machine being able to resolve
it, by asking the lab where its ingress is. You can do the same by hand:

```bash
curl --resolve podinfo.minimal.test:80:127.0.0.1 http://podinfo.minimal.test
```

## Resolve the zone from your browser

One of the most annoying things about testing Kubernetes locally is
integrating DNS with the host. Often we use port forwarding, but that
already makes it so that we aren't actually testing our system as Kubernetes
would run it. The lab runs its own DNS instead, and can point your machine
at it:

```bash
cata --flake .#minimal.local lab dns --setup     # needs sudo
```

Then <http://podinfo.minimal.test> works in a browser like any other name.
This is off by default because it edits configuration outside the lab and
needs `sudo`, which is a poor default for a command whose job is to be
reversible; a lab you live in can turn it on for good with
`lab.dns.configureHost = true`, and `lab destroy` then removes it again.

`kubectl` works normally against context `k3d-minimal-local-app`.

## Inspect

```bash
cata --flake .#minimal.local lab topology --format table
```

Reports what the lab contains and how it is wired: host services and their
ports, clusters and their networks. Add `--live` to query the clusters for
real status instead of reporting it as unknown. `mermaid`, `json` and `dot`
are the other formats.

## Tear down

```bash
cata --flake .#minimal.local lab down      # stop, keep state
cata --flake .#minimal.local lab destroy   # delete everything
```

`destroy` runs the teardown plan, which `lab plan --teardown` prints. The
teardown is the reverse of the `lab up` command. It depends on the
definition of the lab itself. So for a local defined lab that depends on k3d
clusters it should be fast to tear down. For a lab that orchestrates cloud
clusters it will make sure that the cloud resources are fully removed.

## Try another bigger example

`homelab.local` is multi-cluster lab with some cool apps integrating with
each other. Kanidm for OIDC, the observability stack, ArgoCD, and a
self-hosted Forgejo. The commands are identical, just point to the flake
output.

```bash
cata --flake .#homelab.local lab up
cata --flake .#homelab.local lab ops kanidm init-user lab-admin
```

That second command is worth noticing. `lab ops` runs operator commands a
floe ships with itself. The kanidm floe provides `init-user`, so any lab
running kanidm gets it without anyone writing a runbook. It is like we can
make executable runbooks that understand our cluster topology through the
power of nix. Run `lab ops` with no sub-command to list what a lab offers.

`mesh.local` is the awkward example, but demonstrates something very
difficult to do outside of catallaxy. It demonstrates how to integrate host
concerns like trust certificates for tls along with a vpn mesh (netbird)

[examples README](https://github.com/onepunchtech/catallaxy/tree/master/examples/labs)
says what each lab demonstrates.
