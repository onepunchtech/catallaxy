# lib/renderers/kapp.nix
#
# kapp manifest renderer.
# Produces ordered directories that the CLI applies sequentially via kapp.
#
# Output structure:
#   <clusterName>/
#     00-crds/
#       manifests.yaml
#     01-namespaces/
#       manifests.yaml
#     ...
#     .phase-order
#     .deploy-strategy

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
  phases,
  phaseOrder,
  deployConfig,
}:

let
  inherit (lib) concatStringsSep imap0 fixedWidthString;

  phaseEntries = dirBuilder.buildOrderedDirs "kapp-${clusterName}-phases" phaseOrder phases;

in
pkgs.runCommand "kapp-${clusterName}"
  {
    nativeBuildInputs = [ pkgs.yq-go ];
  }
  ''
    mkdir -p "$out/${clusterName}"
    cp -r --no-preserve=mode ${phaseEntries}/. "$out/${clusterName}/"

    # Apply prefix to resource names
    ${prefixUtil.applyToDir { inherit prefix labNamespaces; } "$out/${clusterName}"}

    echo "kapp" > "$out/${clusterName}/.deploy-strategy"

    cat > "$out/${clusterName}/.deploy-config" <<'EOF'
    waitTimeout: ${deployConfig.waitTimeout}
    EOF
  ''
