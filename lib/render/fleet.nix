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
  inherit (lib) concatStringsSep;

  sanitize = key: builtins.replaceStrings [ "/" ] [ "__" ] key;

  bundleFleetName = key: prefixUtil.prefixed prefix (sanitize key);

  bundleEntries = lib.concatLists (
    lib.imap0 (
      i: waveBundles:
      let
        predecessors = lib.concatLists (
          lib.imap0 (
            j: prev:
            if j < i then map (b: b.name) (lib.filter (b: !(lib.hasPrefix "projection/" b.name)) prev) else [ ]
          ) waves
        );
      in
      map (b: {
        bundleKey = b.name;
        dependsOn = map bundleFleetName predecessors;
      }) (lib.filter (b: !(lib.hasPrefix "projection/" b.name)) waveBundles)
    ) waves
  );

  mkFleetYaml =
    entry:
    let
      dependsOnRefs = map (n: { name = n; }) entry.dependsOn;
    in
    {
      defaultNamespace = "default";
    }
    // lib.optionalAttrs (dependsOnRefs != [ ]) {
      dependsOn = dependsOnRefs;
    };

  bundlesDrv =
    pkgs.runCommand "fleet-${clusterName}-bundles"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p $out
        ${concatStringsSep "\n" (
          map (
            entry:
            let
              inherit (entry) bundleKey;
              sanitized = sanitize bundleKey;
              pkg = packages.${bundleKey} or null;
              fleetConfig = mkFleetYaml entry;
            in
            if pkg == null then
              ""
            else
              ''
                mkdir -p "$out/${sanitized}"
                echo '${builtins.toJSON fleetConfig}' | yq -P '.' > "$out/${sanitized}/fleet.yaml"

                if [ -d "${pkg}" ]; then
                  cp -r --no-preserve=mode ${pkg}/* "$out/${sanitized}/" 2>/dev/null || true
                else
                  cp --no-preserve=mode ${pkg} "$out/${sanitized}/manifests.yaml"
                fi

                find "$out/${sanitized}" -name '*.yaml' -not -name 'fleet.yaml' -type f | while read -r f; do
                  yq -P -i '.' "$f" 2>/dev/null || true
                done

                ${prefixUtil.applyToDir { inherit prefix labNamespaces; } "$out/${sanitized}"}
                ${imageUtil.applyToDir {
                  lock = imageLock;
                  registry = imageRegistry;
                  exempt = imageExempt;
                  overrides = imageOverrides;
                } "$out/${sanitized}"}
              ''
          ) bundleEntries
        )}
      '';

in
pkgs.runCommand "fleet-${clusterName}" { } ''
  mkdir -p "$out/${clusterName}"
  if [ -d "${bundlesDrv}" ] && [ -n "$(ls -A "${bundlesDrv}" 2>/dev/null)" ]; then
    cp -r ${bundlesDrv}/* "$out/${clusterName}/"
  fi
  echo "fleet" > "$out/${clusterName}/.deploy-strategy"
''
