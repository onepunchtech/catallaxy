# Roadmap

## Later

- **Talos on bare metal.** `cluster.provisioner = "talos"` exists today, but
  only as Talos-in-Docker for local development, driven by `talosctl`. There
  is no provisioner module for real hardware.

- **Exercise OpenBao outside `dev` mode.** `standalone` and `ha` initialise
  themselves, mount their KV engine and hand external-secrets a scoped
  token, but no lab in the repo runs either, because both need a real KMS or
  transit seal to unseal and CI can reach neither. They are covered by unit
  tests and nothing else.

  `lib/tests/self-contained.nix` will not catch that: eligibility is
  computed from five things and `floes.openbao.mode` is invisible to all of
  them, so a lab could be marked self-contained while its vault cannot
  unseal. Either teach it about sealing, or stand up a transit seal against
  a second in-cluster OpenBao so a self-contained lab can run one.

## Ideas

Not committed to, and each would want a design discussion first.

- Progressive delivery integration (Flagger or Argo Rollouts) as a
  first-class floe with typed analysis templates.
- Cost attribution from the declared topology.
- multizone/multiregion solutions for doing hot cold or hot hot deployments
  across geographic regions.
  - syncing databases between
  - syncing file systems like seaweedfs

- managing breaking changes when clusters depend on older version of
  catallaxy
  - migration guide? Or something built in/automatic
