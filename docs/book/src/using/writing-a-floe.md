# Write a Floe

Building one, from the smallest thing that renders to something you can
ship. Each stage evaluates, so you can stop at any point.

If you have not read [Floes](../understanding/floes.md) yet, start there. It
covers what a floe is and when `floes.custom.apps` is the better answer.

The finished article is in the consumer template:

```bash
nix flake init -t github:onepunchtech/catallaxy#consumer
```

## 1. The smallest thing that renders

```nix
# floes/hello-world/default.nix
{ floeOptions, lib }:

{ config, ... }:

let
  cfg = config.floes.hello-world;
in
{
  imports = [
    (floeOptions {
      name = "hello-world";
      version = "1.0.0";
    })
  ];

  config = lib.mkIf cfg.enable {
    floes.hello-world.bundles.hello-world = {
      createNamespaces = [ cfg.namespace ];
      resources.hello-deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = { name = "hello"; namespace = cfg.namespace; };
        spec = { /* … */ };
      };
    };
  };
}
```

A floe is a NixOS module and nothing else. `floeOptions` declares the option
set every floe has at `options.floes.hello-world`, and everything after that
is ordinary module syntax: bind `cfg` yourself, and gate your config on
`cfg.enable`. `cfg.namespace` defaults to the floe's name.

Register it, then turn it on. There is no auto-discovery: a floe directory
that is in neither place does nothing at all, with no error.

```nix
# floes/default.nix
{ floeOptions, lib }:
{
  hello-world = import ./hello-world { inherit floeOptions lib; };
}
```

```nix
# in a cluster
imports = [ myFloes.hello-world ];
floes.hello-world.enable = true;
```

## 2. An option surface

Options go in their own file, pulled in through `imports`:

```nix
{ lib, ... }:
let inherit (lib) mkOption types; in
{
  options.floes.hello-world = {
    image = mkOption {
      type = types.str;
      default = "hashicorp/http-echo:1.0.0";
      description = "Container image. Pin a tag, never `latest`.";
    };
    replicas = mkOption { type = types.ints.positive; default = 1; };
    domain = mkOption { type = types.str; };
  };
}
```

The two-file split is not style. **`imports` sits outside the enable gate**,
so option _declarations_ stay visible when the floe is off. That is what
lets another module read them in its own option default, and lets the
generated reference document a floe nobody turned on. Everything under
`config` is gated on `enable`.

## 3. Say what you need, and when you are ready

```nix
floes.hello-world.bundles.hello-world = {
  requires = [ "gateway/controller/ready" ];   # waits for READY
  after = [ "optional:namespace:shared" ];     # waits for APPLIED
  readyProbe = {
    kind = "condition";
    resource = "deployment/hello";
    namespace = cfg.namespace;
    condition = "Available";
    timeout = "2m";
  };
  resources = { /* … */ };
};
```

A dependency is always a _name_, never the name of another floe. Names live
in one namespace: hand-written ones are bare, by convention
`<scope>/<subject>/<state>`, and derived ones carry a prefix (`bundle:`,
`floe:`, `kind:`, `namespace:`). `requires` waits for the provider to be
ready, `after` only for it to be applied, and `conflicts` refuses a second
provider of a name only one implementation of can be right.

A name nothing provides is an evaluation error naming the bundle and the
name, so a dependency cannot be silently dropped. Prefix it `optional:` when
matching nothing is genuinely allowed.

Most of what a bundle needs is never written down at all. Emitting a
resource of a kind Kubernetes does not ship derives
`requires kind:<group>/<Kind>`, so a Certificate waits for cert-manager and
an HTTPRoute waits for a programmed Gateway without either being mentioned.
Write a name only for what the resources do not already say.

Give a bundle a `readyProbe` whenever it mints state something downstream
waits on. Leave it `null` for purely declarative bundles.

Say what the floe needs on the network too, which a lab renders into policy
when it turns [`networkPolicies`](../reference/security.md#network-policies)
on:

```nix
floes.hello.network = {
  declared = true;                      # its traffic has been worked out

  serves.http.port = 8080;              # checked against your Service
  reaches = [ "openbao/api" ];          # a label openbao published
  egress.internet.ports = [ 443 ];
};
```

Name your own ports under `serves`; name other floes' by label. You never
write another floe's port number, so you cannot write a wrong one, and
`openbao/api` naming something that does not exist fails evaluation.

Ingress is derived from whoever reaches you, so there is no second half to
keep in step.

DNS, same-namespace traffic and the API server are already granted, so a
floe that needs nothing else still sets `declared` and stops there. A check
fails on any floe that never does.

`cata lab lint` compares all of this against the Services and service
references in the rendered manifests, so a wrong port or a flow you forgot
to declare is a build failure rather than a timeout on a cluster.

## 4. Publish an interface

An export is an ordinary option under `exports`, declared outside the enable
gate and filled in inside it:

```nix
options.floes.hello-world.exports.url = lib.mkOption {
  type = lib.types.str;
  default = "http://hello-world.hello-world.svc.cluster.local";
  description = "In-cluster URL of the Service.";
};

config = lib.mkIf cfg.enable {
  floes.hello-world.exports.url =
    "http://hello-world.${cfg.namespace}.svc.cluster.local";
};
```

The split is the same one as in step 2, for the same reason: the declaration
has to stay readable when the floe is off.

Every export field needs a `default`, enforced by
`checks.every-floe-export-has-a-default`, because a consumer may read one
while computing its own option default, and that evaluates whether or not
your floe is enabled. Where there is no value until the floe runs, make the
default `null` and the type `nullOr`.

## 5. Work that is not a manifest

Some capabilities need something to happen on the operator's machine or
against a cluster that no manifest expresses: join a mesh, drain a queue,
deregister a peer. Declare it as a step, in the same DSL a lab uses:

```nix
floes.hello.steps.mesh-join = {
  kind = "run-script";
  direction = "deploy";                  # or "teardown", or "both"
  description = "Join this lab's mesh";
  scope = "lab";                         # runs once, not once per cluster
  provides = [ t.lab.reachable ];
  after = [ (t.wants (t.cluster config.cluster.name).deployed) ];
  policy.interactive = true;             # a human completes the browser login
  params.bin = "${joinScript}/bin/join";
};
```

Each entry is folded into `lab.steps` as `<cluster>-<name>`, which has two
consequences:

- **Anchor on tokens.** The fold renames your steps, and a bare name is not
  an anchor anyway. Publish a `provides` from one and wait on it from the
  other, through `lib.planTokens` so a typo is an eval error. That is also
  what lets a step in one cluster order against one in another.
- **Say what you actually depend on.** An under-constrained step gets
  hoisted by the topological sort. A mesh-join anchored only on host setup
  once landed before its clusters existed.

Publishing `t.lab.reachable` above is what makes every step that dials a lab
endpoint from the host wait for the mesh, without your naming any of them.

For cleanup, set `direction = "teardown"`, publish `t.lab.cleanup` so every
destroy waits for you, and set `policy.onFailure = "continue"`, since a
failed cleanup should not strand the rest of the teardown.

## The rules that bite

1. **Read another floe only through `config.floes.<x>.exports.<field>`**:
   its `exports`, and nothing else, enforced by `checks.floe-boundary`. What
   a floe does not export, you may not depend on; publishing is its author's
   call. This reads the same in `options.nix` as in the module body, because
   it is config rather than an argument handed to one of them.
2. **Never ask another floe whether it is enabled.** Ask for the capability,
   `config.floes.cert-manager.exports.issuance != null`, which only the
   producer can compute.
3. **Address the job, not the floe, wherever one exists.**
   `config.cluster.capabilities.resolved.<name>` is whoever does that job on
   this cluster, so a gateway consumer works whether traefik or cilium is
   serving. Ordering is a name in the bundle's `requires`, never another
   floe's.
4. **Read `cfg.overrides.*` into every resource you emit.** The option
   exists whether you read it or not, so a body that ignores it silently
   does nothing when someone sets it.
5. **Consume nothing at `let` scope from outside the floe.** A top-level
   `let` evaluates even when the floe is disabled, so an outside lookup
   there means switching your floe _off_ can break something unrelated.
6. **Take a lab-level fact from the floe that owns it, never from `lab`.**
   Reading `lab.*` claims you own that decision, and one decision has one
   owner: `gateway` owns exposure and the zones, `delivery` owns how
   manifests reach a cluster. Everything else reads their `exports`. This is
   the one rule here that nothing enforces, so it is the one that drifts,
   and it drifts silently both ways. `gatewayRef` defaulted to the literal
   `"default-gateway"` in every consumer instead of following
   `floes.gateway.exports.gatewayName`, so renaming the Gateway left five
   routes across three floes attached to one that was never created, with
   every check green. `crossplane` guessed at `lab.cd.bootstrap` and
   compared it against `"kapp"`, which that option cannot hold, so its
   rebase rules had never rendered at all (2026-08-23).

## Helpers

| Helper                                                                                                     | Reach it as                              | For                     |
| ---------------------------------------------------------------------------------------------------------- | ---------------------------------------- | ----------------------- |
| `mkGatewayExposure`, `mkGatewayParentFor`, `mkHttpRoute`, `mkTlsRoute`, `mkCertificate`, `mkGatewayParent` | `k8sHelpers.*`                           | routes and certificates |
| `wait.mkWaitInitContainer`, `wait.mkWaitJob`                                                               | `k8sHelpers.wait.*`                      | in-workload waits       |
| `mkIdempotentJob`, `hashContent`                                                                           | `catallaxy.lib.*`                        | one-shot bootstrap Jobs |
| `mkNetworkPolicy`, `network`                                                                               | `catallaxy.lib.*`                        | policies, CIDR maths    |
| chart derivations                                                                                          | `cataCharts.<name>.{chart,crds,version}` | pinned upstream charts  |

`mkIdempotentJob` exists because a Job's `spec.template` is immutable: a
one-shot bootstrap Job that changes becomes a permanent sync error. It
suffixes the name with a hash of its content, so the same content is the
same name and applying is a no-op.

Note that **any resource carrying a `helm.sh/hook` annotation is dropped**
during render, because `helm template` gives hook resources no lifecycle
semantics. If a chart's hook does something you need, re-emit it as a
first-class resource or a `mkIdempotentJob`.

## Test it

`evalFloe` evaluates one floe against a fixture cluster with stubbed
upstreams, in milliseconds and without a cluster:

```nix
{ lib, pkgs }:
let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  result = evalFloe {
    floe = import ./floes/hello-world;
    cluster.floes.hello-world = { enable = true; domain = "hello.example.test"; };
  };
in
lib.runTests {
  testExportsUrl = {
    expr = result.exports.url;
    expected = "http://hello-world.hello-world.svc.cluster.local";
  };
}
```

Wrap it in a `runCommand` as a flake check and it gates your pull requests.

## Ship it

A floe is a flake output:

```nix
outputs = { ... }: {
  floes.hello = import ./hello { inherit floeOptions lib; };
};
```

Consumers add your flake as an input and import the floe into a cluster.
There is deliberately no version-constraint mechanism: floes are flake
inputs, so `flake.lock` pins them and `nix flake update` upgrades them.
