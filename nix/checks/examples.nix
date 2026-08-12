{
  lib,
  pkgs,
  cataWrapped,
  exampleLabDefs,
}:

let
  net = import ../../lib/util/network.nix { inherit lib; };

  labNames = builtins.attrNames exampleLabDefs;

  subnetOf = labName: exampleLabDefs.${labName}.config.lab.network.dockerSubnet;

  unorderedPairs =
    names: lib.concatMap (a: map (b: { inherit a b; }) (lib.filter (b: b > a) names)) names;

  subnetOverlaps = lib.filter ({ a, b }: net.cidrsOverlap (subnetOf a) (subnetOf b)) (
    unorderedPairs labNames
  );

  meshClients = lib.concatMap (
    labName:
    lib.mapAttrsToList
      (clusterName: c: {
        lab = "${labName}/${clusterName}";
        inherit (c.floes.netbird.client) wireguardPort interfaceName;
      })
      (
        lib.filterAttrs (
          _: c: (c.floes.netbird.enable or false) && (c.floes.netbird.operator.enable or false)
        ) exampleLabDefs.${labName}.config.lab.clusters
      )
  ) labNames;

  meshPortClashes = lib.concatMap (
    a: lib.filter (b: b.lab > a.lab && b.wireguardPort == a.wireguardPort) meshClients
  ) meshClients;

  meshIfaceClashes = lib.filter (
    n: lib.count (m: m == n) (map (c: c.interfaceName) meshClients) > 1
  ) (lib.unique (map (c: c.interfaceName) meshClients));

  planSnapshotCheck =
    labName: direction:
    let
      out = exampleLabDefs.${labName}.config.lab.out;
      plan = if direction == "teardown" then out.teardownPlan else out.deploymentPlan;
      planJson = pkgs.writeText "plan-${labName}-${direction}.json" (builtins.toJSON plan);
      fixture = ../../examples/labs/tests/plan-snapshots + "/${labName}.${direction}.expected.txt";
    in
    pkgs.runCommand "plan-snapshot-${labName}-${direction}"
      {
        nativeBuildInputs = [
          cataWrapped
          pkgs.diffutils
        ];
      }
      ''
        cata lab plan --stable --from-file ${planJson} > actual.txt
        if ! diff -u ${fixture} actual.txt; then
          cat >&2 <<EOF

        Plan snapshot for ${labName}/${direction} diverged from
        the committed fixture. If the diff above is intentional,
        refresh it:

          cata --flake . lab plan ${labName} --stable ${
            lib.optionalString (direction == "teardown") "--teardown "
          }\
            > examples/labs/tests/plan-snapshots/${labName}.${direction}.expected.txt
        EOF
          exit 1
        fi
        echo "plan snapshot ${labName}/${direction} matches" > $out
      '';

  planSnapshotChecks = lib.listToAttrs (
    lib.concatMap (
      labName:
      map
        (direction: {
          name = "plan-snapshot-${labName}-${direction}";
          value = planSnapshotCheck labName direction;
        })
        [
          "deploy"
          "teardown"
        ]
    ) labNames
  );

  lintChecks = lib.mapAttrs' (
    name: lab:
    lib.nameValuePair "${name}-lint" (
      pkgs.runCommand "${name}-lint" { nativeBuildInputs = [ cataWrapped ]; } ''
        cata lab lint --path ${lab.config.lab.out.package}
        touch $out
      ''
    )
  ) exampleLabDefs;
in
{
  example-lab-subnets =
    let
      report = lib.concatMapStringsSep "\n" (
        { a, b }: "  ${a} (${subnetOf a}) overlaps ${b} (${subnetOf b})"
      ) subnetOverlaps;
    in
    pkgs.runCommand "example-lab-subnets" { } ''
      if [ ${toString (builtins.length subnetOverlaps)} -ne 0 ]; then
        cat >&2 <<'EOF'
      Example labs claim overlapping docker subnets:
      ${report}

      Give each lab its own /16 via `lab.network.dockerSubnet`
      in its env module, and record it in the table in
      examples/labs/README.md.
      EOF
        exit 1
      fi
      echo "example lab docker subnets are pairwise distinct" > $out
    '';

  example-lab-mesh-ports =
    let
      ports = lib.concatMapStringsSep "\n" (
        c: "  ${c.lab}: port ${toString c.wireguardPort}, iface ${c.interfaceName}"
      ) meshClients;
      clashing = meshPortClashes != [ ] || meshIfaceClashes != [ ];
    in
    pkgs.runCommand "example-lab-mesh-ports" { } ''
      if [ ${if clashing then "1" else "0"} -ne 0 ]; then
        cat >&2 <<'EOF'
      Example labs' host netbird clients collide:
      ${ports}

      Two daemons cannot share a WireGuard port or an interface
      name. Set `floes.netbird.client.wireguardPort` (and
      `interfaceName` if you overrode it) per lab, and record it
      in the table in examples/labs/README.md.
      EOF
        exit 1
      fi
      echo "example lab mesh clients are pairwise distinct" > $out
    '';
}
// planSnapshotChecks
// lintChecks
