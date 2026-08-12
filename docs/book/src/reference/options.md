# Module Options

Every option a lab can set, generated from the module declarations. Each one
shows its type, default, example, and the file that declares it.

| Page                                  | Covers                                                                       |
| ------------------------------------- | ---------------------------------------------------------------------------- |
| [`lab.*`](./options/lab.md)           | the lab: identity, CD strategy, DNS, networking, secrets, images, lint, ops  |
| [`lab.steps.*`](./options/steps.md)   | a plan step you declare yourself                                             |
| [`cluster.*`](./options/cluster.md)   | one cluster: Kubernetes settings, provisioner, projections, drift, apiserver |
| [`bundles.*`](./options/bundles.md)   | one installable group of resources                                           |
| [`floes.*`](./options/floes/index.md) | one page per built-in floe                                                   |

Each page opens with an index table of every option on it, then the full
entries grouped by prefix.

## Paths

`cluster.*` and `floes.*` are set inside a `lab.clusters.<name>` submodule.
The pages spell out the full path. You write the tail.

```nix
lab.clusters.app.floes.gateway.tls   # what the page shows
floes.gateway.tls                    # what you write
```

`bundles.*` and `lab.steps.*` pages go one further and drop the entry
placeholder, so a heading reads `awaitRollout` rather than
`lab.clusters.<name>.bundles.<name>.awaitRollout`.

## Linking to an option

Anchors are the option's page-relative path, lowercased, with dots as dashes
and the punctuation stripped from `<name>` and `*` placeholders:

```markdown
[`awaitRollout`](./options/bundles.md#awaitrollout)
[`helmCharts.<name>.values`](./options/bundles.md#helmcharts-name-values)
[`cd.defaultOwner.bootstrap`](./options/lab.md#cd-defaultowner-bootstrap)
```

Two options that would slugify to the same anchor fail the docs build rather
than silently shadowing each other.

## What lives here and what does not

Generated pages own every fact the module system already knows: name, type,
default, example, declaration site, and the option's own description. Prose
pages own what it cannot see: judgement, sequencing, failure modes and
worked examples.

So a prose page should not carry a table whose cells are derivable from the
option set. If you are typing a name, type or default column, the fact
belongs in a `description` and the page should link to it instead.

`exports` fields appear alongside the rest, but they are output: a floe
computes them and you read them.
