{ cfg, nb }:
let
  inherit (nb) managedBy;
in
{
  netbird-relay-sa = {
    apiVersion = "v1";
    kind = "ServiceAccount";
    metadata = {
      name = "netbird-relay";
      namespace = cfg.namespace;
      labels = managedBy;
    };
  };

  netbird-relay-svc = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "netbird-relay";
      namespace = cfg.namespace;
      labels = managedBy;
    };
    spec = {
      type = "ClusterIP";
      selector."app.kubernetes.io/name" = "netbird-relay";
      ports = [
        {
          name = "http";
          port = 33080;
          targetPort = "ws";
          protocol = "TCP";
        }
        {
          name = "metrics";
          port = 9090;
          targetPort = "metrics";
          protocol = "TCP";
        }
      ];
    };
  };

  netbird-relay = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = "netbird-relay";
      namespace = cfg.namespace;
      labels = managedBy // {
        "app.kubernetes.io/name" = "netbird-relay";
      };
    };
    spec = {
      replicas = 1;
      selector.matchLabels."app.kubernetes.io/name" = "netbird-relay";
      template = {
        metadata.labels."app.kubernetes.io/name" = "netbird-relay";
        spec = {
          serviceAccountName = "netbird-relay";
          containers = [
            {
              name = "netbird-relay";
              image = cfg.images.relay.ref;
              imagePullPolicy = "IfNotPresent";
              args = [
                "--log-file"
                "console"
              ];
              env = [
                {
                  name = "NB_LOG_LEVEL";
                  value = "info";
                }
                {
                  name = "NB_LISTEN_ADDRESS";
                  value = ":33080";
                }
                {
                  name = "NB_EXPOSED_ADDRESS";
                  value = cfg.domain;
                }
                {
                  name = "NB_AUTH_SECRET";
                  valueFrom.secretKeyRef = {
                    name = "netbird-relay-secret";
                    key = "netbird-relay-secret-key";
                  };
                }
              ];
              ports = [
                {
                  name = "ws";
                  containerPort = 33080;
                  protocol = "TCP";
                }
                {
                  name = "metrics";
                  containerPort = 9090;
                  protocol = "TCP";
                }
              ];
              livenessProbe.tcpSocket.port = "ws";
              readinessProbe.tcpSocket.port = "ws";
            }
          ];
        };
      };
    };
  };
}
