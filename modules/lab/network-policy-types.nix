{ lib }:

let
  inherit (lib) mkOption types;

  protocol = mkOption {
    type = types.enum [
      "TCP"
      "UDP"
      "SCTP"
    ];
    default = "TCP";
    description = "Transport protocol.";
  };

  portType = types.submodule {
    options = {
      port = mkOption {
        type = types.either types.int types.str;
        example = 8200;
        description = "Port number, or the name a container gave it.";
      };
      inherit protocol;
    };
  };

  ports = mkOption {
    type = types.listOf (
      types.coercedTo types.int (p: { port = p; }) (types.coercedTo types.str (p: { port = p; }) portType)
    );
    default = [ ];
    example = [ 443 ];
    description = ''
      Ports the rule covers. Empty is not a request: a rule that names no
      port is not written.
    '';
  };

  cidrType = types.submodule {
    options = {
      cidr = mkOption {
        type = types.str;
        example = "10.0.0.0/8";
        description = "Address range the rule covers.";
      };

      except = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Ranges carved back out of `cidr`.";
      };

      inherit ports;
    };
  };

  egressOptions = {
    internet = mkOption {
      type = types.submodule { options = { inherit ports; }; };
      default = { };
      description = ''
        Destinations outside the cluster: an ACME server, a git remote, a
        cloud API, an object store.

        Named ports rather than a bare toggle, because this is the broadest
        thing that can be asked for and "443 outbound" is a different request
        from "anything anywhere".
      '';
    };

    cidrs = mkOption {
      type = types.listOf cidrType;
      default = [ ];
      description = "Address ranges, for anything neither a floe nor the open internet.";
    };
  };
in
{
  inherit portType cidrType;

  networkType = types.submodule {
    options = {
      declared = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this floe's network needs have been worked out.

          A floe needing nothing beyond what every namespace gets by default
          still sets this: otherwise it is indistinguishable from one nobody
          has looked at, and the difference is the whole point of asking.
        '';
      };

      serves = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              port = mkOption {
                type = types.either types.int types.str;
                example = 8200;
                description = ''
                  The port this floe answers on. Checked against the Services
                  the floe actually renders, so a number that is wrong is a
                  build failure rather than a broken lab.
                '';
              };

              inherit protocol;

              fromExternal = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Whether this port is reached from outside the cluster, as
                  it is behind a LoadBalancer or a NodePort.
                '';
              };

              fromApiServer = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Whether the API server calls this port, which is what an
                  admission webhook receives.

                  Egress to the API server every namespace has already,
                  because nearly everything needs it. This is the other
                  direction, and only a floe registering a webhook wants it.
                '';
              };
            };
          }
        );
        default = { };
        example = lib.literalExpression "{ api.port = 8200; }";
        description = ''
          Ports this floe answers on, each under a label other floes name.

          The label is the interface. Renaming one breaks the floes that
          reach it, loudly, at evaluation.
        '';
      };

      reaches = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "openbao/api" ];
        description = ''
          Other floes this one connects to, as `<floe>/<label>` naming a
          label that floe published in `serves`.

          No port number here, deliberately. The one on the other side is the
          only one, so the two cannot disagree. A label that no enabled floe
          serves is an evaluation error rather than a rule that renders and
          does nothing.

          Ingress on the other end is derived from this, so a flow is
          declared once and cannot be half-declared.
        '';
      };

      egress = mkOption {
        type = types.submodule { options = egressOptions; };
        default = { };
        description = "What this floe connects out to, other than other floes.";
      };
    };
  };

  namespacePolicyType = types.submodule {
    options = {
      dns = mkOption {
        type = types.bool;
        default = true;
        description = "Allow DNS egress, without which nothing resolves.";
      };

      apiServer = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Allow egress to the Kubernetes API server. Nearly every floe runs a
          controller that needs it, and a pod that cannot reach it is the
          common broken case.
        '';
      };

      sameNamespace = mkOption {
        type = types.bool;
        default = true;
        description = "Allow pods in the namespace to reach each other.";
      };

      egress = mkOption {
        type = types.submodule { options = egressOptions; };
        default = { };
        description = "Extra egress every pod in the namespace gets.";
      };

      ingress = mkOption {
        type = types.submodule {
          options = {
            cidrs = mkOption {
              type = types.listOf cidrType;
              default = [ ];
              description = "Address ranges allowed to reach the namespace.";
            };
          };
        };
        default = { };
        description = "Extra ingress every pod in the namespace accepts.";
      };
    };
  };
}
