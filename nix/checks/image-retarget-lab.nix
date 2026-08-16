{
  lib,
  pkgs,
  mkLab,
}:

let
  labWith =
    images:
    (mkLab {
      modules = [
        {
          lab.name = "retarget-fixture";
          lab.environment = "development";
          lab.dns.enable = false;
          lab.registry.enable = false;
          lab.proxy.enable = false;
          lab.images = images;
          lab.clusters.app = {
            cluster.name = "app";
            cluster.provisioner = "k3d";
            provisioner.k3d.network = "retarget-fixture";
            floes.external-secrets.enable = true;

            # Not dev mode, and auto-unsealed, because that is what renders
            # openbao's init Job. The fixture needs both an image the floe
            # writes into a manifest itself and one only the chart produces,
            # and this floe is the smallest thing that has both.
            floes.openbao = {
              enable = true;
              mode = "standalone";
              seal.transit = {
                address = "https://bao.example";
                key_name = "unseal";
              };
            };
          };
        }
      ];
    }).config;

  plain = labWith { };

  mirrored = labWith { registry = "registry.internal"; };

  pinnedElsewhere = labWith {
    registry = "registry.internal";
    pinned.openbao.server.registry = "quay.io";
  };

  # openbao renders its init image itself and takes its server image from the
  # chart, so pinning both says whether an override reaches an image no floe
  # writes into a manifest.
  pinnedTags = labWith {
    pinned.openbao = {
      init.tag = "9.9.9";
      server.tag = "8.8.8";
    };
  };

  manifestsOf = c: c.lab.out.manifests.app;
in
{
  # The unit tests say the type and the yq expression each do their job. This
  # says the two are actually connected: a lab sets one option and what lands
  # on disk moves, through the declared path for images a floe named and
  # through the file rewrite for the ones no floe has declared yet.
  image-retarget-reaches-a-rendered-lab =
    pkgs.runCommand "image-retarget-reaches-a-rendered-lab"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        fail() { echo "$1" >&2; exit 1; }

        images() {
          find -L "$1" -name '*.yaml' -type f -exec \
            yq -N '(.. | select(has("image")).image)' {} \; 2>/dev/null | sort -u
        }

        images ${manifestsOf plain} | grep -v '^$' > plain.txt
        images ${manifestsOf mirrored} | grep -v '^$' > mirrored.txt
        images ${manifestsOf pinnedElsewhere} | grep -v '^$' > pinned.txt

        test -s plain.txt || fail "the fixture lab rendered no images at all"

        # Nothing is left behind. The blanket registry is only worth having if
        # a lab can hand the list to an air-gapped registry and have every
        # pull resolve, so one straggler is a failure rather than a shortfall.
        if grep -vq '^registry\.internal/' mirrored.txt; then
          echo "these images were not moved to the mirror:" >&2
          grep -v '^registry\.internal/' mirrored.txt | sed 's/^/  /' >&2
          exit 1
        fi

        # And the move is only the host: same count, same repositories, same
        # tags. A retarget that dropped or merged an image would still satisfy
        # the check above.
        [ "$(wc -l < plain.txt)" = "$(wc -l < mirrored.txt)" ] \
          || fail "the mirror has $(wc -l < mirrored.txt) images and the lab has $(wc -l < plain.txt)"

        # A pin names one label and moves that image alone, so a lab can
        # mirror everything and still take one thing from upstream.
        grep -q '^quay\.io/openbao/openbao:' pinned.txt \
          || fail "the pin on openbao.server did not survive the blanket registry"
        [ "$(grep -c '^quay\.io/' pinned.txt)" = 1 ] \
          || fail "the pin moved more than the one image it named"

        touch $out
      '';

  # Most declared images belong to a chart, so a pin that only worked on the
  # ones a floe writes by hand would work on almost nothing.
  image-pins-reach-an-image-the-floe-never-writes =
    pkgs.runCommand "image-pins-reach-an-image-the-floe-never-writes"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        fail() { echo "$1" >&2; exit 1; }

        find -L ${manifestsOf pinnedTags} -name '*.yaml' -type f -exec \
          yq -N '(.. | select(has("image")).image)' {} \; 2>/dev/null | sort -u > got.txt

        # The floe writes this one into a Job it renders, so the declaration
        # reaches the manifest directly.
        grep -q '^alpine/k8s:9\.9\.9$' got.txt \
          || fail "the pin on an image the floe renders itself did not land"

        # And this one only ever appears because the chart put it there.
        grep -q '^quay\.io/openbao/openbao:8\.8\.8$' got.txt \
          || fail "the pin on a chart's own image did not land"

        # Nothing of the original is left behind, which is what separates a
        # pin that worked from one that added a second copy.
        grep -q ':1\.32\.4$\|:2\.3\.1$' got.txt \
          && fail "the images the floe declared are still rendered alongside the pinned ones"

        touch $out
      '';

  image-retarget-changes-nothing-when-unset =
    pkgs.runCommand "image-retarget-changes-nothing-when-unset" { }
      ''
        # A lab that sets none of this has to render exactly what it rendered
        # before the mechanism existed.
        diff -r ${manifestsOf plain} ${manifestsOf (labWith { })} \
          || { echo "the default path is not the identity" >&2; exit 1; }
        touch $out
      '';
}
