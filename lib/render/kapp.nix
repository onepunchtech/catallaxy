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

    cat > "$out/${clusterName}/.deploy-config" <<'EOF'
    waitTimeout: ${deployConfig.waitTimeout}
    EOF
  ''
