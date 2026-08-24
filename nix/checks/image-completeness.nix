{
  lib,
  pkgs,
  labs,
}:

let
  imageUtil = import ../../lib/render/images.nix { inherit lib pkgs; };

  # Every floe across every lab that claims its image set is complete.
  claims = lib.concatLists (
    lib.mapAttrsToList (
      labName: lab:
      lib.concatLists (
        lib.mapAttrsToList (
          clusterName: clusterCfg:
          lib.mapAttrsToList (floeName: c: {
            inherit
              labName
              clusterName
              floeName
              ;
            inherit (c) declared packages;
          }) (clusterCfg.cluster.out.imageCompleteness or { })
        ) lab.config.lab.clusters
      )
    ) labs
  );

  checkOne =
    c:
    let
      declared = pkgs.writeText "declared.txt" (lib.concatStringsSep "\n" (c.declared ++ [ "" ]));
    in
    ''
      echo "--- ${c.labName}/${c.clusterName}/${c.floeName}"
      : > found.txt
      ${lib.concatMapStringsSep "\n" (p: ''
        for f in $(find -L ${p} -name '*.yaml' -type f); do
          yq -N '${imageUtil.scrapeExpr}' "$f" 2>/dev/null >> found.txt || true
        done
      '') c.packages}

      # `docker.io/traefik` and `traefik` are one image spelled two ways, and
      # a chart picks whichever it likes. Comparing the spellings would make
      # a floe restate a chart's punctuation, so both sides drop the implicit
      # registry before they meet.
      norm() { sed 's|^docker\.io/||' | sort -u | grep -v '^$'; }

      norm < found.txt | grep -v '^null$' > found-sorted.txt || true
      norm < ${declared} > declared-sorted.txt || true

      undeclared=$(comm -23 found-sorted.txt declared-sorted.txt)
      if [ -n "$undeclared" ]; then
        {
          echo "${c.floeName} on ${c.labName}/${c.clusterName}:"
          printf '%s\n' "$undeclared" | sed 's/^/  /'
        } >> failures.txt
      fi
    '';
  # Floes that render whatever a lab hands them, so only the lab can say what
  # the images are. An entry here is a claim that the floe cannot know, not
  # that nobody got round to it.
  cannotKnowItsImages = [ "custom" ];

  allFloes = lib.attrNames (
    lib.filterAttrs (_: t: t == "directory") (builtins.readDir ../../modules/lab/cluster/floes)
  );

  claiming = lib.unique (map (c: c.floeName) claims);

  missing = lib.subtractLists (claiming ++ cannotKnowItsImages) allFloes;
in
{
  # A floe nobody's example lab uses is still a floe someone downstream can
  # depend on, and its images are still images they have to mirror. Without
  # this, the way a floe ends up undeclared is that nobody notices it is
  # missing, which is exactly what a published library cannot afford.
  #
  # It also catches the subtler case: a floe that claims completeness but is
  # enabled nowhere is checked against nothing, so it must be enabled in a lab
  # before it counts as claiming.
  every-floe-declares-its-images = pkgs.runCommand "every-floe-declares-its-images" { } ''
    ${lib.optionalString (missing != [ ]) ''
      echo "these floes never declare their images:" >&2
      ${lib.concatMapStringsSep "\n" (f: ''echo "  ${f}" >&2'') missing}
      echo "" >&2
      echo "Enable each in a lab, set imagesComplete, and add what" >&2
      echo "image-sets-are-complete names. examples/labs/tests/every-floe.nix" >&2
      echo "exists for floes no example lab uses." >&2
      echo "" >&2
      echo "A floe that genuinely cannot know its images, because a lab" >&2
      echo "supplies them, goes in cannotKnowItsImages with a reason." >&2
      exit 1
    ''}
    touch $out
  '';

  # A floe that says its image set is complete has to mean it. This renders
  # what the floe actually produced - the bundles are found by the provenance
  # the floe they are declared under - and fails naming anything the floe did not
  # declare, which is what turns declaring ~170 images from archaeology into
  # "run it, add what it names".
  #
  # It also settles the operator-CR question: a Prometheus CR's `spec.image`
  # is caught for being in the rendered output, not because a path was added.
  image-sets-are-complete =
    pkgs.runCommand "image-sets-are-complete"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        ${
          if claims == [ ] then
            ''
              echo "no floe claims a complete image set yet" > $out
              exit 0
            ''
          else
            ''
              : > failures.txt
              ${lib.concatMapStringsSep "\n" checkOne claims}

              # Every floe at once rather than the first one that fails,
              # because declaring an image set is done by running this and
              # adding what it names, and one name per run makes that a loop
              # as long as the list.
              if [ -s failures.txt ]; then
                echo "these floes render images they did not declare:" >&2
                cat failures.txt >&2
                echo "" >&2
                echo "Add each to the floe's \`images\`, or drop its" >&2
                echo "\`imagesComplete\` until they are all there." >&2
                exit 1
              fi
            ''
        }
        touch $out
      '';
}
