{
  self,
  lib,
  pkgs,
  system,
  nixpkgs,
  pureLib,
  packages,
  treefmtEval,
  mkLab,
  mkLabChecks,
  exampleLabDefs,
  e2eLabs,
}:

let
  fixtureLabs = {
    cloud-teardown = mkLab { modules = [ ../../examples/labs/tests/cloud-teardown.nix ]; };
    every-floe = mkLab { modules = [ ../../examples/labs/tests/every-floe.nix ]; };
  };
in
{
  cli = packages.cataWrapped;
  cli-clippy = packages.cata.passthru.clippy;
  docs = packages.docs;
  formatting = treefmtEval.config.build.check self;
}
// import ./assertions.nix { inherit lib pkgs mkLab; }
// import ./resource-types.nix { inherit lib pkgs mkLab; }
// import ./cli-lints.nix { inherit pkgs self; }
// import ./lib-tests.nix { inherit lib pkgs e2eLabs; }
// import ./step-kinds.nix { inherit lib pkgs system; }
// import ./host-dns.nix { inherit lib pkgs self; }
// import ./scripts.nix { inherit pkgs self; }
// import ./image-rewrite.nix { inherit lib pkgs; }
// import ./openbao-ops.nix { inherit lib pkgs mkLab; }
// import ./image-paths.nix { inherit lib pkgs self; }
// import ./image-completeness.nix {
  inherit lib pkgs;
  labs = exampleLabDefs // fixtureLabs;
}
// import ./image-retarget-lab.nix { inherit lib pkgs mkLab; }
// import ./network-policies.nix {
  inherit lib pkgs mkLab;
  inherit (packages) cataWrapped;
  labs = exampleLabDefs // fixtureLabs;
  # An example lab, rendered again with policies on. Those labs leave the
  # option off, so their own output is untouched; this is the only way to
  # analyse a lab whose floes are actually wired to one another.
  policyLab =
    (mkLab {
      modules = [
        ../../examples/labs/homelab/labs/default.nix
        {
          lab.clusters.core.cluster.security.networkPolicies.enable = true;
          lab.clusters.obs.cluster.security.networkPolicies.enable = true;
        }
      ];
    }).config.lab.out.package;
  # The same lab with one deliberate lie, so there is something the rule is
  # known to reject. A check that only ever sees a passing lab cannot tell
  # "found nothing wrong" from "never ran".
  brokenPolicyLab =
    (mkLab {
      modules = [
        ../../examples/labs/homelab/labs/default.nix
        {
          lab.clusters.core.cluster.security.networkPolicies.enable = true;
          lab.clusters.obs.cluster.security.networkPolicies.enable = true;
          lab.clusters.obs.floes.grafana.network.serves.http.port = lib.mkForce 9999;
        }
      ];
    }).config.lab.out.package;
}
// import ./docs.nix {
  inherit pkgs;
  inherit (packages) optionDocs stepKindDocs;
}
// import ./external-floes.nix {
  inherit
    lib
    pkgs
    nixpkgs
    pureLib
    mkLab
    ;
}
// import ./examples.nix {
  inherit exampleLabDefs mkLabChecks;
  inherit fixtureLabs;
}
