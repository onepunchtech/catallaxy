{ config, lib, ... }:
let
  cfg = config.floes.netbird;
  nb = import ./lib.nix { inherit lib cfg; };

  inherit (lib) mkIf;
  inherit (nb)
    apiTokenSecretName
    allGroups
    allSetupKeys
    owner
    managedBy
    ;

  groupResources = lib.mapAttrs' (
    name: def:
    lib.nameValuePair "netbird-group-${name}" {
      apiVersion = "netbird.io/v1alpha1";
      kind = "Group";
      metadata = {
        inherit name;
        namespace = cfg.namespace;
        labels = managedBy;
      };
      spec = {
        name = def.specName;
      };
    }
  ) allGroups;

  setupKeyResources = lib.mapAttrs' (
    name: spec:
    lib.nameValuePair "netbird-setupkey-${name}" {
      apiVersion = "netbird.io/v1alpha1";
      kind = "SetupKey";
      metadata = {
        inherit name;
        namespace = cfg.namespace;
        labels = managedBy;
      };
      spec = {
        inherit name;
        ephemeral = spec.ephemeral or false;
        allowExtraDnsLabels = false;
        duration = spec.duration or "8760h";
        autoGroups = map (g: {
          localRef = {
            name = g;
          };
        }) (spec.autoGroups or [ ]);
      };
    }
  ) allSetupKeys;
in
{
  config = lib.mkMerge [
    (mkIf (cfg.enable && cfg.operator.enable && cfg.operator.crds != null) {
      floes.netbird.network = {
        declared = true;

        egress.internet.ports = [ 443 ];
      };

      floes.netbird.imagesComplete = true;

      floes.netbird.images.operator = {
        registry = "ghcr.io";
        repository = "netbirdio/netbird-operator";
        tag = "v0.7.0";
      };

      floes.netbird.bundles.netbird-operator-crds = {
        inherit owner;
        yamls = [ cfg.operator.crds ];
        provides = [
          "netbird/operator-crds/established"
          "kind:netbird.io/Group"
          "kind:netbird.io/SetupKey"
          "kind:netbird.io/NBGroup"
          "kind:netbird.io/NBPolicy"
          "kind:netbird.io/NBResource"
          "kind:netbird.io/NBRoutingPeer"
          "kind:netbird.io/NBSetupKey"
        ];
      };
    })

    (mkIf (cfg.enable && cfg.operator.enable) {
      floes.netbird.bundles.netbird-operator = {
        inherit owner;

        requires = [

          "netbird/api-key/ready"
          "netbird/operator-crds/established"
        ]

        ++ [ "certificate-issuance/webhook/ready" ];
        provides = [ "netbird/operator/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/netbird-operator";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "10m";
        };

        helmCharts.netbird-operator = {
          chart = cfg.operator.chart;
          releaseName = "netbird-operator";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {

            managementURL =
              if cfg.operator.managementUrl != "" then
                cfg.operator.managementUrl
              else
                "http://netbird-management.${cfg.namespace}.svc.cluster.local";
            netbirdAPI.keyFromSecret = {
              name = apiTokenSecretName;
              key = cfg.operator.apiTokenSecretKey;
            };

            webhook.failurePolicy = "Ignore";
          };
        };
      };
    })

    (mkIf (cfg.enable && cfg.operator.enable) {
      floes.netbird.bundles.netbird-state = {
        inherit owner;
        resources = groupResources // setupKeyResources;

        requires = [ "netbird/operator/ready" ];
        provides = [ "netbird/setup-keys/ready" ];

        readyProbe =
          if cfg.agent.enable && cfg.agent.setupKeyRef.name != "" then
            {
              kind = "jsonpath";
              resource = "secret/${cfg.agent.setupKeyRef.name}";
              namespace = cfg.agent.namespace;
              jsonpath = "{.data.${cfg.agent.setupKeyRef.key}}";
              timeout = "10m";
            }
          else
            null;
      };
    })
  ];
}
