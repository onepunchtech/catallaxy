{ config, lib, ... }:

let
  inherit (lib) mkIf;
  cfg = config.cluster.security.networkPolicies;

  allNamespaces = lib.unique (
    lib.concatMap (b: b.createNamespaces or [ ]) (lib.attrValues config.bundles)
  );

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
          podSelector = { };
          policyTypes = [
            "Ingress"
            "Egress"
          ];
          ingress = [
            {

              from = [
                {
                  podSelector = { };
                }
              ];
            }
          ];
          egress = [
            {

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

    bundles.default-network-policies.resources = defaultDenyResources;
  };
}
