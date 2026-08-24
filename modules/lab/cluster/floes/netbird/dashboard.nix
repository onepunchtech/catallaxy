{
  lib,
  cfg,
  nb,
  k8sHelpers,
  sectionName,
  internalGatewayName,
  gatewayName,
  gatewayNamespace,
}:
let
  inherit (lib) optionalAttrs;
  inherit (nb) dashboardDomain managedBy;

  dashboardEnv = [
    {
      name = "AUTH_AUDIENCE";
      value = cfg.dashboard.oidc.clientId;
    }
    {
      name = "AUTH_CLIENT_ID";
      value = cfg.dashboard.oidc.clientId;
    }
    {
      name = "AUTH_AUTHORITY";
      value = cfg.dashboard.oidc.issuerUrl;
    }
    {
      name = "USE_AUTH0";
      value = "false";
    }
    {
      name = "AUTH_SUPPORTED_SCOPES";
      value = lib.concatStringsSep " " cfg.dashboard.oidc.scopes;
    }
    {
      name = "AUTH_REDIRECT_URI";
      value = cfg.dashboard.oidc.authRedirectPath;
    }
    {
      name = "AUTH_SILENT_REDIRECT_URI";
      value = cfg.dashboard.oidc.silentRedirectPath;
    }
    {
      name = "NETBIRD_TOKEN_SOURCE";
      value = "idToken";
    }
    {
      name = "NETBIRD_MGMT_API_ENDPOINT";
      value = "https://${cfg.domain}";
    }
    {
      name = "NETBIRD_MGMT_GRPC_API_ENDPOINT";
      value = "https://${cfg.domain}";
    }

    {
      name = "NGINX_PID";
      value = "/tmp/nginx.pid";
    }
  ];

  resources = optionalAttrs cfg.dashboard.enable {
    netbird-dashboard-svc = {
      apiVersion = "v1";
      kind = "Service";
      metadata = {
        name = "netbird-dashboard";
        namespace = cfg.namespace;
        labels = managedBy;
      };
      spec = {
        type = "ClusterIP";
        selector."app.kubernetes.io/name" = "netbird-dashboard";
        ports = [
          {
            name = "http";
            port = 80;

            targetPort = 80;
          }
        ];
      };
    };

    netbird-dashboard = {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        name = "netbird-dashboard";
        namespace = cfg.namespace;
        labels = managedBy // {
          "app.kubernetes.io/name" = "netbird-dashboard";
        };
      };
      spec = {
        replicas = cfg.dashboard.replicas;
        selector.matchLabels."app.kubernetes.io/name" = "netbird-dashboard";
        template = {
          metadata.labels."app.kubernetes.io/name" = "netbird-dashboard";
          spec = {
            containers = [
              {
                name = "dashboard";
                image = cfg.images.dashboard.ref;
                env = dashboardEnv;
                ports = [
                  {
                    name = "http";

                    containerPort = 80;
                  }
                ];
                resources = cfg.dashboard.resources;

                volumeMounts = [
                  {
                    name = "tmp";
                    mountPath = "/tmp";
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "tmp";
                emptyDir = { };
              }
            ];
          };
        };
      };
    };

    netbird-dashboard-route = k8sHelpers.mkHttpRoute {
      name = "netbird-dashboard";
      namespace = cfg.namespace;
      hostname = dashboardDomain;
      labels = managedBy;
      gatewayParent = k8sHelpers.mkGatewayParent {
        name = if cfg.dashboard.gateway.tier == "internal" then internalGatewayName else gatewayName;
        namespace = gatewayNamespace;
        inherit sectionName;
      };
      backend = {
        name = "netbird-dashboard";
        port = 80;
      };
    };
  };

  cert = optionalAttrs (cfg.dashboard.enable && cfg.tls.issuerRef != null) {
    netbird-dashboard-tls = k8sHelpers.mkCertificate {
      name = cfg.dashboard.tls.secretName;
      namespace = cfg.namespace;
      secretName = cfg.dashboard.tls.secretName;
      issuerRef = {
        inherit (cfg.tls.issuerRef) name kind;
      };
      dnsNames = [ dashboardDomain ];
      labels = managedBy;
    };
  };
in
{
  inherit resources cert;
}
