# DNS for the Lab

A local lab has a problem that a cloud environment does not. The same name
has to resolve from two places that cannot see the same network: your
laptop, and a pod inside a cluster. `grafana.mylab.test` typed into your
browser and `grafana.mylab.test` looked up by a sidecar have to arrive at
the same service, and neither `/etc/hosts` nor the cluster's CoreDNS can do
both.

So catallaxy runs a real DNS server. Knot DNS, in a container, authoritative
for your lab zone.

## What runs

Turn it on with `lab.dns.enable = true`. You get a container called
`catallaxy-dns` holding one zone, `<lab>.test` by default, published on host
port 5354. Port 5354 rather than 5353 because mDNS already owns 5353 on most
machines.

The zone starts with a wildcard:

```
*   IN  A   172.19.0.1
```

That address is the docker bridge gateway, and it is the whole trick. It is
reachable from your host and from inside every container on the lab network,
so one record answers for both. It points at the HAProxy ingress, which
routes on the Host header, so a single wildcard covers every service the lab
exposes without anything having to enumerate them.

## How your machine finds it

The `dns-setup` step writes a systemd-resolved drop-in:

```
[Resolve]
DNS=127.0.0.1:5354
Domains=~test
```

`~test` is a routing domain, not a search domain. It means "send `.test`
queries here", and nothing else changes about your resolver. Every lab whose
zone ends in `.test` and uses the default port shares this one drop-in, so
you install it once no matter how many labs you run. A lab on a different
zone or port gets its own file.

`cata lab dns --teardown` removes it.

## external-dns writes to it

Knot is configured for RFC2136 dynamic updates with a TSIG key, and the
external-dns floe is pointed at it with the same key. A service that wants a
real record gets one, and because a more specific record always beats a
wildcard, external-dns keeps control of anything it publishes while the
wildcard catches everything else.

That ordering matters more than it looks. Without the wildcard, a lab
running no DNS controller resolves nothing at all.

## Two tiers, one zone

Some services should be reachable from your browser. Others should be
reachable only from inside the cluster or across the mesh. Both are in the
same zone, and both need to resolve at the same time.

That is what `lab.dns.internalZone` is for. It defaults to
`internal.<zone>`, and it must be a strict subdomain:

| Name                        | Resolves to                    | Reachable from |
| --------------------------- | ------------------------------ | -------------- |
| `idm.mylab.test`            | docker gateway, then HAProxy   | anywhere       |
| `hello.internal.mylab.test` | the internal gateway ClusterIP | the mesh only  |

A subdomain and not a prefix, because resolvers match on suffix and never on
prefix. `internal-hello.mylab.test` cannot be routed separately from
`idm.mylab.test` by anything, no matter how it is spelled. This is also why
the mesh hands its clients `~internal.mylab.test` rather than `~mylab.test`:
the more specific routing domain wins, so joining the mesh does not take
your public names with it.

The zone file carries a `TXT` record at `internal` for a reason that is easy
to miss. Without a node there, the wildcard above it answers for every name
beneath it, and a mesh-only name gets the ingress address back instead of
NXDOMAIN. You then get a 503 from a gateway that has no such route, which
looks like a broken service rather than a name that was never meant to
resolve there.

## Inside the cluster

Each cluster's CoreDNS gets a `coredns-custom` ConfigMap with two server
blocks: one for the internal zone, mapping internal hostnames to the pinned
internal gateway ClusterIP, and one for the public zone that forwards to
knot for everything else.

Catallaxy owns that ConfigMap when `lab.dns.coredns.enable` is on, so do not
declare your own. Use `lab.dns.coredns.extraServers` to add blocks.
