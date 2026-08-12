{
  description = "catallaxy: declarative Kubernetes platform management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    nix-kube-generators.url = "github:farcaller/nix-kube-generators";

    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nix-kube-generators,
      crane,
      rust-overlay,
      treefmt-nix,
    }:
    let
      lib = nixpkgs.lib;
      pureLib = import ./lib/pure.nix { inherit lib; };
    in
    {
      nixosModules.default =
        { ... }:
        {
          imports = [ ./modules ];
        };

      lib = pureLib;

      templates.consumer = {
        path = ./templates/consumer;
        description = "A catallaxy consumer flake with a custom floe";
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        rustToolchain = pkgs.rust-bin.stable.latest.default;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
          programs.rustfmt = {
            enable = true;
            package = rustToolchain;
            edition = "2024";
          };
          programs.yamlfmt.enable = true;

          programs.prettier.enable = true;
          programs.prettier.settings = {
            proseWrap = "always";
            printWidth = 76;
          };
          settings.formatter.prettier = {
            includes = lib.mkForce [ "*.md" ];
            excludes = [ "docs/book/src/SUMMARY.md" ];
          };
        };

        kubelib = nix-kube-generators.lib { inherit pkgs; };
        cataCharts = import ./lib/charts.nix { inherit lib pkgs kubelib; };
        k8sSpecs = import ./lib/k8s-specs.nix { inherit lib pkgs cataCharts; };

        packages' = import ./pkgs {
          inherit
            self
            lib
            pkgs
            craneLib
            rustToolchain
            cataCharts
            k8sSpecs
            ;
        };

        labs = import ./lib/labs.nix {
          inherit
            lib
            pkgs
            pureLib
            cataCharts
            k8sSpecs
            ;
          modulesPath = ./modules;
          examplesPath = ./examples/labs;

          inherit (packages') tools;
          inherit (packages') cataWrapped;
        };

        exampleLabDefs = labs.discoverExampleLabs;

      in
      {

        legacyPackages = {
          mkLab = labs.mkLab;

          mkLabShell = labs.mkLabShell;
          inherit (packages') tools;
          labs = lib.mapAttrs (_: lab: lab.config.lab.out.cliConfig) exampleLabDefs;
          e2eLabs = lib.mapAttrs (_: lab: lab.config.lab.out.selfContained) exampleLabDefs;
          labPackages = lib.mapAttrs (_: lab: lab.config.lab.out.package) exampleLabDefs;
          charts = cataCharts;
          inherit (labs) k8sTypegenConfig;
        };

        packages = {
          default = packages'.cataWrapped;
          cata = packages'.cataWrapped;
          cata-unwrapped = packages'.cata;
          e2e = packages'.e2e;
          option-docs = packages'.optionDocs;
          docs = packages'.docs;
        };

        apps = {
          default = {
            type = "app";
            program = "${packages'.cataWrapped}/bin/cata";
          };
          cata = {
            type = "app";
            program = "${packages'.cataWrapped}/bin/cata";
          };
          e2e = {
            type = "app";
            program = "${packages'.e2e}/bin/cata-e2e";
          };
          generate-k8s-types =
            let
              configFile = pkgs.writeText "k8s-typegen-config.json" (builtins.toJSON labs.k8sTypegenConfig);
            in
            {
              type = "app";
              program = toString (
                pkgs.writeShellScript "generate-k8s-types" ''
                  set -euo pipefail
                  exec ${packages'.cataWrapped}/bin/cata generate ${configFile}
                ''
              );
            };
        }
        // lib.concatMapAttrs (
          name: lab:
          let
            opsTool = lab.config.lab.ops.out.tool;
          in
          lib.optionalAttrs (opsTool != null) {
            "${name}-ops" = {
              type = "app";
              program = "${opsTool}/bin/${name}-ops";
            };
          }
        ) exampleLabDefs;

        devShells = lib.mapAttrs (_: lab: labs.mkLabShell lab) exampleLabDefs // {
          default = pkgs.mkShell {
            packages = packages'.tools ++ [

              packages'.cataWrapped
              rustToolchain
              pkgs.bacon
              pkgs.rust-analyzer
              pkgs.mdbook
              pkgs.mdbook-mermaid

              (pkgs.writeShellScriptBin "cata-dev" ''
                exec cargo run --manifest-path "''${CATALLAXY_ROOT:-$(git rev-parse --show-toplevel)}/cli/Cargo.toml" -- "$@"
              '')
            ];
            shellHook = ''
              echo "catallaxy dev shell"
              echo "  cata                 # released CLI"
              echo "  cata-dev             # run CLI from source (cargo build + run)"
              echo "  cargo build          # build CLI"
              echo "  bacon                # watch + rebuild on change"
              echo "  nix build .#docs     # build the book"
              echo "  nix develop .#<lab>  # a lab's tools + its CA trust"
            '';
          };
        };

        formatter = treefmtEval.config.build.wrapper;

        checks =
          let
            net = import ./lib/util/network.nix { inherit lib; };

            planSnapshotCheck =
              labName: direction:
              let
                out = exampleLabDefs.${labName}.config.lab.out;
                plan = if direction == "teardown" then out.teardownPlan else out.deploymentPlan;
                planJson = pkgs.writeText "plan-${labName}-${direction}.json" (builtins.toJSON plan);
                fixture = ./examples/labs/tests/plan-snapshots + "/${labName}.${direction}.expected.txt";
              in
              pkgs.runCommand "plan-snapshot-${labName}-${direction}"
                {
                  nativeBuildInputs = [
                    packages'.cataWrapped
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
              ) (builtins.attrNames exampleLabDefs)
            );

            subnetOf = labName: exampleLabDefs.${labName}.config.lab.network.dockerSubnet;

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
            ) (builtins.attrNames exampleLabDefs);

            meshPortClashes =
              let
                pairs = lib.concatMap (
                  a: lib.filter (b: b.lab > a.lab && b.wireguardPort == a.wireguardPort) meshClients
                ) meshClients;
              in
              pairs;

            meshIfaceClashes = lib.filter (
              n: lib.count (m: m == n) (map (c: c.interfaceName) meshClients) > 1
            ) (lib.unique (map (c: c.interfaceName) meshClients));

            subnetOverlaps =
              let
                names = builtins.attrNames exampleLabDefs;
                pairs = lib.concatMap (a: map (b: { inherit a b; }) (lib.filter (b: b > a) names)) names;
              in
              lib.filter ({ a, b }: net.cidrsOverlap (subnetOf a) (subnetOf b)) pairs;
          in
          {
            cli = packages'.cataWrapped;

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
            formatting = treefmtEval.config.build.check self;

            docs = packages'.docs;

            docs-options-nav = pkgs.runCommand "docs-options-nav" { } ''
              missing=""
              while read -r page; do
                [ -f "${packages'.optionDocs}/$page" ] || missing="$missing $page"
              done < <(grep -oE '\]\(\./reference/(options|cli)/[^)]+\)' \
                         ${packages'.optionDocs}/SUMMARY.md \
                       | sed 's|](\./reference/||; s|)||')

              if [ -n "$missing" ]; then
                echo "SUMMARY.md links option pages the generator did not emit:" >&2
                for p in $missing; do echo "  $p" >&2; done
                exit 1
              fi
              echo "every generated option page linked from SUMMARY.md exists" > $out
            '';

            docs-option-links = pkgs.runCommand "docs-option-links" { } ''
              broken=""
              while read -r link; do
                page="''${link%%#*}"
                id="''${link##*#}"
                target="${packages'.optionDocs}/options/$page"
                if [ ! -f "$target" ] || ! grep -qF "{#$id}" "$target"; then
                  broken="$broken $link"
                fi
              done < <(grep -rhoE '\./options/[a-z/]+\.md#[a-z0-9-]+' \
                         ${./docs/book/src} ${packages'.stepKindDocs} --include='*.md' \
                       | sed 's|\./options/||' | sort -u)

              if [ -n "$broken" ]; then
                echo "prose links to option anchors that do not exist:" >&2
                for l in $broken; do echo "  ./options/$l" >&2; done
                echo "" >&2
                echo "Anchors come from cli/src/docs/options.rs::anchor." >&2
                echo "Check the real one with:" >&2
                echo "  nix build .#option-docs && grep -oE '\\{#[a-z0-9-]+\\}' result/<page>.md" >&2
                exit 1
              fi
              echo "every option deep link resolves" > $out
            '';

            option-descriptions =
              pkgs.runCommand "option-descriptions" { nativeBuildInputs = [ pkgs.diffutils ]; }
                ''
                  if ! diff -u ${./docs/book/undescribed-options.txt} \
                          ${packages'.optionDocs}/undescribed.txt > drift.txt; then
                    cat >&2 <<'EOF'

                  Options without a `description` changed.

                  Lines prefixed `+` are options you added or renamed that have no
                  description. Give them one: the description is the API's
                  documentation and renders into the options book.

                  Lines prefixed `-` are options that gained a description or went
                  away. Refresh the baseline so it can only ever shrink:

                    nix build .#option-docs
                    install -m 644 result/undescribed.txt docs/book/undescribed-options.txt

                  EOF
                    cat drift.txt >&2
                    exit 1
                  fi
                  echo "undescribed options match the baseline" > $out
                '';

            template-consumer =
              let
                myFloes = import ./templates/consumer/floes {
                  inherit lib;
                  inherit (pureLib.floe) mkFloe;
                };
                lab = labs.mkLab {
                  modules = [ (import ./templates/consumer/lab.nix { inherit myFloes; }) ];
                };
                forced = builtins.toJSON lab.config.lab.out.manifests;
              in
              pkgs.runCommand "template-consumer" { } ''
                cat > /dev/null <<'JSON'
                ${forced}
                JSON
                echo "templates/consumer evaluated" > $out
              '';

            coredns-internal =
              let
                results = import ./lib/tests/coredns-internal.nix { inherit lib; };
              in
              pkgs.runCommand "coredns-internal-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "coredns-internal tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            k8s-helpers =
              let
                results = import ./lib/tests/k8s-helpers.nix { inherit lib; };
              in
              pkgs.runCommand "k8s-helpers-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "k8s-helpers tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            idempotent-job =
              let
                results = import ./lib/tests/util-idempotent-job.nix { inherit lib; };
              in
              pkgs.runCommand "idempotent-job-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "idempotent-job tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            wait-helpers =
              let
                results = import ./lib/tests/util-wait.nix { inherit lib; };
              in
              pkgs.runCommand "wait-helpers-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "wait-helpers tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            drift-lowering =
              let
                results = import ./lib/tests/drift.nix { inherit lib; };
              in
              pkgs.runCommand "drift-lowering-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "drift-lowering tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-boundary =
              let
                results = import ./lib/tests/floes/boundary.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-boundary-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe boundary VIOLATED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-exports-defaults =
              let
                results = import ./lib/tests/floes/exports-defaults.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-exports-defaults-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-exports-defaults tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            self-contained =
              let
                e2eLabs = lib.mapAttrs (_: lab: lab.config.lab.out.selfContained) exampleLabDefs;
                results = import ./lib/tests/self-contained.nix { inherit lib e2eLabs; };
              in
              pkgs.runCommand "self-contained-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "self-contained tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            step-kinds-conformance =
              let
                schema = import ./lib/eval/step-kind-schema.nix { inherit lib; };
                emitted = pkgs.writeText "step-kinds.json" (builtins.toJSON schema);
              in
              pkgs.runCommand "step-kinds-conformance"
                {
                  nativeBuildInputs = [
                    pkgs.python3
                    pkgs.diffutils
                  ];
                }
                ''
                  python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open("expected.json","w"), indent=2, sort_keys=True); open("expected.json","a").write("\n")' ${emitted}
                  if ! diff -u ${./cli/tests/fixtures/step-kinds.json} expected.json; then
                    cat >&2 <<EOF

                  cli/tests/fixtures/step-kinds.json no longer matches
                  modules/lab/planner/kinds/. The Rust conformance tests read
                  that fixture, so a stale one lets the two sides drift.
                  Refresh it:

                    nix build .#checks.${system}.step-kinds-conformance
                  EOF
                    exit 1
                  fi
                  cp expected.json $out
                '';

            plan-graph =
              let
                results = import ./lib/tests/plan-graph.nix { inherit lib; };
              in
              pkgs.runCommand "plan-graph-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "plan-graph tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            manifest-graph =
              let
                results = import ./lib/tests/manifest-graph.nix { inherit lib; };
              in
              pkgs.runCommand "manifest-graph-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "manifest-graph tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            manifest-autoedges =
              let
                results = import ./lib/tests/manifest-autoedges.nix { inherit lib; };
              in
              pkgs.runCommand "manifest-autoedges-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "manifest-autoedges tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            manifest-projections =
              let
                results = import ./lib/tests/manifest-projections.nix { inherit lib; };
              in
              pkgs.runCommand "manifest-projections-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "manifest-projections tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            mk-floe =
              let
                results = import ./lib/tests/floe/mk-floe.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "mk-floe-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "mk-floe tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            contracts-oidc =
              let
                results =
                  import ./lib/tests/contracts/oidc-scopes.nix { inherit lib pkgs; }
                  ++ import ./lib/tests/contracts/oidc-client-type.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "contracts-oidc-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "contracts-oidc tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-kanidm =
              let
                results = import ./lib/tests/floes/kanidm.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-kanidm-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-kanidm tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-netbird =
              let
                results = import ./lib/tests/floes/netbird.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-netbird-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-netbird tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-custom =
              let
                results = import ./lib/tests/floes/custom.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-custom-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-custom tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-argocd =
              let
                results = import ./lib/tests/floes/argocd.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-argocd-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-argocd tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-cert-manager =
              let
                results = import ./lib/tests/floes/cert-manager.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-cert-manager-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-cert-manager tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-trust-manager =
              let
                results = import ./lib/tests/floes/trust-manager.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-trust-manager-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-trust-manager tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-cnpg =
              let
                results = import ./lib/tests/floes/cnpg.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-cnpg-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-cnpg tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-prometheus =
              let
                results = import ./lib/tests/floes/prometheus.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-prometheus-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-prometheus tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-tempo =
              let
                results = import ./lib/tests/floes/tempo.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-tempo-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-tempo tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-loki =
              let
                results = import ./lib/tests/floes/loki.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-loki-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-loki tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-kaniop =
              let
                results = import ./lib/tests/floes/kaniop.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-kaniop-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-kaniop tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-gateway =
              let
                results = import ./lib/tests/floes/gateway.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-gateway-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-gateway tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-forgejo =
              let
                results = import ./lib/tests/floes/forgejo.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-forgejo-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-forgejo tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-grafana =
              let
                results = import ./lib/tests/floes/grafana.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-grafana-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-grafana tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-harbor =
              let
                results = import ./lib/tests/floes/harbor.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-harbor-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-harbor tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-zot =
              let
                results = import ./lib/tests/floes/zot.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-zot-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-zot tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-external-dns =
              let
                results = import ./lib/tests/floes/external-dns.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-external-dns-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-external-dns tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-velero =
              let
                results = import ./lib/tests/floes/velero.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-velero-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-velero tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-openebs =
              let
                results = import ./lib/tests/floes/openebs.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-openebs-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-openebs tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-seaweedfs =
              let
                results = import ./lib/tests/floes/seaweedfs.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-seaweedfs-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-seaweedfs tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-redis-operator =
              let
                results = import ./lib/tests/floes/redis-operator.nix { inherit lib pkgs; };
              in
              pkgs.runCommand "floe-redis-operator-tests" { } ''
                cat <<'EOF' > $out
                ${builtins.toJSON results}
                EOF
                if [ ${toString (builtins.length results)} -ne 0 ]; then
                  echo "floe-redis-operator tests FAILED:" >&2
                  cat $out >&2
                  exit 1
                fi
              '';

            floe-hello =
              let

                helloOutputs = (import ./examples/floes/hello-floe/flake.nix).outputs {
                  self = {
                    floes = helloOutputs.flake.floes or { };
                  };
                  catallaxy = {
                    lib.floe = pureLib.floe;
                  };
                  inherit nixpkgs;
                  flake-parts.lib.mkFlake = _: cfg: cfg;
                };

                result = pureLib.floe.evalFloe {
                  floe = helloOutputs.flake.floes.hello;
                  cluster = {
                    floes.hello.enable = true;
                  };
                };
                resourceCount = builtins.length (lib.attrNames (result.manifests.hello.resources or { }));
              in
              pkgs.runCommand "floe-hello" { } ''
                cat <<EOF > $out
                hello-floe emitted ${toString resourceCount} resource(s)
                url = ${result.exports.url}
                EOF
                if [ ${toString resourceCount} -ne 2 ]; then
                  echo "expected 2 resources, got ${toString resourceCount}" >&2
                  exit 1
                fi
                if [ "${result.exports.url}" != "http://hello.hello.svc.cluster.local:80" ]; then
                  echo "unexpected exports.url" >&2
                  exit 1
                fi
              '';

            floe-consumer =
              let
                helloOutputs = (import ./examples/floes/hello-floe/flake.nix).outputs {
                  self = {
                    floes = helloOutputs.flake.floes or { };
                  };
                  catallaxy = {
                    lib.floe = pureLib.floe;
                  };
                  inherit nixpkgs;
                  flake-parts.lib.mkFlake = _: cfg: cfg;
                };
                result = pureLib.evalModule {
                  modules = [
                    helloOutputs.flake.floes.hello
                    (
                      { ... }:
                      {
                        floes.hello = {
                          enable = true;
                          replicas = 3;
                          overrides.extraLabels."app.kubernetes.io/instance" = "consumer-test";
                        };
                      }
                    )

                    (
                      { lib, ... }:
                      {
                        options.bundles = lib.mkOption {
                          type = lib.types.attrsOf lib.types.attrs;
                          default = { };
                        };
                      }
                    )
                  ];
                };
                deployment = result.config.bundles.hello.resources.hello-deployment;
                replicas = deployment.spec.replicas;
                labelInstance = deployment.metadata.labels."app.kubernetes.io/instance" or "MISSING";
                exportsUrl = result.config.floes.hello.exports.url;
              in
              pkgs.runCommand "floe-consumer" { } ''
                cat <<EOF > $out
                consumer set replicas=${toString replicas}
                consumer override label app.kubernetes.io/instance=${labelInstance}
                exports.url=${exportsUrl}
                EOF
                if [ "${toString replicas}" != "3" ]; then
                  echo "consumer's replicas override did not propagate" >&2
                  exit 1
                fi
                if [ "${labelInstance}" != "consumer-test" ]; then
                  echo "consumer's overrides.extraLabels did not propagate" >&2
                  exit 1
                fi
                if [ "${exportsUrl}" != "http://hello.hello.svc.cluster.local:80" ]; then
                  echo "exports.url did not resolve" >&2
                  exit 1
                fi
              '';
          }
          // lib.mapAttrs' (
            name: lab:
            lib.nameValuePair "${name}-lint" (
              pkgs.runCommand "${name}-lint" { nativeBuildInputs = [ packages'.cataWrapped ]; } ''
                cata lab lint --path ${lab.config.lab.out.package}
                touch $out
              ''
            )
          ) exampleLabDefs
          // planSnapshotChecks;
      }
    );
}
