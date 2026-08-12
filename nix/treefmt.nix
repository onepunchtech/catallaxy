{ lib, rustToolchain }:

{
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;

  programs.rustfmt = {
    enable = true;
    package = rustToolchain;
    edition = "2024";
  };

  programs.yamlfmt.enable = true;

  programs.prettier.enable = true;
  programs.prettier.settings = {
    proseWrap = "always";
    printWidth = 76;
  };

  settings.formatter.prettier = {
    includes = lib.mkForce [ "*.md" ];
    excludes = [ "docs/book/src/SUMMARY.md" ];
  };
}
