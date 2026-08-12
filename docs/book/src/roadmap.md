# Roadmap

## Next

- **`kind:` and `floe:` anchors.** Both are implemented in the graph
  resolver but inert, because the wave builder passes `null` for those
  fields. Wiring them up makes "after every CRD bundle" expressible without
  naming each one.
- **`cata images lock`.** Resolve tags to digests and write a lockfile, so
  `requireDigest` is adoptable without hand-collecting hashes.
- **Floe-declared lint checks.** `lab.lint.checks` is lab-scope only. A floe
  that knows an invariant about its own manifests cannot express it except
  as an assertion over the configuration.

## Later

- **Talos on bare metal.** `cluster.provisioner = "talos"` exists today, but
  only as Talos-in-Docker for local development, driven by `talosctl`. There
  is no provisioner module for real hardware.
- **Air-gapped registry rewriting**, rewrite every image reference to a
  mirror at render time rather than relying on containerd config.
- **Per-floe network policies**, built-in floes declaring their own
  cross-namespace allow rules when `networkPolicies.enable` is on. Today the
  default-deny lands and each floe's rules are the operator's problem.
- **Richer SBOMs.** `cluster.out.sbom` reports each enabled floe and its
  version. It does not yet read the rendered manifests, so images pinned
  inside a Helm chart's own values are not counted.

## Ideas

Not committed to, and each would want a design discussion first.

- Progressive delivery integration (Flagger or Argo Rollouts) as a
  first-class floe with typed analysis templates.
- Cost attribution from the declared topology.
