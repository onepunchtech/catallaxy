{ lib }:

let
  inherit (lib) optionalAttrs;
  wait = import ./util/wait.nix { inherit lib; };
in
{

  inherit wait;

  mkGatewayParent =
    {
      name,
      sectionName ? "https",
      namespace ? null,
    }:
    { inherit name sectionName; } // optionalAttrs (namespace != null) { inherit namespace; };

  mkHttpRoute =
    {
      name,
      namespace,
      hostname,
      gatewayParent,
      backend,
      pathPrefix ? "/",
      labels ? { },
    }:
    {
      apiVersion = "gateway.networking.k8s.io/v1";
      kind = "HTTPRoute";
      metadata = {
        inherit name namespace;
      }
      // optionalAttrs (labels != { }) { inherit labels; };
      spec = {
        parentRefs = [ gatewayParent ];
        hostnames = [ hostname ];
        rules = [
          {
            matches = [
              {
                path = {
                  type = "PathPrefix";
                  value = pathPrefix;
                };
              }
            ];
            backendRefs = [ backend ];
          }
        ];
      };
    };

  mkTlsRoute =
    {
      name,
      namespace,
      hostname,
      gatewayParent,
      backend,
      labels ? { },
    }:
    {
      apiVersion = "gateway.networking.k8s.io/v1alpha2";
      kind = "TLSRoute";
      metadata = {
        inherit name namespace;
      }
      // optionalAttrs (labels != { }) { inherit labels; };
      spec = {
        parentRefs = [ gatewayParent ];
        hostnames = [ hostname ];
        rules = [
          { backendRefs = [ backend ]; }
        ];
      };
    };

  mkCertificate =
    {
      name,
      namespace,
      secretName,
      issuerRef,
      dnsNames,
      labels ? { },
    }:
    {
      apiVersion = "cert-manager.io/v1";
      kind = "Certificate";
      metadata = {
        inherit name namespace;
      }
      // optionalAttrs (labels != { }) { inherit labels; };
      spec = { inherit secretName issuerRef dnsNames; };
    };
}
