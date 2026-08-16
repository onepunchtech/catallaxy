{
  lib,
  pkgs,
  cataWrapped,
}:

let
  net = import ./util/network.nix { inherit lib; };

  unorderedPairs =
    names: lib.concatMap (a: map (b: { inherit a b; }) (lib.filter (b: b > a) names)) names;

  proxiedHosts = lab: lab.config.lab.proxy.out.hosts or [ ];

  publicRoutedHosts =
    lab:
    lib.unique (
      lib.concatMap (
        c: map (h: h.host) (lib.filter (h: h.tier == "public") (c.cluster.out.exposedHosts or [ ]))
      ) (lib.attrValues lab.config.lab.out.allClusters)
    );

  meshClientsOf =
    labName: lab:
    lib.mapAttrsToList
      (clusterName: c: {
        where = "${labName}/${clusterName}";
        inherit (c.floes.netbird.client) wireguardPort interfaceName;
      })
      (
        lib.filterAttrs (
          _: c: (c.floes.netbird.enable or false) && (c.floes.netbird.operator.enable or false)
        ) lab.config.lab.clusters
      );

  mkLabChecks =
    {
      labs,
      snapshotLabs ? labs,
      snapshotDir ? null,
    }:
    let
      labNames = builtins.attrNames labs;

      evalChecks = lib.mapAttrs' (
        name: lab:
        lib.nameValuePair "${name}-eval" (
          pkgs.runCommand "${name}-eval" { } ''
            cat > /dev/null <<'JSON'
            ${builtins.toJSON lab.config.lab.out.manifests}
            JSON
            echo "${name} evaluated" > $out
          ''
        )
      ) labs;

      lintChecks = lib.mapAttrs' (
        name: lab:
        lib.nameValuePair "${name}-lint" (
          pkgs.runCommand "${name}-lint" { nativeBuildInputs = [ cataWrapped ]; } ''
            cata lab lint --path ${lab.config.lab.out.package}
            touch $out
          ''
        )
      ) labs;

      subnetOf = name: labs.${name}.config.lab.network.dockerSubnet;

      subnetOverlaps = lib.filter ({ a, b }: net.cidrsOverlap (subnetOf a) (subnetOf b)) (
        unorderedPairs labNames
      );

      meshClients = lib.concatLists (lib.mapAttrsToList meshClientsOf labs);

      meshPortClashes = lib.concatMap (
        a: lib.filter (b: b.where > a.where && b.wireguardPort == a.wireguardPort) meshClients
      ) meshClients;

      meshIfaceClashes = lib.filter (
        n: lib.count (m: m == n) (map (c: c.interfaceName) meshClients) > 1
      ) (lib.unique (map (c: c.interfaceName) meshClients));

      unproxiedHosts = lib.concatLists (
        lib.mapAttrsToList (
          name: lab:
          if !(lab.config.lab.proxy.enable or false) then
            [ ]
          else
            let
              proxied = proxiedHosts lab;
            in
            map (h: "  ${name}: ${h}") (lib.filter (h: !(builtins.elem h proxied)) (publicRoutedHosts lab))
        ) labs
      );

      planSnapshotCheck =
        labName: lab: direction:
        let
          out = lab.config.lab.out;
          plan = if direction == "teardown" then out.teardownPlan else out.deploymentPlan;
          planJson = pkgs.writeText "plan-${labName}-${direction}.json" (builtins.toJSON plan);
          fixture = snapshotDir + "/${labName}.${direction}.expected.txt";
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
                > ${toString snapshotDir}/${labName}.${direction}.expected.txt
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
              value = planSnapshotCheck labName snapshotLabs.${labName} direction;
            })
            [
              "deploy"
              "teardown"
            ]
        ) (builtins.attrNames snapshotLabs)
      );

      subnetReport = lib.concatMapStringsSep "\n" (
        { a, b }: "  ${a} (${subnetOf a}) overlaps ${b} (${subnetOf b})"
      ) subnetOverlaps;

      meshReport = lib.concatMapStringsSep "\n" (
        c: "  ${c.where}: port ${toString c.wireguardPort}, iface ${c.interfaceName}"
      ) meshClients;
    in
    evalChecks
    // lintChecks
    // lib.optionalAttrs (snapshotDir != null) planSnapshotChecks
    // {
      lab-subnets = pkgs.runCommand "lab-subnets" { } ''
        if [ ${toString (builtins.length subnetOverlaps)} -ne 0 ]; then
          cat >&2 <<'EOF'
        These labs claim overlapping docker subnets:
        ${subnetReport}

        A docker network owns its subnet exclusively, so the second lab to
        come up fails at network creation. Give each lab its own /16 via
        `lab.network.dockerSubnet`.
        EOF
          exit 1
        fi
        echo "docker subnets are pairwise distinct" > $out
      '';

      lab-mesh-ports = pkgs.runCommand "lab-mesh-ports" { } ''
        if [ ${if meshPortClashes != [ ] || meshIfaceClashes != [ ] then "1" else "0"} -ne 0 ]; then
          cat >&2 <<'EOF'
        These labs' host netbird clients collide:
        ${meshReport}

        Two daemons cannot share a WireGuard port or an interface name.
        Set `floes.netbird.client.wireguardPort`, and `interfaceName` if
        you overrode it, per lab.
        EOF
          exit 1
        fi
        echo "mesh clients are pairwise distinct" > $out
      '';

      lab-routed-hosts-are-proxied = pkgs.runCommand "lab-routed-hosts-are-proxied" { } ''
        if [ ${toString (builtins.length unproxiedHosts)} -ne 0 ]; then
          cat >&2 <<'EOF'
        These hostnames have a public route inside a cluster, but the lab
        proxy has no backend for them, so a request from the operator's
        machine reaches the proxy's default backend and gets a 503:

        ${lib.concatStringsSep "\n" unproxiedHosts}

        The proxy builds its host map from each floe's `domain` and
        `gateway.domain`. A floe naming its hostname anywhere else is
        invisible to it.
        EOF
          exit 1
        fi
        echo "every publicly routed host has a proxy backend" > $out
      '';
    };
in
{
  inherit mkLabChecks;
}
