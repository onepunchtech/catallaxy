{ lib }:

let
  inherit (import ../../modules/lab/image-types.nix { inherit lib; }) imageType retarget;

  # A floe's declared set, as the option's `apply` sees it.
  declared = {
    server = {
      registry = "quay.io";
      repository = "openbao/openbao";
      tag = "2.3.1";
      digest = null;
    };
    init = {
      registry = "docker.io";
      repository = "alpine/k8s";
      tag = "1.32.4";
      digest = null;
    };
  };

  refsOf = args: lib.mapAttrs (_: i: i.ref) (retarget args declared);

  refOf =
    image:
    (lib.evalModules {
      modules = [
        {
          options.image = lib.mkOption { type = imageType; };
          config.image = image;
        }
      ];
    }).config.image.ref;
in
lib.runTests {

  # Docker Hub is left implicit because that is what every manifest in the
  # tree writes. Emitting it would change every rendered image without
  # changing what any of them resolve to, which would make the migration to
  # declared images look like a behaviour change when it is not.
  testTheImplicitRegistryStaysImplicit = {
    expr = refOf {
      repository = "alpine/k8s";
      tag = "1.32.4";
    };
    expected = "alpine/k8s:1.32.4";
  };

  # And appears the moment it is not Docker Hub, which is what a retarget
  # relies on.
  testAnyOtherRegistryIsWritten = {
    expr = refOf {
      registry = "quay.io";
      repository = "argoproj/argocd";
      tag = "v3.0.1";
    };
    expected = "quay.io/argoproj/argocd:v3.0.1";
  };

  testRetargetingIsJustTheRegistry = {
    expr = refOf {
      registry = "registry.internal";
      repository = "alpine/k8s";
      tag = "1.32.4";
    };
    expected = "registry.internal/alpine/k8s:1.32.4";
  };

  # Alongside the tag, not instead of it: the tag is what a pull-through
  # cache's tag list can answer about, and dropping it defeats the warm cache.
  testADigestKeepsTheTag = {
    expr = refOf {
      repository = "nginx";
      tag = "1.27";
      digest = "sha256:abc";
    };
    expected = "nginx:1.27@sha256:abc";
  };

  testADigestWithoutATag = {
    expr = refOf {
      registry = "ghcr.io";
      repository = "o/r";
      digest = "sha256:abc";
    };
    expected = "ghcr.io/o/r@sha256:abc";
  };

  testAnUntaggedImageIsJustTheRepository = {
    expr = refOf { repository = "nginx"; };
    expected = "nginx";
  };

  # `repository` has no default, so a floe cannot declare a slot without
  # saying what is in it.
  testARepositoryIsRequired = {
    expr =
      (builtins.tryEval (refOf {
        tag = "1.0";
      })).success;
    expected = false;
  };

  # The three images every waiter in every lab rides. They were literals in a
  # shared helper with no path from configuration to them, so this asserts the
  # path exists rather than that a string is a string.
  testTheWaitImagesReachTheProbeRenderer = {
    expr =
      let
        wait = import ../util/wait.nix {
          inherit lib;
          images = {
            kubectl = "registry.internal/alpine/k8s:1.32.4";
            curl = "registry.internal/curlimages/curl:8.10.1";
            network = "registry.internal/busybox:1.36";
          };
        };
        imageOf =
          probe:
          (wait.mkWaitInitContainer {
            inherit probe;
            name = "w";
          }).image;
      in
      map imageOf [
        {
          kind = "exists";
          resource = "secret/x";
          namespace = "n";
        }
        {
          kind = "http";
          url = "http://x/";
        }
        {
          kind = "tcp";
          host = "x";
          port = 1;
        }
      ];
    expected = [
      "registry.internal/alpine/k8s:1.32.4"
      "registry.internal/curlimages/curl:8.10.1"
      "registry.internal/busybox:1.36"
    ];
  };

  # One line points a whole lab at a mirror, which is the case that makes the
  # blanket registry worth having over pinning each image.
  testABlanketRegistryMovesEveryImage = {
    expr = refsOf { registry = "registry.internal"; };
    expected = {
      server = "registry.internal/openbao/openbao:2.3.1";
      init = "registry.internal/alpine/k8s:1.32.4";
    };
  };

  # Matching is by label and nothing else, so a lab names the image it means
  # rather than catallaxy guessing from a repository two floes might share.
  testAPinMatchesByLabel = {
    expr = refsOf {
      pinned.server.digest = "sha256:abc";
    };
    expected = {
      server = "quay.io/openbao/openbao:2.3.1@sha256:abc";
      init = "alpine/k8s:1.32.4";
    };
  };

  # A lab that mirrors everything but takes one image from elsewhere. Without
  # this ordering the blanket setting would silently win and the pin would
  # look applied while pointing at the wrong host.
  testAPinBeatsTheBlanketRegistry = {
    expr = refsOf {
      registry = "registry.internal";
      pinned.server.registry = "quay.io";
    };
    expected = {
      server = "quay.io/openbao/openbao:2.3.1";
      init = "registry.internal/alpine/k8s:1.32.4";
    };
  };

  # A pin says what to change. Restating the repository to move a tag would
  # be a second place for it to drift from what the floe declared.
  testAnUnsetPinFieldKeepsWhatTheFloeDeclared = {
    expr = (refsOf { pinned.init.tag = "1.33.0"; }).init;
    expected = "alpine/k8s:1.33.0";
  };

  # A label no floe declared is not a way to add an image. Naming one is
  # almost always a typo in the label, and inventing a slot from it would
  # produce an image with no repository.
  testAPinForAnUnknownLabelAddsNothing = {
    expr = builtins.attrNames (retarget { pinned.typo.tag = "9"; } declared);
    expected = [
      "init"
      "server"
    ];
  };

  testNoLabSettingsChangeNothing = {
    expr = refsOf { };
    expected = {
      server = "quay.io/openbao/openbao:2.3.1";
      init = "alpine/k8s:1.32.4";
    };
  };

  # Unset, they are what every manifest in the tree already carries.
  testTheWaitImagesDefaultToWhatIsRenderedToday = {
    expr =
      let
        wait = import ../util/wait.nix { inherit lib; };
      in
      (wait.mkWaitInitContainer {
        name = "w";
        probe = {
          kind = "exists";
          resource = "secret/x";
          namespace = "n";
        };
      }).image;
    expected = "alpine/k8s:1.32.4";
  };
}
