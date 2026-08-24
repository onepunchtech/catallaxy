{ config, lib, ... }:
let
  cfg = config.floes.netbird;
  nb = import ./lib.nix { inherit lib cfg; };

  inherit (lib) optional optionalAttrs;

  inherit (nb)
    idpClientId
    idpIssuer
    idpMachineTokenEndpoint
    idpMachineTokenRef
    hasCaBundle
    apiTokenSecretName
    jwtGroupUuidsSecretName
    jwtDiscoverySpnsJson
    owner
    managedBy
    ;

  catalLib = import ../../../../../lib/util/idempotent-job.nix { inherit lib; };

  bootstrapRbac = {
    netbird-bootstrap-sa = {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = {
        name = "netbird-bootstrap";
        namespace = cfg.namespace;
        labels = managedBy;
      };
    };
    netbird-bootstrap-role = {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = {
        name = "netbird-bootstrap";
        namespace = cfg.namespace;
        labels = managedBy;
      };
      rules = [
        {
          apiGroups = [ "" ];
          resources = [ "secrets" ];
          verbs = [
            "get"
            "create"
            "update"
            "patch"
          ];
        }

        {
          apiGroups = [ "kaniop.rs" ];
          resources = [ "kanidmoauth2clients" ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
      ];
    };
    netbird-bootstrap-rb = {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = {
        name = "netbird-bootstrap";
        namespace = cfg.namespace;
        labels = managedBy;
      };
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "netbird-bootstrap";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "netbird-bootstrap";
          namespace = cfg.namespace;
        }
      ];
    };
  };

  netbirdBootstrapScript = builtins.readFile ./scripts/bootstrap.sh;

  netbirdBootstrapPodSpec = {
    serviceAccountName = "netbird-bootstrap";
    restartPolicy = "OnFailure";
    containers = [
      {
        name = "bootstrap";
        image = cfg.images.bootstrap.ref;
        env = [
          {
            name = "NB_NS";
            value = cfg.namespace;
          }
          {
            name = "NB_URL";
            value = "http://netbird-management.${cfg.namespace}.svc.cluster.local";
          }
          {
            name = "OAUTH2_CLIENT_NAME";
            value = idpClientId;
          }
          {
            name = "BOT_TOKEN_NS";
            value =
              if idpMachineTokenRef != null && idpMachineTokenRef.namespace != null then
                idpMachineTokenRef.namespace
              else
                cfg.namespace;
          }
          {
            name = "BOT_TOKEN_SECRET";
            value = if idpMachineTokenRef != null then idpMachineTokenRef.name else "";
          }
          {
            name = "BOT_TOKEN_KEY";
            value = if idpMachineTokenRef != null then idpMachineTokenRef.key else "token";
          }
          {
            name = "TOKEN_ENDPOINT";
            value = idpMachineTokenEndpoint;
          }
          {
            name = "OIDC_DISCOVERY";
            value = if idpIssuer != "" then "${idpIssuer}/.well-known/openid-configuration" else "";
          }
          {
            name = "OUT_SECRET";
            value = apiTokenSecretName;
          }
          {
            name = "OUT_KEY";
            value = cfg.operator.apiTokenSecretKey;
          }
          {

            name = "NB_JWT_SPNS_JSON";
            value = jwtDiscoverySpnsJson;
          }
          {
            name = "JWT_GROUP_UUIDS_SECRET";
            value = jwtGroupUuidsSecretName;
          }

          # These three used to be spliced into the script as Nix string
          # interpolations, which is why it could not live in a .sh file.
          # They are jq arguments now, so the script is a script.
          {
            name = "NB_LAZY_CONNECTIONS";
            value = if cfg.lazyConnections then "true" else "false";
          }
          {
            name = "NB_JWT_GROUPS_CLAIM";
            value = cfg.operator.jwtGroupsClaimName;
          }
          {
            name = "NB_JWT_ALLOW_GROUPS";
            value = builtins.toJSON cfg.operator.autoGroupsFromJwt;
          }
        ];
        command = [
          "bash"
          "-c"
        ];
        args = [ netbirdBootstrapScript ];
        volumeMounts = optional hasCaBundle {
          name = "lab-ca";
          mountPath = "/etc/ssl/certs/lab-ca.crt";
          subPath = cfg.tls.caBundle.key;
          readOnly = true;
        };
      }
    ];
    volumes = optional hasCaBundle {
      name = "lab-ca";
      configMap.name = cfg.tls.caBundle.name;
    };
  };

  botTokenNs =
    if idpMachineTokenRef != null then
      (if idpMachineTokenRef.namespace != null then idpMachineTokenRef.namespace else cfg.namespace)
    else
      null;

  botTokenRbac =
    if (idpMachineTokenRef != null && botTokenNs != cfg.namespace) then
      {
        netbird-bootstrap-bot-token-reader-role = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          metadata = {
            name = "netbird-bootstrap-bot-token-reader";
            namespace = botTokenNs;
            labels = managedBy;
          };
          rules = [
            {
              apiGroups = [ "" ];
              resources = [ "secrets" ];
              resourceNames = [ idpMachineTokenRef.name ];
              verbs = [
                "get"
                "list"
                "watch"
              ];
            }
          ];
        };
        netbird-bootstrap-bot-token-reader-rb = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          metadata = {
            name = "netbird-bootstrap-bot-token-reader";
            namespace = botTokenNs;
            labels = managedBy;
          };
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "netbird-bootstrap-bot-token-reader";
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = "netbird-bootstrap";
              namespace = cfg.namespace;
            }
          ];
        };
      }
    else
      { };

  netbirdBootstrapJobResources =
    if idpMachineTokenRef != null then
      (catalLib.mkIdempotentJob {
        name = "netbird-bootstrap";
        namespace = cfg.namespace;
        contentInputs = {
          issuer = idpIssuer;
          clientID = idpClientId;
          tokenEndpoint = idpMachineTokenEndpoint;
          botTokenName = idpMachineTokenRef.name;
          botTokenNs = botTokenNs;
          botTokenKey = idpMachineTokenRef.key;
          netbirdUrl = "http://netbird-management.${cfg.namespace}.svc.cluster.local";
          outSecret = apiTokenSecretName;
          outKey = cfg.operator.apiTokenSecretKey;
        };
        behaviourVersion = 1;
        podSpec = netbirdBootstrapPodSpec;
      }).resources
      // botTokenRbac
    else
      { };
in
{
  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && cfg.management.enable) {
      floes.netbird.bundles.netbird-prechart = {
        inherit owner;
        resources = bootstrapRbac;
        createNamespaces = [ cfg.namespace ];

        provides = [ "netbird/prechart/ready" ];
      };
    })

    (lib.mkIf (cfg.enable && cfg.management.enable && idpMachineTokenRef != null) {
      floes.netbird.bundles.netbird-bootstrap = {
        inherit owner;
        resources = netbirdBootstrapJobResources;

        requires = [

          "netbird/prechart/ready"

          "netbird/management/ready"
        ]

        ++ [ "certificate-issuance/webhook/ready" ];

        after = [
          "optional:provides:coredns/lab-dns/ready"
          "optional:identity/provisioning/ready"
        ];
        provides = [ "netbird/api-key/ready" ];
        readyProbe = {
          kind = "jsonpath";
          resource = "secret/${apiTokenSecretName}";
          namespace = cfg.namespace;
          jsonpath = "{.data.${cfg.operator.apiTokenSecretKey}}";
          timeout = "10m";
        };
      };
    })
  ];
}
