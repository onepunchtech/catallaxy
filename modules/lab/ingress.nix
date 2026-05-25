# modules/lab/ingress.nix
#
# Lab ingress — HAProxy container on host ports 80/443 that routes
# by domain to the correct k3d cluster. Discovers services from all
# clusters' gateway-enabled components at Nix eval time.
#
# Two routing modes:
# - TLS terminate: HAProxy terminates TLS with a wildcard cert, routes
#   HTTP by Host header to the cluster's gateway HTTP port (80).
# - TLS passthrough: HAProxy inspects SNI and forwards raw TLS to the
#   cluster's gateway passthrough port (8444).

{ config, lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    concatStringsSep
    concatLists
    mapAttrsToList
    filter
    map
    unique
    ;
  cfg = config.lab.ingress;

  # Discover exposed services from all clusters
  exposedServices = concatLists (
    mapAttrsToList (
      clusterName: clusterCfg:
      let
        components = clusterCfg.components or { };
        k3dClusterName = clusterCfg.provisioner.k3d.clusterName or clusterName;
        upstream = "k3d-${k3dClusterName}-server-0";
        passthroughPort = clusterCfg.components.gateway.tls.passthrough.port or 8444;
      in
      filter (s: s != null) (
        mapAttrsToList (
          compName: comp:
          let
            isEnabled = comp.enable or false;
            hasDomain =
              (comp ? domain) && (comp.domain or "") != "" && (comp.domain or "") != "idm.example.com";
            hasGateway = (comp ? gateway) && ((comp.gateway or { }).enable or false);
          in
          if isEnabled && hasDomain && hasGateway then
            {
              name = compName;
              cluster = clusterName;
              domain = comp.domain;
              mode = (comp.gateway or { }).mode or "terminate";
              inherit upstream passthroughPort;
            }
          else
            null
        ) components
      )
    ) config.lab.out.allClusters
  );

  terminateServices = filter (s: s.mode == "terminate") exposedServices;
  passthroughServices = filter (s: s.mode == "passthrough") exposedServices;

  # Unique clusters that have terminate services
  terminateClusters = unique (map (s: s.upstream) terminateServices);
  # Unique clusters that have passthrough services
  passthroughClusters = unique (map (s: s.upstream) passthroughServices);

  # HAProxy config
  haproxyConfig =
    let
      # SNI ACLs for passthrough domains
      passthroughAcls = concatStringsSep "\n" (
        map (
          svc: "    use_backend bk_pass_${svc.cluster} if { req.ssl_sni -i ${svc.domain} }"
        ) passthroughServices
      );

      # Host ACLs for terminate domains (route by Host header after TLS termination)
      terminateAcls = concatStringsSep "\n" (
        map (
          svc: "    use_backend bk_http_${svc.cluster} if { hdr(host) -i ${svc.domain} }"
        ) terminateServices
      );

      # HTTP backends (one per cluster with terminate services)
      # init-addr none: start without resolving; resolve lazily on first request
      # (k3d clusters may not exist yet when HAProxy starts)
      httpBackends = concatStringsSep "\n\n" (
        map (
          upstream:
          let
            cluster = (builtins.head (filter (s: s.upstream == upstream) terminateServices)).cluster;
          in
          ''
            backend bk_http_${cluster}
                mode http
                server srv1 ${upstream}:80 init-addr none resolvers docker resolve-prefer ipv4''
        ) terminateClusters
      );

      # Passthrough backends (one per cluster with passthrough services)
      passthroughBackends = concatStringsSep "\n\n" (
        map (
          upstream:
          let
            svc = builtins.head (filter (s: s.upstream == upstream) passthroughServices);
          in
          ''
            backend bk_pass_${svc.cluster}
                mode tcp
                server srv1 ${upstream}:${toString svc.passthroughPort} init-addr none resolvers docker resolve-prefer ipv4''
        ) passthroughClusters
      );
    in
    ''
      global
          log stdout format raw local0 info

      resolvers docker
          nameserver dns1 127.0.0.11:53
          resolve_retries 30
          timeout resolve 1s
          timeout retry 1s
          hold valid 10s

      defaults
          timeout connect 5s
          timeout client 30s
          timeout server 30s
          log global

      # Port 443: SNI-based routing
      frontend ft_ssl
          bind *:443
          mode tcp
          tcp-request inspect-delay 5s
          tcp-request content accept if { req_ssl_hello_type 1 }

          # Passthrough routes (raw TLS by SNI)
      ${passthroughAcls}

          # Everything else → TLS termination
          default_backend bk_local_https

      # Internal loopback for TLS termination
      backend bk_local_https
          mode tcp
          server loopback 127.0.0.1:8443

      # Terminated HTTPS → route by Host header
      frontend ft_https
          bind 127.0.0.1:8443 ssl crt /etc/haproxy/certs/lab.pem
          mode http

      ${terminateAcls}

      # Port 80: redirect to HTTPS
      frontend ft_http
          bind *:80
          mode http
          http-request redirect scheme https code 301

      ${httpBackends}

      ${passthroughBackends}
    '';
in
{
  options.lab.ingress = {
    enable = mkEnableOption "Lab ingress (HAProxy for domain-based routing to k3d clusters)";

    httpPort = mkOption {
      type = types.port;
      default = 80;
      description = "Host port for HTTP (redirects to HTTPS)";
    };

    httpsPort = mkOption {
      type = types.port;
      default = 443;
      description = "Host port for HTTPS";
    };

    image = mkOption {
      type = types.str;
      default = "haproxy:3.1-alpine";
      description = "HAProxy container image";
    };

    containerName = mkOption {
      type = types.str;
      default = "catallaxy-ingress";
      description = "Docker container name for the ingress";
    };

    out = {
      service = mkOption {
        type = types.attrs;
        readOnly = true;
        description = "Computed container service definition for the lab ingress";
      };
    };
  };

  config.lab.ingress.out = mkIf cfg.enable {
    service = {
      description = "HAProxy lab ingress (${config.lab.dns.zone})";
      container = cfg.containerName;
      image = cfg.image;
      ports = [
        "${toString cfg.httpPort}:80"
        "${toString cfg.httpsPort}:443"
      ];
      volumes = {
        "/usr/local/etc/haproxy/haproxy.cfg" = {
          content = haproxyConfig;
        };
      };
      extraMounts = [
        {
          host = "{{STATE_DIR}}/ingress/lab.pem";
          container = "/etc/haproxy/certs/lab.pem";
        }
      ];
      networks = [ config.lab.name ];
    };
  };
}
