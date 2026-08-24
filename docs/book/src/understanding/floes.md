# Floes

A floe is one capability, such as cert-manager, a gateway, or your own
application, packaged as a typed module. It is the unit you turn on,
configure, and compose.

## Compared to a Helm chart

A floe covers the same ground a chart does, parameterised manifests you can
configure, share and install, and adds the parts a chart leaves to whoever
installs it.

|                      | Helm chart                                                          | Floe                                                                                     |
| -------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Templating           | Go templates over text; structure exists only after render          | Nix functions over data: attrsets, lists, conditionals, all of `lib`                     |
| Configuration        | untyped YAML values; a misspelled key is ignored                    | typed options with defaults and descriptions; a bad name or type fails at eval           |
| Emitted manifests    | whatever the template produced                                      | checked against the generated Kubernetes and CRD schemas                                 |
| Interface to others  | none between releases; you copy the value into a second values file | `exports`, a typed interface peers read directly                                         |
| Reading another unit | subcharts, vendored into your own release                           | `config.floes.<x>.exports.<field>`, and nothing else, enforced by `checks.floe-boundary` |
| Install order        | `helm.sh/hook` weights you pick; across releases, your script       | `provides` and `requires` tokens; the plan is derived                                    |
| What "ready" means   | `--wait` on the release; hooks carry no lifecycle                   | a per-bundle `readyProbe`, published as state others wait on                             |
| Guard rails          | documentation                                                       | `requires` assertions and flake checks that fail the build                               |
| Testing              | render it and read it; anything further wants a cluster             | `evalFloe` against a fixture cluster: milliseconds, no cluster                           |
| Distribution         | chart repo or OCI, resolved by version range                        | a flake output, pinned by `flake.lock`                                                   |

## Two camps

A floe declares Kubernetes resources with `bundles` and everything else with
`infra`. The split is about how a thing gets made, not about clouds versus
clusters.

A bundle is the reconcile camp: a controller in a cluster acts on it
continuously, truth lives in the API server, ordering is readiness tokens,
and outputs are Secrets. Crossplane is here too, which is why a Crossplane
managed resource is just a bundle.

`infra` is the plan/apply camp: a tool acts once when you run it, truth
lives in a state file, the tool orders resources from the references between
them, and outputs are known only after apply. Terraform is the first thing
it renders; OpenTofu, Pulumi, CloudFormation and Bicep are the same shape.

See [Provisioned Infrastructure](../reference/infra.md).

None of that is a reason to abandon the charts you already run. A bundle
renders upstream charts at build time through `helmCharts.<release>`, so
wrapping one in a floe gives it the typed surface, the interface and the
place in the install graph, without reimplementing what the chart does.

## The interface is the point

Your app needs the issuer cert-manager created, so you type the issuer's
name into your app's values file. Now the same fact exists in two places.
Rename it on one side and nothing complains. The chart still renders, the
manifest still applies, and you find out when a certificate never appears.

A floe publishes its computed values as a typed interface, and consumers
read that interface instead of copying from it.

```nix
floes.my-app.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
```

If cert-manager renames that field, this line stops evaluating. You learn at
`nix flake check`, not from a pod that never got a certificate.

## A complete floe

This is the whole thing: options, resources, a readiness probe, and an
interface. It is the worked example in the consumer template, condensed:

```nix
{ floeOptions, lib }:

{ config, ... }:

let
  cfg = config.floes.hello-world;
  gateway = config.floes.gateway.exports;
in
{
  imports = [
    (floeOptions {
      name = "hello-world";
      version = "1.0.0";
    })
    ./options.nix                     # image, replicas, domain
  ];

  options.floes.hello-world.exports.url = lib.mkOption {
    type = lib.types.str;
    default = "http://hello-world.hello-world.svc.cluster.local";
    description = "In-cluster URL of the Service.";
  };

  config = lib.mkIf cfg.enable {
    floes.hello-world.exports.url =
      "http://hello-world.${cfg.namespace}.svc.cluster.local";

    floes.hello-world.bundles.hello-world = {
      createNamespaces = [ cfg.namespace ];
      requires = [ "gateway/controller/ready" ];   # not just applied, ready
      readyProbe = {
        kind = "condition";
        resource = "deployment/hello-world";
        namespace = cfg.namespace;
        condition = "Available";
        timeout = "2m";
      };

      resources = {
        hello-deployment = { /* … */ };
        hello-service = { /* … */ };
        hello-route = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          spec.parentRefs = [{
            name = gateway.gatewayName;        # read, not hardcoded
            namespace = gateway.namespace;
          }];
          # …
        };
      };
    };
  };
}
```

A floe declares no dependencies of its own. What it needs is said on its
bundles, as names in the one dependency namespace, so
`gateway/controller/ready` above is what makes enabling this without a
gateway fail evaluation.

Get the full file, and a lab that runs it:

```bash
nix flake init -t github:onepunchtech/catallaxy#consumer
```

## What each part is for

**`imports`** brings in the option surface. It sits _outside_ the enable
gate, so other modules can read your options even when your floe is off.
That is why options live in their own file.

**`config`** is the body, gated on `enable` with `lib.mkIf`. `cfg` is
`config.floes.hello-world`, which you bind yourself in a `let`.

**`bundles.<name>`** groups resources that install together. `requires`
names a _state_ another bundle offers, and it means ready, not applied.
Applying a CRD and the CRD being usable are different moments. Nothing
carries a phase or a number. The order is computed from these declarations.

**`exports`** is the typed interface, declared outside the enable gate for
the same reason `imports` is. Every field needs a `default`, because a
consumer may read one while computing its own option default, and the module
system evaluates that whether or not your floe is enabled.

A floe has no dependency list of its own. Everything it needs is said on its
bundles, as names rather than floe names, so `requires` above is what makes
enabling this without a gateway fail evaluation.

## Export the answer, not the ingredients

Publish the value a consumer wants, not the parts they would assemble it
from:

```nix
# good: one place can get it wrong
url = "http://hello-world.${cfg.namespace}.svc.cluster.local";

# bad: every consumer can get it wrong
namespace = cfg.namespace;
port = 80;
```

The same applies to questions. Do not make consumers ask whether you are
enabled. `enable` is internal state and usually the wrong question: "is
cert-manager on" is a proxy for "can I get a certificate", and only
cert-manager can answer that, since it can be enabled and still issue
nothing without an issuer. Publish the capability, and let it be `null` when
absent:

```nix
issuance = if hasIssuer then { defaultIssuerRef = …; } else null;
```

## When you don't need one

If you have a few resources, no options worth naming, and nothing reads
values off them, use `floes.custom.apps` instead:

```nix
floes.custom.enable = true;
floes.custom.apps.podinfo = {
  namespace = "podinfo";
  gateway = { enable = true; domain = "podinfo.${lab.dns.zone}"; };
  resources = { /* Deployment, Service */ };
};
```

That is exactly what the `minimal` example lab does. Reach for a floe when
it has options that differ per environment, something downstream reads a
value off it, it must wait for something specific to be ready, or you want
to ship it to someone else.
