{ lib, pkgs }:

let
  imageUtil = import ../render/images.nix { inherit lib pkgs; };
in
lib.runTests {

  # Not merely "changes nothing": emits nothing, so a lab with no lockfile
  # pays no yq pass over every manifest it renders. What the pass does with an
  # empty lock is covered by the image-rewrite check.
  testNoLockEmitsNoPass = {
    expr = imageUtil.applyToDir { lock = { }; } "somewhere";
    expected = "";
  };

  testAnEmptyImagesMapIsTheSameAsNoLock = {
    expr = imageUtil.applyToDir { lock.images = { }; } "somewhere";
    expected = "";
  };

  # What the pass contains is checked by the image-rewrite derivation, which
  # runs it. This only pins that a lock produces one at all.
  testALockEmitsAPass = {
    expr = imageUtil.applyToDir { lock.images."nginx:1.27-alpine" = "sha256:aaa"; } "somewhere" != "";
    expected = true;
  };

  # The scrape has to reach every path the image-pin lint reads, or the lint
  # flags a reference the lock could never have carried. Asserted as a list
  # rather than by substring, because `.spec.template.spec.containers`
  # contains `.spec.containers` and an infix test cannot tell a missing
  # bare-Pod path from a present one.
  testTheScrapeReachesEveryPathTheLintDoes = {
    expr = imageUtil.scrapePaths;
    expected = [
      ".spec.containers"
      ".spec.initContainers"
      ".spec.template.spec.containers"
      ".spec.template.spec.initContainers"
      ".spec.jobTemplate.spec.template.spec.containers"
      ".spec.jobTemplate.spec.template.spec.initContainers"
    ];
  };
}
