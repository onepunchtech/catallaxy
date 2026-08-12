{
  lib,
  pkgs,
  dirBuilder,
  yamlUtil,
  prefixUtil,
}:

{
  clusterName,
  prefix ? "",
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

    echo "kapp" > "$out/${clusterName}/.deploy-strategy"

    cat > "$out/${clusterName}/.deploy-config" <<'EOF'
    waitTimeout: ${deployConfig.waitTimeout}
    EOF
  ''
