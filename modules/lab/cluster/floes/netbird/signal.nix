{
  cfg,
  nb,
}:
let
  inherit (nb)
    signalPort
    signalLegacyGrpcPort
    managedBy
    ;
in
{
  netbird-signal-sa = {
    apiVersion = "v1";
    kind = "ServiceAccount";
    metadata = {
      name = "netbird-signal";
      namespace = cfg.namespace;
      labels = managedBy;
    };
  };

  netbird-signal-svc = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "netbird-signal";
      namespace = cfg.namespace;
      labels = managedBy;
    };
    spec = {
      type = "ClusterIP";
      selector."app.kubernetes.io/name" = "netbird-signal";
      ports = [

        {
          name = "http";
          port = signalPort;
          targetPort = "http";
          protocol = "TCP";
          appProtocol = "kubernetes.io/h2c";
        }

        {
          name = "grpc-compat";
          port = signalLegacyGrpcPort;
          targetPort = signalLegacyGrpcPort;
          protocol = "TCP";
          appProtocol = "kubernetes.io/h2c";
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

  netbird-signal = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = "netbird-signal";
      namespace = cfg.namespace;
      labels = managedBy // {
        "app.kubernetes.io/name" = "netbird-signal";
      };
    };
    spec = {
      replicas = cfg.signal.replicas;
      selector.matchLabels."app.kubernetes.io/name" = "netbird-signal";
      template = {
        metadata.labels."app.kubernetes.io/name" = "netbird-signal";
        spec = {
          serviceAccountName = "netbird-signal";
          containers = [
            {
              name = "netbird-signal";
              image = cfg.images.signal.ref;
              imagePullPolicy = "IfNotPresent";
              args = [
                "--port"
                (toString signalPort)
                "--log-level"
                "info"
                "--log-file"
                "console"
              ];
              ports = [
                {
                  name = "http";
                  containerPort = signalPort;
                  protocol = "TCP";
                }
                {
                  name = "grpc-compat";
                  containerPort = signalLegacyGrpcPort;
                  protocol = "TCP";
                }
                {
                  name = "metrics";
                  containerPort = 9090;
                  protocol = "TCP";
                }
              ];
              livenessProbe.tcpSocket.port = "http";
              readinessProbe.tcpSocket.port = "http";
            }
          ];
        };
      };
    };
  };
}
