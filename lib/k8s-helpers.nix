{
  lib,
  waitImages ? { },
}:

let
  inherit (lib) optionalAttrs;
  wait = import ./util/wait.nix {
    inherit lib;
    images = waitImages;
  };
in
rec {

  inherit wait;

  # Which Gateway a floe attaches to. Nine floes wrote this branch out, and
  # it is the whole of what `tier` means at the point of use.
  gatewayNameFor =
    {
      gateway,
      internalGatewayName,
    }:
    if gateway.tier == "internal" then internalGatewayName else gateway.gatewayRef;

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

  # Which Gateway a floe attaches to, and where on it. Eight floes built this
  # attrset by hand, always the same three ways: pick the Gateway by tier, add
  # a namespace if there is one, add the listener.
  #
  # `sectionName` is required rather than defaulted. It is the field the hand
  # written copies disagreed about, and a wrong listener fails at apply time
  # with a message about a parent that does not exist.
  mkGatewayParentFor =
    {
      gateway,
      internalGatewayName,
      sectionName,
      name ? if gateway.tier == "internal" then internalGatewayName else gateway.gatewayRef,
    }:
    {
      inherit name sectionName;
    }
    // optionalAttrs (gateway.gatewayNamespace != null) {
      namespace = gateway.gatewayNamespace;
    };

  # A floe's whole public face: the HTTPRoute that attaches it to a Gateway
  # and the Certificate that terminates TLS for it.
  #
  # Eight floes wrote this out. Five of them hand-rolled the HTTPRoute rather
  # than calling `mkHttpRoute`, and the copies had drifted: those five read
  # the Gateway's exported listener name, and the three that went through
  # `mkGatewayParent` took its "https" default instead. A plaintext lab
  # exports "http", so those three were attaching to a listener that was not
  # there.
  #
  # `sectionName` has no default here for that reason. The caller passes the
  # Gateway's exported name and cannot get it wrong by omission.
  mkGatewayExposure =
    {
      name,
      namespace,
      domain,
      gateway,
      internalGatewayName,
      sectionName,
      backend,
      pathPrefix ? "/",
      routeName ? "${name}-route",
      tls ? null,
      labels ? { },
    }:
    let
      exposed = gateway.enable && domain != "";

      parent = mkGatewayParentFor { inherit gateway internalGatewayName sectionName; };

      route = {
        apiVersion = "gateway.networking.k8s.io/v1";
        kind = "HTTPRoute";
        metadata = {
          inherit name namespace;
        }
        // optionalAttrs (labels != { }) { inherit labels; };
        spec = {
          parentRefs = [ parent ];
          hostnames = [ domain ];
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

      # Deliberately not gated on `gateway.enable`. A floe reached some other
      # way still wants its certificate, and every caller did it this way.
      certified = tls != null && tls.issuerRef != null && domain != "";

      certificate = {
        apiVersion = "cert-manager.io/v1";
        kind = "Certificate";
        metadata = {
          name = tls.secretName;
          inherit namespace;
        }
        // optionalAttrs (labels != { }) { inherit labels; };
        spec = {
          inherit (tls) secretName;
          issuerRef = { inherit (tls.issuerRef) name kind; };
          dnsNames = [ domain ];
        };
      };
    in
    optionalAttrs exposed { "${routeName}" = route; }
    // optionalAttrs certified { "${tls.secretName}" = certificate; };

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
