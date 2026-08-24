{
  lib,
  pkgs,
  dirBuilder,
  yamlUtil,
  prefixUtil,
  imageUtil,
}:

{
  clusterName,
  labName,
  declaredBundles ? [ ],
  prefix ? "",
  imageLock ? { },
  imageRegistry ? null,
  imageExempt ? [ ],
  imageOverrides ? { },
  labNamespaces ? [ ],

  packages,
  deployConfig,

  waves ? [ ],
}:

let
  bundleEntries = dirBuilder.buildWaveDirs "kapp-${clusterName}-bundles" packages waves;

  # Every bundle the cluster declares, not just the ones this tree renders.
  # `lab up` applies a subset -- for an argocd lab, only the install-target
  # set -- so the applied tree cannot say whether a bundle it is missing was
  # dropped from the declaration or is simply owned by argocd. Pruning off the
  # applied tree alone would delete everything argocd manages.
  declaredBundlesFile = lib.concatStringsSep "\n" (lib.sort (a: b: a < b) declaredBundles);
in
pkgs.runCommand "kapp-${clusterName}"
  {
    nativeBuildInputs = [ pkgs.yq-go ];
  }
  ''
    mkdir -p "$out/${clusterName}"
    cp -r --no-preserve=mode ${bundleEntries}/. "$out/${clusterName}/"

    ${prefixUtil.applyToDir { inherit prefix labNamespaces; } "$out/${clusterName}"}
    ${imageUtil.applyToDir {
      lock = imageLock;
      registry = imageRegistry;
      exempt = imageExempt;
      overrides = imageOverrides;
    } "$out/${clusterName}"}

    echo "kapp" > "$out/${clusterName}/.deploy-strategy"

    cat > "$out/${clusterName}/.declared-bundles" <<'DECLARED'
    ${declaredBundlesFile}
    DECLARED

    cat > "$out/${clusterName}/.deploy-config" <<'EOF'
    waitTimeout: ${deployConfig.waitTimeout}
    EOF
  ''
