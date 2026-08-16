{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkDefault;
  labName = config.lab.name;
  zone = config.lab.dns.zone or "";

  caPathExpr = ''"$HOME/.local/share/catallaxy/labs/${labName}/proxy/ca.crt"'';

  inherit
    (import ./scripts.nix {
      inherit
        lib
        pkgs
        labName
        zone
        caPathExpr
        ;
    })
    setupScript
    browserScript
    teardownScript
    exportScript
    ;

in
{

  imports = [ ./options.nix ];

  config.lab.ops.commands.trust.setup = mkDefault {
    description = "Install the lab CA into the operator's OS / browser / Docker trust stores";
    options.docker = {
      type = "bool";
      default = "false";
      description = "Also install into /etc/docker/certs.d/registry.<zone>/ca.crt (Linux, sudo)";
    };
    package = setupScript;
  };

  config.lab.ops.commands.trust.browser = mkDefault {
    description = "Trust the lab CA in your browsers (no sudo)";
    options.firefox-profile = {
      type = "string";
      default = "";
      description = "Only this Firefox profile directory, e.g. a throwaway one for a demo. Created if absent.";
    };
    package = browserScript;
  };

  config.lab.ops.commands.trust.teardown = mkDefault {
    description = "Remove the lab CA from the operator's trust stores";
    package = teardownScript;
  };

  config.lab.ops.commands.trust.export = mkDefault {
    description = "Print the lab CA PEM to stdout";
    package = exportScript;
  };

}
