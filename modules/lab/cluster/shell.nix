{ lib, ... }:
{
  options.shell.packages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = ''
      Packages to add to this lab's dev shell. Floes contribute their
      host-side wrappers here.
    '';
  };
}
