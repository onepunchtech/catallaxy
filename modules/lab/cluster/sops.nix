{ config, lib, ... }:

let
  cfg = config.secrets.sops;
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;
in
{
  options.secrets.sops = {
    enable = mkEnableOption "SOPS secrets management";

    ageKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to age private key for decryption";
    };

    defaultEncryptedSuffix = mkOption {
      type = types.str;
      default = ".enc.yaml";
      description = "File suffix for encrypted files";
    };
  };

}
