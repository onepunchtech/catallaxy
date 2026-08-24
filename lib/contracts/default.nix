{ lib }:

{
  oidc = import ./oidc { inherit lib; };
  tls = import ./tls.nix { inherit lib; };
  gateway-api = import ./gateway-api.nix { inherit lib; };
  api-gateway = import ./api-gateway.nix { inherit lib; };
}
