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
  inherit (lib)
    concatStringsSep
    imap0
    fixedWidthString
    mapAttrsToList
    ;

  appName = name: if prefix == "" then name else "${prefix}-${name}";

  # Generate an ArgoCD Application CR for a phase
  mkApplication =
    i: phaseName:
    let
      phase = phases.${phaseName};
      numPrefix = fixedWidthString 2 "0" (toString i);
    in
    {
      name = "${numPrefix}-${phaseName}";
      value = {
        apiVersion = "argoproj.io/v1alpha1";
        kind = "Application";
        metadata = {
          name = appName "${clusterName}-${phaseName}";
          namespace = "argocd";
          annotations = {
            "argocd.argoproj.io/sync-wave" = toString phase.order;
          };
        };
        spec = {
          project = "default";
          source = {
            repoURL = deployConfig.repoUrl;
            targetRevision = deployConfig.targetBranch;
            path = "${deployConfig.targetPath}/phases/${phaseName}";
          };
          destination = {
            server = "https://kubernetes.default.svc";
          };
          syncPolicy = {
            automated = {
              prune = true;
              selfHeal = true;
            };
          };
        };
      };
    };

  applicationEntries = lib.listToAttrs (imap0 mkApplication phaseOrder);

  # Build the applications/ directory with one YAML file per Application CR
  applicationsDir =
    pkgs.runCommand "argocd-${clusterName}-apps"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p $out
        ${concatStringsSep "\n" (
          mapAttrsToList (name: app: ''
            echo '${builtins.toJSON app}' | yq -P '.' > "$out/${name}.yaml"
          '') applicationEntries
        )}
      '';

  # Build the phases/ directory with rendered manifests
  phasesDir =
    pkgs.runCommand "argocd-${clusterName}-phases"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p $out
        ${concatStringsSep "\n" (
          map (
            phaseName:
            let
              phase = phases.${phaseName};
            in
            ''
              mkdir -p "$out/${phaseName}"
              if [ -d "${phase.package}" ]; then
                cp -r --no-preserve=mode ${phase.package}/* "$out/${phaseName}/" 2>/dev/null || true
              else
                cp --no-preserve=mode ${phase.package} "$out/${phaseName}/manifests.yaml"
              fi

              # Convert to human-readable YAML
              find "$out/${phaseName}" -name '*.yaml' -type f | while read -r f; do
                yq -P -i '.' "$f" 2>/dev/null || true
              done

              # Apply prefix to resource names
              ${prefixUtil.applyToDir { inherit prefix labNamespaces; } "$out/${phaseName}"}
            ''
          ) phaseOrder
        )}
      '';

in
pkgs.runCommand "argocd-${clusterName}" { } ''
  mkdir -p "$out/${clusterName}/applications"
  mkdir -p "$out/${clusterName}/phases"

  cp -r ${applicationsDir}/* "$out/${clusterName}/applications/"
  cp -r ${phasesDir}/* "$out/${clusterName}/phases/"

  echo "argocd" > "$out/${clusterName}/.deploy-strategy"
''
