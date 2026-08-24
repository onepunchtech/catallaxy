{
  exampleLabDefs,
  fixtureLabs,
  mkLabChecks,
}:

mkLabChecks {
  labs = exampleLabDefs;
  snapshotLabs = exampleLabDefs // fixtureLabs;
  snapshotDir = ../../examples/labs/tests/plan-snapshots;
  digestDir = ../../examples/labs/tests/manifest-digests;
}
