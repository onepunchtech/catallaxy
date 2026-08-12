{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.lab.trust.installIntoHostStore = mkOption {
    type = types.bool;
    default = false;
    description = ''
      Install the lab CA into the host OS trust store as part of
      `cata lab up`.

      Off by default. The CLI hands every tool it spawns a merged CA
      bundle (public roots + this lab's CA) through `SSL_CERT_FILE` and
      friends, and `cata lab env <lab>` gives your own shell the same
      trust, so examples, demos and CI need no `sudo`, no
      `update-ca-certificates`, and on NixOS no `nixos-rebuild`.

      Turn it on for a long-lived lab where you want browsers, editors
      and hand-run tools to trust `*.<zone>` without entering the lab's
      shell. On NixOS the store is declarative, so the step asserts the
      CA is already in `security.pki.certificateFiles` rather than
      installing it, and fails with instructions if it is not.
    '';
  };
}
