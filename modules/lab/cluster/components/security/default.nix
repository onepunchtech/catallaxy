# Security policies — default-deny network policies for lab namespaces.
#
# When cluster.security.networkPolicies.enable = true, generates a
# default-deny NetworkPolicy for every lab-managed namespace. This blocks
# all traffic except:
#   - DNS (UDP 53) egress to kube-system
#   - Same-namespace pod-to-pod traffic
#
# Components add their own allow rules as additional NetworkPolicy resources
# in their phase bundles (conditioned on config.cluster.security.networkPolicies.enable).
{ config, lib, ... }:

let
  inherit (lib) mkIf;
  cfg = config.cluster.security.networkPolicies;

  # Collect all lab-managed namespaces
  allNamespaces = lib.unique (
    lib.concatLists (
      lib.mapAttrsToList (
        _: phaseCfg: lib.concatMap (b: b.createNamespaces or [ ]) (lib.attrValues phaseCfg.bundles)
      ) config.phases
    )
  );

  # Generate a default-deny + allow-DNS + allow-same-namespace policy per namespace
  defaultDenyResources = lib.listToAttrs (
    map (
      ns:
      lib.nameValuePair "netpol-default-deny-${ns}" {
        apiVersion = "networking.k8s.io/v1";
        kind = "NetworkPolicy";
        metadata = {
          name = "default-deny";
          namespace = ns;
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        spec = {
          podSelector = { }; # All pods in namespace
          policyTypes = [
            "Ingress"
            "Egress"
          ];
          ingress = [
            {
              # Allow same-namespace traffic
              from = [
                {
                  podSelector = { };
                }
              ];
            }
          ];
          egress = [
            {
              # Allow DNS resolution
              to = [ { } ];
              ports = [
                {
                  port = 53;
                  protocol = "UDP";
                }
                {
                  port = 53;
                  protocol = "TCP";
                }
              ];
            }
            {
              # Allow same-namespace traffic
              to = [
                {
                  podSelector = { };
                }
              ];
            }
          ];
        };
      }
    ) allNamespaces
  );
in
{
  config = mkIf cfg.enable {
    # Deploy default-deny policies in the networking phase (after namespaces exist)
    phases.networking.bundles.default-network-policies.resources = defaultDenyResources;
  };
}
