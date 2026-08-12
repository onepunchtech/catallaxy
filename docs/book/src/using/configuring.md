# Configure a Lab

Turning floes on, wiring them to each other, and varying them per
environment.

Getting a lab scaffolded in the first place is
[Build Your Own Lab](../start-here/your-own-lab.md).

## Enabling a floe

Floes belong to a cluster, not to the lab, so this goes inside a
`lab.clusters.<name>` block:

```nix
floes.cert-manager = {
  enable = true;
  selfSignedCA.enable = true;
};
```

`enable` sits on the _floe_, and its whole module body is gated on it. This
renders nothing, silently:

```nix
floes.custom.apps.hello = { … };   # without floes.custom.enable = true
```

Every floe carries the same base options whatever it does: `enable`,
`namespace`, `version`, `exports`, `requires`, `drift.expected` and
`overrides.*`. The rest are on the generated
[option pages](../reference/options.md).

## Wiring floes together

Read another floe's typed exports rather than copying its values:

```nix
floes.my-app.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
```

Every export carries a default, so reading one from a cluster that does not
run the producing floe gives you that fallback rather than an error. Where a
floe may genuinely be absent, read defensively:

```nix
issuer = config.floes.my-idp.exports.oauth2Clients.my-app.issuer or "";
```

Depending on a floe's _value_ degrades to a default. Depending on its
_presence_ does not: anything naming a disabled floe in `requires` fails
evaluation with `floe 'x' requires floe 'y' to be enabled`.

Across clusters, use the `lab` argument. That gives you the right _address_
for something elsewhere, but moves no data. Copying an actual Secret between
clusters is a `cross-cluster-secret-copy` plan step.

## `overrides`

Every floe accepts the same override surface, so facts about _where_ you are
deploying enter from outside instead of being baked into the floe:

```nix
floes.gateway.overrides = {
  serviceType = "LoadBalancer";
  extraAnnotations."service.beta.kubernetes.io/aws-load-balancer-type" = "nlb";
  nodeSelector."node.kubernetes.io/instance-type" = "m6i.large";
};
```

Overrides merge into every resource the floe emits, so an override with no
effect is a bug in that floe.

## Layering across environments

Floe configuration is ordinary module configuration: put the shape in a
shared module and the differences in an env file.

```nix
# shared
floes.prometheus.retention = lib.mkDefault "15d";

# envs/local.nix
floes.prometheus.retention = "2d";
```

`mkDefault` in the shared module keeps env files short and marks the value
as expected to be overridden. `mkForce` wins regardless of priority.

A lab is then a base plus an environment:

```nix
"my-platform.local" = mkLab [ ./labs/default.nix ./envs/local.nix ];
"my-platform.prod"  = mkLab [ ./labs/default.nix ./envs/prod.nix ];
```

## The other extension points

Beyond floes, a lab can add:

| Option                         | For                                                                            |
| ------------------------------ | ------------------------------------------------------------------------------ |
| `floes.custom.apps.<n>`        | a few resources and a route, with no option surface worth naming               |
| `lab.steps.<n>`                | work the plan must do that is not applying a manifest                          |
| `cluster.lifecycle.*`          | per-cluster hooks around provisioning, deploy and teardown                     |
| `lab.ops.commands.<n>`         | an operator command, as `cata lab ops <category> <name>`, never part of a plan |
| `lab.lint.checks.<n>`          | a rule about your rendered manifests, run beside the built-in ones             |
| `bundles.<n>`                  | one odd resource that needs a position in the install graph                    |
| `cluster.drift.declarations`   | a field something other than your CD tool writes                               |
| `lab.policy.*`, `lab.images.*` | lab-wide defaults every floe inherits                                          |

The one thing needing a change to catallaxy itself is a new _built-in_ lint
rule; those are a hardcoded list in Rust. `lab.lint.checks` runs in the same
pass and is the supported substitute.

## Checking it

```bash
cata --flake .#<lab> lab lint                          # does it hold together
cata --flake .#<lab> lab plan                          # what will happen
cata --flake .#<lab> lab plan-manifests --cluster <c>  # what installs when
cata --flake .#<lab> lab up                            # converge
```

`lab up` is idempotent. Running it against a healthy lab is a no-op plus a
re-apply, which is the right response to "something got changed by hand".
