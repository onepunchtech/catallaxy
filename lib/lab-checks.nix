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

  hostPortsOf =
    labName: lab:
    let
      cfg = lab.config.lab;
      claim = option: port: {
        where = labName;
        inherit option port;
      };
    in
    lib.optional (cfg.proxy.enable or false) (claim "lab.proxy.httpPort" cfg.proxy.httpPort)
    ++ lib.optional ((cfg.proxy.enable or false) && (cfg.proxy.tls.enable or true)) (
      claim "lab.proxy.httpsPort" cfg.proxy.httpsPort
    )
    ++ lib.optional (cfg.registry.enable or false) (claim "lab.registry.port" cfg.registry.port)
    ++ lib.optional (cfg.dns.enable or false) (claim "lab.dns.hostPort" cfg.dns.hostPort)
    ++ lib.optional (cfg.egress.enable or false) (claim "lab.egress.port" cfg.egress.port);

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
      digestDir ? null,
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

      # What a lab renders, file by file, so a refactor can claim it changed
      # nothing without standing the lab up. `evalChecks` above forces the
      # manifests and throws them away, which proves they evaluate and nothing
      # about what they say.
      #
      # Store hashes are normalised the way `lab plan --stable` normalises
      # them: a chart rebuilt from a newer nixpkgs is not a change to what the
      # lab declares, and a fixture that moved on every input bump would be
      # refreshed without being read.
      manifestDigestCheck =
        labName: lab:
        let
          fixture = digestDir + "/${labName}.digest.txt";
        in
        pkgs.runCommand "manifest-digest-${labName}"
          {
            nativeBuildInputs = [
              pkgs.diffutils
              pkgs.coreutils
            ];
          }
          ''
            cd ${lab.config.lab.out.package}
            find -L . -type f | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do
              hash=$(sed 's|/nix/store/[a-z0-9]\{32\}-|/nix/store/HASH-|g' "$f" \
                | sha256sum | cut -d' ' -f1)
              printf '%s  %s\n' "$hash" "$f"
            done > $TMPDIR/actual.txt

            if ! diff -u ${fixture} $TMPDIR/actual.txt; then
              cat >&2 <<EOF

            What ${labName} renders no longer matches the committed digest.
            Each line above names one file that appeared, vanished or changed.

            A refactor that meant to change nothing should show no diff here.
            If the diff is intentional, refresh it:

              nix run .#refresh-digests
            EOF
              exit 1
            fi
            echo "manifest digest ${labName} matches" > $out
          '';

      manifestDigestChecks = lib.mapAttrs' (
        name: lab: lib.nameValuePair "manifest-digest-${name}" (manifestDigestCheck name lab)
      ) snapshotLabs;

      declaredBundleChecks = lib.mapAttrs' (
        name: lab:
        lib.nameValuePair "${name}-declared-bundles" (
          pkgs.runCommand "${name}-declared-bundles" { } ''
            pkg=${lab.config.lab.out.package}
            status=0

            for declared in $(find -L "$pkg" -name .declared-bundles); do
              cluster=$(basename "$(dirname "$declared")")
              grep -v '^[[:space:]]*$' "$declared" | sort -u > declared.txt
              find -L "$pkg" -path "*/$cluster/*" -name '*.yaml' -print0 \
                | xargs -0 -r grep -h 'catallaxy.io/bundle:' \
                | sed 's/.*catallaxy\.io\/bundle: *//' | tr -d '"' | sort -u > seen.txt

              undeclared=$(comm -23 seen.txt declared.txt)
              if [ -n "$undeclared" ]; then
                status=1
                cat >&2 <<EOF

            ${name}, cluster '$cluster': these bundle labels reach a resource
            but are missing from .declared-bundles:

            $(printf '  %s\n' $undeclared)
            EOF
              fi
            done

            if [ "$status" -ne 0 ]; then
              cat >&2 <<'EOF'

            `lab up` prunes anything carrying this lab's label whose bundle the
            declaration no longer names, so a bundle key that reaches a resource
            without reaching .declared-bundles deletes that resource on the next
            run. Add it in `declaredBundlesOf`, the way the synthetic
            `namespaces` bundle and each strategy's `deliveryBundle` are.
            EOF
              exit 1
            fi

            echo "every bundle label is declared" > $out
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

      # Every range a lab makes docker own, not just its own bridge. A Talos
      # cluster gets a second network that talosctl creates, and
      # `provisioner.talos.subnet` defaults to the same 10.5.0.0/24 for every
      # Talos cluster ever declared, so two of them overlap by default. Its
      # own docstring says it must not, and nothing enforced that.
      subnetsOf =
        name:
        let
          lab = labs.${name}.config.lab;
        in
        [
          {
            option = "lab.network.dockerSubnet";
            cidr = lab.network.dockerSubnet;
          }
        ]
        ++ lib.concatMap (
          c:
          lib.optional (c.cluster.provisioner == "talos") {
            option = "provisioner.talos.subnet";
            cidr = c.provisioner.talos.subnet;
          }
        ) (lib.attrValues lab.out.allClusters);

      claimedSubnets = lib.concatLists (
        map (name: map (s: s // { where = name; }) (subnetsOf name)) labNames
      );

      subnetOverlaps = lib.concatMap (
        a:
        lib.filter (
          b:
          (b.where > a.where || (b.where == a.where && b.option > a.option)) && net.cidrsOverlap a.cidr b.cidr
        ) claimedSubnets
      ) claimedSubnets;

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
        b:
        "  ${b.where} (${b.option} = ${b.cidr}) overlaps "
        + lib.concatMapStringsSep ", " (a: "${a.where} (${a.option} = ${a.cidr})") (
          lib.filter (a: a != b && net.cidrsOverlap a.cidr b.cidr) claimedSubnets
        )
      ) subnetOverlaps;

      hostPorts = lib.concatLists (lib.mapAttrsToList hostPortsOf labs);

      hostPortClashes = lib.concatMap (
        a: lib.filter (b: b.where > a.where && b.port == a.port) hostPorts
      ) hostPorts;

      hostPortReport = lib.concatMapStringsSep "\n" (
        port:
        "  port ${toString port}: "
        + lib.concatMapStringsSep ", " (c: "${c.where} (${c.option})") (
          lib.filter (c: c.port == port) hostPorts
        )
      ) (lib.unique (map (c: c.port) hostPortClashes));

      meshReport = lib.concatMapStringsSep "\n" (
        c: "  ${c.where}: port ${toString c.wireguardPort}, iface ${c.interfaceName}"
      ) meshClients;
    in
    evalChecks
    // lintChecks
    // declaredBundleChecks
    // lib.optionalAttrs (snapshotDir != null) planSnapshotChecks
    // lib.optionalAttrs (digestDir != null) manifestDigestChecks
    // {
      lab-subnets = pkgs.runCommand "lab-subnets" { } ''
        if [ ${toString (builtins.length subnetOverlaps)} -ne 0 ]; then
          cat >&2 <<'EOF'
        These labs claim overlapping docker subnets:
        ${subnetReport}

        A docker network owns its subnet exclusively, so the second lab to
        come up fails at network creation. Give each range its own space:
        `lab.network.dockerSubnet` for the lab's bridge, and
        `provisioner.talos.subnet` for the network talosctl makes, which
        defaults to the same value for every Talos cluster.
        EOF
          exit 1
        fi
        echo "docker subnets are pairwise distinct" > $out
      '';

      lab-host-ports = pkgs.runCommand "lab-host-ports" { } ''
        if [ ${toString (builtins.length hostPortClashes)} -ne 0 ]; then
          cat >&2 <<'EOF'
        These labs want the same host ports:
        ${hostPortReport}

        Two containers cannot bind one host port, so the second lab to come
        up is refused. Everything else about a lab is already named after it
        and does not clash; the ports are the one thing a lab has to be given
        on purpose. Set them per lab:

          lab.proxy.httpPort, lab.proxy.httpsPort,
          lab.registry.port, lab.dns.hostPort
        EOF
          exit 1
        fi
        echo "host ports are pairwise distinct" > $out
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
