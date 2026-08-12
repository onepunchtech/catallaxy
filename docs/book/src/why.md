# Why Catallaxy

Kubernetes platform engineering has an accidental complexity problem: YAML
sprawl across environments, deployment ordering that lives in tribal
knowledge, brittle bash glue that breaks silently, and a bootstrap
chicken-and-egg that someone solves by hand every time.

Catallaxy treats the platform as a compilation problem. You declare
components in typed Nix modules, and the system resolves them into exactly
the manifests each cluster needs.

## What it replaces

| Problem                                                                                                                                           | What Catallaxy does                                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| YAML sprawl: values files, overlays and patches, duplicated with variations                                                                       | Composable Nix expressions cover every component, cluster and environment                                                            |
| Charts don't compose: a chart is a bag of templates with no interface, so an umbrella chart wires subcharts through global values and alias hacks | A [floe](./understanding/floes.md) publishes a typed interface its peers read, so two components that must agree are checked at eval |
| Patching: when a chart does not expose what you need, you fork it or bolt on a post-renderer                                                      | Options are the extension point, and every floe carries an `overrides` escape hatch, so customizing is not forking                   |
| Tribal knowledge: install order lives in someone's head or a stale runbook                                                                        | Each part declares what it needs and offers, and the install graph is computed at build time                                         |
| Brittle glue: bash, retry loops and sleeps papering over ordering bugs                                                                            | Cross-cluster references resolve by lazy evaluation, so there is no runtime discovery                                                |
| Manual bootstrap: the management cluster was clicked into existence by hand                                                                       | The management plane is declared like everything it manages, so rebuilding it is a build                                             |
| No type safety: a misspelled Helm value is silently ignored                                                                                       | Options are typed from OpenAPI specs and CRD schemas, so errors surface at `nix eval`                                                |
| Unpinned inputs: dependency ranges and mutable image tags let a rebuild drift                                                                     | Every input is locked by hash and rendering is pure, so the same inputs give the same store path                                     |
| Strategy lock-in: changing deploy target means rewriting component code                                                                           | The same declarations compile to kapp, ArgoCD or Fleet, and switching is one option change                                           |

## Who this is for

Platform engineers running multi-cluster Kubernetes who want it defined in
code that is typed, reproducible and reviewable, and who are comfortable
with Nix or willing to learn it.
