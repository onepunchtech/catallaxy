{ lib, e2eLabs }:

let
  expected = {
    "minimal.local" = {
      eligible = true;
      mentions = [ ];
    };
    "gitops.local" = {
      eligible = true;
      mentions = [ ];
    };
    "homelab.local" = {
      eligible = true;
      mentions = [ ];
    };
    "homelab.gitops-local" = {
      eligible = true;
      mentions = [ ];
    };
    "mesh.local" = {
      eligible = false;
      mentions = [
        "lab-ca in store trust, backend sops"
        "cannot finish without a human"
      ];
    };
  };

  failure = name: message: {
    inherit name message;
  };

  missing = map (name: failure name "expected in e2eLabs but the flake does not define it") (
    lib.subtractLists (lib.attrNames e2eLabs) (lib.attrNames expected)
  );

  unexpected = map (
    name: failure name "is in e2eLabs but lib/tests/self-contained.nix says nothing about it"
  ) (lib.subtractLists (lib.attrNames expected) (lib.attrNames e2eLabs));

  checkLab =
    name: want:
    let
      got = e2eLabs.${name};
      reasonText = lib.concatStringsSep "\n" got.reasons;
      unmentioned = lib.filter (m: !(lib.hasInfix m reasonText)) want.mentions;
    in
    lib.optional (got.eligible != want.eligible) (
      failure name "eligible is ${lib.boolToString got.eligible}, expected ${lib.boolToString want.eligible}: ${reasonText}"
    )
    ++ lib.optional (got.eligible && got.reasons != [ ]) (
      failure name "is eligible but still gives reasons: ${reasonText}"
    )
    ++ lib.optional (!got.eligible && got.reasons == [ ]) (
      failure name "is ineligible and says nothing about why"
    )
    ++ lib.optional (unmentioned != [ ]) (
      failure name "no reason mentions ${lib.concatStringsSep " or " unmentioned}, so the check that used to catch it has stopped: ${reasonText}"
    );

  checked = lib.concatLists (
    lib.mapAttrsToList checkLab (lib.filterAttrs (name: _: e2eLabs ? ${name}) expected)
  );
in
missing ++ unexpected ++ checked
