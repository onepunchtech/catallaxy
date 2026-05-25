{
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  sourceRoot,
}:

let
  # Evaluate the full module tree to extract option declarations.
  # We use a minimal config — only option metadata is needed, not computed values.
  evaluated = lib.evalModules {
    modules = [
      ../modules
      {
        _module.args = {
          inherit cataCharts k8sSpecs;
        };
      }
      {
        lab.name = "docs-placeholder";
        lab.clusters = { };
      }
    ];
    specialArgs = { inherit lib pkgs; };
  };

  gitHubBaseUrl = "https://github.com/onepunchtech/catallaxy/blob/master";

  transformOptions =
    opt:
    opt
    // {
      declarations = map (
        decl:
        let
          declStr = toString decl;
        in
        if lib.hasPrefix sourceRoot declStr then
          let
            relative = lib.removePrefix (sourceRoot + "/") declStr;
          in
          {
            url = "${gitHubBaseUrl}/${relative}";
            name = relative;
          }
        else
          decl
      ) opt.declarations;
    };

  optionsDocs = pkgs.nixosOptionsDoc {
    options = evaluated.options;
    inherit transformOptions;
    warningsAreErrors = false;
  };

in
{
  json = optionsDocs.optionsJSON;
  commonMark = optionsDocs.optionsCommonMark;
}
