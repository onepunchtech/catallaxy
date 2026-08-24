# Provisioned Infrastructure

A floe declares Kubernetes resources with `bundles`. It declares everything
else with `infra`.

The two are different camps, and the split is not about clouds versus
clusters. It is about how a thing gets made.

|                   | Reconcile camp (`bundles`)                       | Plan/apply camp (`infra`)                          |
| ----------------- | ------------------------------------------------ | -------------------------------------------------- |
| Who acts          | a controller in a cluster, continuously          | a tool, once, when you run it                      |
| Where truth lives | the cluster's API server                         | a state file                                       |
| Unit of change    | a resource                                       | a stack                                            |
| Ordering          | readiness tokens you declare                     | the tool, from the references between resources    |
| Outputs           | a Secret another floe reads                      | known only after apply                             |
| Examples          | Kubernetes objects, Crossplane managed resources | Terraform, OpenTofu, Pulumi, CloudFormation, Bicep |

Crossplane is in the first column. It is a controller reconciling a CR, so a
floe declares it as a bundle and gets ordering, readiness and Secrets from
what is already there. `infra` is not a replacement for it and does not wrap
it.

Terraform's JSON is the first thing `infra` renders. It is not what `infra`
is: the interface is the shape every tool in the second column shares.

## Stacks, and when things happen

A stack is one state file and one apply. You do not declare one: a stack
exists because something is in it.

What decides that is **when** a resource is needed, not what it is:

```nix
floes.net.infra.resources.vpc.phase = "before-clusters";
floes.app.infra.resources.bucket.phase = "after-clusters";   # the default
```

    before-clusters      anything a cluster needs in order to exist
      |   create-cluster
    after-clusters       anything that needs a cluster, which is most things
      |   deploy-manifests
    after-manifests      anything that needs the workloads running

A phase boundary is not a preference. It is there because something
terraform cannot do happens in between: a cluster is created, a kubeconfig
appears, a provider that could not be configured now can be.

**Splitting for any other reason makes things worse.** Terraform orders
resources within a stack from the references between them and applies the
independent ones at the same time; catallaxy runs steps one after another.
So two resources in one stack are concurrent, and in two stacks they are
serial with a state read in between. Fewer phases is less state to manage
_and_ faster.

A lab that sets no phase has one stack and one state file, and writes
nothing to get it.

The phase is the one thing here you have to say. Whether a bucket is wanted
before the cluster or after is a fact about the world, not something in the
declaration, so a floe states it and everything else follows: which stacks
exist, what is in them, and the order they run in.

A reference pointing at a later phase is refused. The value would not exist
yet, and ordering the two the way the reference needs would put the phases
in the wrong order.

## Where state lives

One declaration covers every stack:

```nix
lab.infra.backend.s3 = { bucket = "tf-state"; key = "labs/<stack>"; };
```

The literal `<stack>` is replaced with each stack's name. Two stacks
resolving to the same key is refused: sharing one state file means each
apply reads the other's resources as things to destroy, and that is the
worst thing this can do quietly.

The default is a local file in each stack's own working directory, which
needs no configuration.

## Providers configure themselves

A resource says `provider = "aws"` and nothing else is needed. The registry
address and the version come from the nix package the lab carries, so the
rendered file records the provider that actually ran rather than a hope
about it.

Configuration is written once for the lab, per instance:

```nix
lab.infra.providers.aws.main.region = "us-east-1";
lab.infra.providers.aws.eu.region = "eu-west-1";
```

`main` is the unaliased configuration and is what a resource gets without
asking; anything else becomes a provider alias, and a resource picks one
with `instance = "eu"`. That is how one stack holds two regions, rather than
needing two stacks for something that has no lifecycle boundary in it.

Credentials are not here. A provider reads them from the environment the
apply runs in, which keeps them out of the rendered file and out of state.

Three of the packaged providers share a short name. Those are refused,
naming every candidate, and settled with
`lab.infra.stacks.<phase>.requiredProviders.<name>.source`.

## References: a value that does not exist yet

`infra.ref "backups" "arn"` is the representation of a value only the apply
will know. It resolves through the _target's_ type, so nothing referring to
a bucket has to repeat that it is a bucket:

```nix
inputs.resource = infra.ref "backups" "arn";
# renders as "${aws_s3_bucket.backups.arn}"
```

Because it is a value, a floe exports one like anything else, and another
floe depends on something neither of them can compute:

```nix
options.floes.storage.exports.bucketArn = mkOption { type = infra.refType; };
config.floes.storage.exports.bucketArn = infra.ref "backups" "arn";
```

A reference may cross a stack. It becomes a read of the producing stack's
state, and the producing stack already emits an output for every attribute
it declares:

```json
"data": { "terraform_remote_state": { "cloud": { "backend": "s3", "config": { ... } } } }
"content": "${data.terraform_remote_state.cloud.outputs.backups_arn}"
```

**That is also what orders the stacks.** A stack reading another's output
applies after it, and is destroyed before it, with nothing declared. This is
the multi-pass case: when a value cannot exist until an earlier apply has
run, say so with a reference and the passes fall out.

Two stacks referencing each other is refused, naming the cycle. Neither can
go first, and putting them in one stack lets the tool order them itself.

What is refused at eval: a reference to a resource nothing declares, to an
output the target does not declare, a cycle between stacks, and one used
inside a Kubernetes manifest.

## Getting a value into a cluster

A reference cannot go in a manifest. Interpolation syntax in a Kubernetes
resource is a literal string nothing expands, so the value has to be
materialised first:

```nix
publish.arn = { store = "runtime"; key = "BACKUP_BUCKET_ARN"; };
```

The apply writes the output into that store, and a cluster reads it back
with `secrets.subscribe`, the same channel that already carries a value one
cluster mints to another.

Which store is yours to choose, so writing to one is an interface. A `vault`
store is written over its API, with the token read from `VAULT_TOKEN` rather
than from the lab so it stays out of the rendered file and out of state.
Anything else is a command:

```nix
lab.secrets.stores.runtime = {
  backend = "external";
  writer.command = [ "my-secret-tool" "put" ];
};
```

It receives `CATA_SECRET_KEY` in the environment and the value on stdin.
Neither is an argument, so neither reaches a process listing. That is what
keeps the set of stores open: one catallaxy has never heard of is a command.

Only a `runtime` store can be published to, which
`lab.secrets.stores.<n>.direction` already answers and derives from the
backend. An `authored` store is refused: sops is a file committed to your
repository, and an apply produces values nobody wrote.

A typed Kubernetes field refuses a reference by itself, because its schema
says the field is a string. The check exists for the untyped half: Helm
values and patches accept anything, and a reference there would reach the
chart intact.

## What is checked, and by what

Two layers, and neither subsumes the other.

Catallaxy checks that a declaration is internally sound, at eval, before
anything runs: that references resolve, that stacks exist and are used, and
that two floes are not claiming one resource name.

It cannot check a declaration against reality. Nothing at eval knows whether
`aws_s3_bucket` really has an `arn`. That is the provider's schema, so the
rendered stack is run through `tofu init -backend=false && tofu validate`
with the providers as nix packages. That check caught the first version of
the fixture in this repo, which claimed a `local_file` has an `arn`.

## Where it lands

Each stack renders to `infra/<stack>/main.tf.json` in the lab package,
beside `manifests/`, and is covered by the lab's manifest digest. What would
be provisioned is reviewed in the same place, and the same way, as what
would be applied.

## Running it

A stack is three steps in the same plan as everything else: `infra-plan`,
`infra-apply` and `infra-destroy`. Ordering against clusters and manifests
is the anchor grammar, and apply defaults to running before manifests are
applied, because a manifest wanting a value from a stack is the common case.
A stack that consumes the cluster instead sets `before = [ ]`.

`cata lab up` runs the plan step and shows the full diff. It does **not**
apply unless you pass `--infra`; without it the apply is skipped and says
so. A cluster can be thrown away and rebuilt, and a cloud account cannot, so
the two do not get the same default. `cata lab destroy --infra` is the same
bargain in reverse.

Providers are nix packages, not downloads. A stack pins them by registry
address and the lab package carries an OpenTofu built with exactly those, at
`infra/bin/tofu`. There is no lock file to drift and no version that differs
between two machines, and `init` needs no network. A provider nixpkgs does
not package is refused at eval rather than at `tofu init`.

State lives in `~/.local/share/catallaxy/infra/<lab>/<stack>`, deliberately
outside the lab's state directory: `cata lab cleanup` removes that directory
wholesale, and losing a state file does not delete what it recorded, it just
makes it nobody's. Cleanup reads each stack's state and refuses while
anything is still in it.

A failed apply names the stack, the directory the tool ran in, and the exact
command to repeat by hand. State is not discarded, so a retry continues from
a partial apply rather than starting over.
