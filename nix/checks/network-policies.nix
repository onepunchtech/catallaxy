{
  lib,
  pkgs,
  mkLab,
  labs,
  cataWrapped,
  policyLab,
  brokenPolicyLab,
}:

let
  labWith =
    clusters:
    (mkLab {
      modules = [
        {
          lab.name = "netpol-fixture";
          lab.environment = "development";
          lab.dns.enable = false;
          lab.registry.enable = false;
          lab.proxy.enable = false;
          lab.clusters = clusters;
        }
      ];
    }).config;

  plain = labWith {
    app =
      { lab, ... }:
      {
        cluster.name = "app";
        cluster.provisioner = "k3d";
        provisioner.k3d.network = lab.name;
        cluster.security.networkPolicies.enable = true;

        floes.external-secrets.enable = true;
        floes.openbao.enable = true;
      };
  };

  routed = labWith {
    app =
      { lab, ... }:
      {
        cluster.name = "app";
        cluster.provisioner = "k3d";
        provisioner.k3d.network = lab.name;
        cluster.security.networkPolicies.enable = true;

        floes.cert-manager.enable = true;
        floes.reloader.enable = true;
        floes.gateway.enable = true;
        floes.grafana = {
          enable = true;
          domain = "grafana.test";
          tls.issuerRef = {
            name = "lab-ca";
            kind = "ClusterIssuer";
          };
        };
      };
  };

  ciliumDialect = labWith {
    app =
      { lab, ... }:
      {
        cluster.name = "app";
        cluster.provisioner = "k3d";
        provisioner.k3d.network = lab.name;
        cluster.security.networkPolicies.enable = true;

        floes.cilium.enable = true;
        floes.external-secrets.enable = true;
        floes.openbao.enable = true;
      };
  };

  creating = labWith {
    app =
      { lab, ... }:
      {
        cluster.name = "app";
        cluster.provisioner = "k3d";
        provisioner.k3d.network = lab.name;
        cluster.security.networkPolicies.enable = true;

        floes.cnpg = {
          enable = true;
          clusters.postgres = {
            namespace = "appdb";
            createNamespace = true;
            instances = 1;
            storage.size = "1Gi";
            postgresql.version = "16";
          };
        };
      };
  };

  policiesOf = c: c.lab.out.manifests.app;

  peerNamesNothing = ''
    [(.spec.ingress // [])[].from // [], (.spec.egress // [])[].to // []]
      | flatten
      | map(select((has("podSelector") or has("namespaceSelector") or has("ipBlock")) | not))
      | length
  '';

  peerListIsEmpty = ''
    [ (.spec.ingress // [])[] | select(has("from")) | .from,
      (.spec.egress // [])[] | select(has("to")) | .to ]
      | map(select(length == 0))
      | length
  '';

  cannotKnowItsTraffic = [ "custom" ];

  allFloes = lib.attrNames (
    lib.filterAttrs (_: t: t == "directory") (builtins.readDir ../../modules/lab/cluster/floes)
  );

  declaring = lib.unique (
    lib.concatLists (
      lib.mapAttrsToList (
        _: l:
        lib.concatLists (
          lib.mapAttrsToList (
            _: clusterCfg:
            lib.attrNames (
              lib.filterAttrs (
                _: f: (f.enable or false) && ((f.network or { }).declared or false)
              ) clusterCfg.floes
            )
          ) l.config.lab.clusters
        )
      ) labs
    )
  );

  missing = lib.subtractLists (declaring ++ cannotKnowItsTraffic) allFloes;
in
{
  every-floe-declares-its-network = pkgs.runCommand "every-floe-declares-its-network" { } ''
    ${lib.optionalString (missing != [ ]) ''
      echo "these floes never say what traffic they need:" >&2
      ${lib.concatMapStringsSep "\n" (f: ''echo "  ${f}" >&2'') missing}
      echo "" >&2
      echo "Set network.declared on each, with whatever egress and" >&2
      echo "ingress it needs. A floe needing nothing beyond the defaults" >&2
      echo "still sets it, so that it reads as reviewed rather than as" >&2
      echo "overlooked." >&2
      echo "" >&2
      echo "examples/labs/tests/every-floe.nix enables floes no example" >&2
      echo "lab uses. A floe whose traffic only a lab can know goes in" >&2
      echo "cannotKnowItsTraffic with a reason." >&2
      exit 1
    ''}
    touch $out
  '';

  network-policies-match-what-is-configured =
    pkgs.runCommand "network-policies-match-what-is-configured"
      {
        nativeBuildInputs = [ cataWrapped ];
      }
      ''
        # Not a pipeline. `cata lab lint` exits non-zero on any error and the
        # build runs under `set -o pipefail`, so piping into tee aborted here
        # and the diagnostic below was unreachable in the one case it exists
        # for. The report is plain text under nix build, because console turns
        # ANSI off when stdout is not a tty.
        status=0
        cata lab lint --path ${policyLab} > out.txt 2>&1 || status=$?
        cat out.txt

        if grep -q 'ERROR \[network-policy\]' out.txt; then
          echo "" >&2
          echo "The policies do not match what the manifests are configured" >&2
          echo "to do. Add the missing flow to the floe's network.reaches, or" >&2
          echo "correct the port in the serving floe's network.serves." >&2
          exit 1
        fi

        if [ "$status" != 0 ]; then
          echo "" >&2
          echo "The fixture lab failed to lint, but not on a network policy." >&2
          echo "Some other rule is reporting; fix that first, or this check" >&2
          echo "cannot tell you anything about the policies." >&2
          exit 1
        fi

        touch $out
      '';

  network-policy-rule-can-fail =
    pkgs.runCommand "network-policy-rule-can-fail"
      {
        nativeBuildInputs = [ cataWrapped ];
      }
      ''
        status=0
        cata lab lint --path ${brokenPolicyLab} > out.txt 2>&1 || status=$?
        cat out.txt

        if [ "$status" = 0 ]; then
          echo "" >&2
          echo "A lab declaring a served port no Service exposes linted clean." >&2
          echo "The network-policy rule is not running, or no longer reports" >&2
          echo "a wrong port as an error." >&2
          exit 1
        fi

        if ! grep -q 'ERROR \[network-policy\]' out.txt; then
          echo "" >&2
          echo "The fixture failed to lint, but not on a network policy, so" >&2
          echo "this proves nothing about the rule. Another rule is reporting." >&2
          exit 1
        fi

        touch $out
      '';

  gateway-reaches-what-it-routes-to =
    pkgs.runCommand "gateway-reaches-what-it-routes-to"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        cat $(find -L ${policiesOf routed} -path '*default-network-policies*' -name '*.yaml') > all.yaml

        want() {
          yq -N "select(.metadata.namespace == \"$1\" and (.metadata.name | test(\"^allow-\"))) | $2" all.yaml \
            | grep -q . || {
              echo "expected $3" >&2
              echo "--- rendered:" >&2
              yq -N 'select(.metadata.name | test("^allow-"))' all.yaml >&2
              exit 1
            }
        }

        # The gateway runs in kube-system, and the port comes from the route's
        # own backendRef, so this is the chart's number rather than a guess.
        want grafana \
          '.spec.ingress[] | select(.from[].namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "kube-system") | .ports[] | select(.port == 80)' \
          "grafana to accept the gateway's namespace on the route's port"

        # And nothing is written into kube-system, which the lab does not
        # create. A namespace with no policy is unrestricted; adding one
        # starts denying everything else in it, and in kube-system that is
        # the cluster's own components. Reaching a floe is not a reason to
        # take over the namespace the caller happens to live in.
        if yq -N 'select(.metadata.namespace == "kube-system") | .metadata.name' all.yaml | grep -q .; then
          echo "a policy was written into kube-system, which the lab does not manage" >&2
          yq -N 'select(.metadata.namespace == "kube-system")' all.yaml >&2
          exit 1
        fi

        touch $out
      '';

  a-floes-rules-stay-where-its-pods-are =
    pkgs.runCommand "a-floes-rules-stay-where-its-pods-are"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        cat $(find -L ${policiesOf creating} -path '*default-network-policies*' -name '*.yaml') > all.yaml

        strays=$(yq -N 'select(.metadata.name == "allow-cnpg" and .metadata.namespace != "cnpg-system") | .metadata.namespace' all.yaml | grep -c . || true)
        if [ "$strays" != 0 ]; then
          echo "cnpg's rules were written into a namespace it only creates:" >&2
          yq -N 'select(.metadata.name == "allow-cnpg" and .metadata.namespace != "cnpg-system")' all.yaml >&2
          exit 1
        fi

        # The created namespace is still covered, by the default-deny every
        # lab-managed namespace gets. Losing that would be the opposite bug.
        yq -N 'select(.metadata.namespace == "appdb" and .metadata.name == "default-deny") | .metadata.name' all.yaml \
          | grep -q . || {
            echo "the created namespace appdb has no default-deny" >&2
            yq -N '.metadata | [.namespace, .name] | join("/")' all.yaml >&2
            exit 1
          }

        # And cnpg keeps its own, or this passes by rendering nothing.
        yq -N 'select(.metadata.namespace == "cnpg-system" and .metadata.name == "allow-cnpg") | .metadata.name' all.yaml \
          | grep -q . || {
            echo "cnpg has no policy in its own namespace, so this checked nothing" >&2
            yq -N '.metadata | [.namespace, .name] | join("/")' all.yaml >&2
            exit 1
          }

        touch $out
      '';

  cilium-policies-deny-both-directions =
    pkgs.runCommand "cilium-policies-deny-both-directions"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        cat $(find -L ${policiesOf ciliumDialect} -path '*default-network-policies*' -name '*.yaml') > all.yaml

        if yq -N 'select(.kind == "NetworkPolicy") | .metadata.name' all.yaml | grep -q .; then
          echo "a cluster running Cilium rendered a plain NetworkPolicy" >&2
          yq -N 'select(.kind == "NetworkPolicy")' all.yaml >&2
          exit 1
        fi

        # Counted rather than matched by name: every namespace renders a
        # policy called default-deny, so a name selects several documents.
        found=$(yq -N 'select(.kind == "CiliumNetworkPolicy") | .metadata.name' all.yaml | grep -c . || true)
        enforcing=$(yq -N 'select(.kind == "CiliumNetworkPolicy" and .spec.enableDefaultDeny.ingress == true and .spec.enableDefaultDeny.egress == true) | .metadata.name' all.yaml | grep -c . || true)

        if [ "$found" != "$enforcing" ]; then
          echo "$((found - enforcing)) of $found CiliumNetworkPolicies do not enforce both directions:" >&2
          yq -N 'select(.kind == "CiliumNetworkPolicy" and (.spec.enableDefaultDeny.ingress != true or .spec.enableDefaultDeny.egress != true))' all.yaml >&2
          echo "" >&2
          echo "Cilium defaults enforcement to false for a direction with no" >&2
          echo "rules, so a policy has to ask for it explicitly or it denies" >&2
          echo "less than the plain dialect does." >&2
          exit 1
        fi

        if [ "$found" = 0 ]; then
          echo "the fixture rendered no CiliumNetworkPolicy, so this checked nothing" >&2
          exit 1
        fi

        echo "checked $found policies" > $out
      '';

  network-policy-peers-are-valid =
    pkgs.runCommand "network-policy-peers-are-valid"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        # $1 is a yq expression counting offending rules, $2 what to say.
        none() {
          while read -r n; do
            [ "$n" = "0" ] || [ -z "$n" ] && continue
            echo "a NetworkPolicy in $f has $n rule(s) $2:" >&2
            yq -N 'select(.kind == "NetworkPolicy")' "$f" >&2
            exit 1
          done < <(yq -N "select(.kind == \"NetworkPolicy\") | $1" "$f")
        }

        found=0
        for f in $(find -L ${policiesOf plain} -name '*.yaml' -type f); do
          none ${lib.escapeShellArg peerNamesNothing} \
            "whose peer names neither a selector nor an ipBlock, which the API server rejects with 'must specify a peer'"

          none ${lib.escapeShellArg peerListIsEmpty} \
            "with an empty peer list, which is not 'no peer' but every peer; omit the list rather than emptying it"

          n=$(yq -N 'select(.kind == "NetworkPolicy") | .metadata.name' "$f" | grep -c . || true)
          found=$((found + n))
        done

        # Or the loop above passed by finding nothing to look at.
        if [ "$found" = 0 ]; then
          echo "the fixture rendered no NetworkPolicy at all, so this checked nothing" >&2
          exit 1
        fi

        echo "checked $found policies" > $out
      '';
}
