{
  lab,
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkDefault types;
in
{

  config.floes.gateway.namespace = mkDefault "kube-system";

  options.floes.gateway = {
    controller = mkOption {
      type = types.enum [
        "traefik"
        "external"
      ];
      default = "traefik";
      description = ''
        Gateway controller to deploy:
        - traefik: deploy Traefik v3 (default, good for k3d labs)
        - external: skip controller deployment (use with Cilium or pre-installed controller)
      '';
    };

    controllerName = mkOption {
      type = types.str;
      default = "traefik.io/gateway-controller";
      description = "Gateway controller name for the GatewayClass";
    };

    className = mkOption {
      type = types.str;
      default = "traefik";
      description = "GatewayClass name";
    };

    gatewayName = mkOption {
      type = types.str;
      default = "default-gateway";
      description = "Gateway resource name (components reference this via gateway.gatewayRef)";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.traefik.chart;
      description = "Traefik Helm chart derivation";
    };

    tls = {
      enable = mkOption {
        type = types.bool;
        default =
          config.floes.gateway.tls.domain != ""
          && (config.floes.cert-manager.exports.issuance or null) != null;
        defaultText = lib.literalExpression "tls.domain != \"\" && cert-manager can issue";
        description = ''
          Serve an HTTPS listener, and expose :443 on the tier Services.

          Derived: on as soon as there is a domain to name a certificate
          after and an issuer to sign it. A lab that declared a zone and
          a CA but forgot this got plain HTTP on :80 only, which breaks
          every in-cluster consumer that follows an issuer's discovery
          document to an `https://` endpoint (mesh.local, 2026-08-01).

          Set false for a deliberately plaintext lab.
        '';
      };

      issuerRef = mkOption {
        type = types.submodule {
          options = {
            name = mkOption { type = types.str; };
            kind = mkOption {
              type = types.str;
              default = "ClusterIssuer";
            };
          };
        };
        default = {
          name = "lab-ca";
          kind = "ClusterIssuer";
        };
      };

      domain = mkOption {
        type = types.str;
        default = lab.dns.zone or "";
        defaultText = lib.literalExpression "lab.dns.zone";
        description = ''
          Base domain for the wildcard certificate. Defaults to the lab's
          DNS zone, which is the name every route is served under.
        '';
      };

      extraCertificateRefs = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              name = mkOption { type = types.str; };
              namespace = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
            };
          }
        );
        default = [ ];
        example = lib.literalExpression ''
          [ { name = "elitemoneyranger-public-tls"; } ]
        '';
        description = ''
          Additional TLS certificate Secret refs to attach to the
          gateway's HTTPS listener. Use when a component brings a
          hostname outside the gateway's wildcard zone (e.g. a
          customer-owned apex). Downstream floes contribute via
          `floes.gateway.tls.extraCertificateRefs = [{ name = "<their-secret>"; }];`.
        '';
      };

      passthrough = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable TLS passthrough listener (for backends that terminate TLS themselves)";
        };
        port = mkOption {
          type = types.port;
          default = 8444;
          description = "Traefik entryPoint port for TLS passthrough (must differ from websecure port)";
        };
      };
    };

    internal = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable a second Gateway resource named `<internal.name>` in
          the same namespace as the public gateway. Services with
          `gateway.tier = "internal"` attach to it. The Gateway's
          listeners are identical to the public gateway's; only the
          Service exposure differs (see `exposureMode`).
        '';
      };

      name = mkOption {
        type = types.str;
        default = "internal-gateway";
        description = "Internal Gateway resource name";
      };

      domain = mkOption {
        type = types.str;
        default = lab.dns.internalZone or "";
        defaultText = lib.literalExpression "lab.dns.internalZone";
        description = ''
          DNS zone the internal tier is named under.

          The gateway owns this because it owns the tier, and it
          publishes it as `exports.internalDomain` so consumers derive
          it rather than restating it; netbird pushes exactly this
          zone to mesh peers, and the wildcard certificate covers it.

          It must not be the lab's public zone. Whoever resolves the
          internal tier claims the whole zone, so sharing one zone with
          the host ingress makes every public name unresolvable the
          moment a peer joins (mesh.local, 2026-08-04).
        '';
      };

      exposureMode = mkOption {
        type = types.enum [
          "haproxy-local"
          "netbird"
          "none"
        ];
        default = "haproxy-local";
        description = ''
          How the internal Gateway is reachable from the operator's
          machine:
          - `haproxy-local` (default for local k3d): the lab haproxy
            sees the internal-gateway just like the public one. No
            actual restriction; topology parity only.
          - `netbird`: the operator reaches the internal gateway via
            a ClusterIP that lives in the cluster's service CIDR,
            routed over the netbird mesh by the cluster's
            `floes.netbird` routing. Internal hostnames resolve to
            that ClusterIP via cluster CoreDNS (see
            `cluster/coredns-internal`). Off-mesh peers cannot reach
            internal services: DNS visibility and L3 routing both
            gate them.
          - `none`: ClusterIP Service, no auto-exposure. Operator
            connects via `kubectl port-forward` or rolls their own.
        '';
      };

      clusterIPAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "10.96.0.250";
        description = ''
          Pinned `spec.clusterIP` for the `traefik-internal` Service
          (sibling of the existing traefik LoadBalancer Service, same
          pod selector). Must sit inside `cluster.network.serviceSubnet`
          but outside the kube-allocated range: convention is the
          high `.250` octet. Required when
          `internal.exposureMode == "netbird"`; cluster CoreDNS will
          use this address as the A record for internal-tier
          hostnames so mesh-routed traffic flows directly to traefik
          via the service CIDR.
        '';
      };
    };

    internalHostnames = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Hostnames belonging to the internal tier. Populated by downstream floes.";
    };
  };
}
