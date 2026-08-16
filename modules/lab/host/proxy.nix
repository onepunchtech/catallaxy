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
  cfg = config.lab.proxy;

  exposedServices = concatLists (
    mapAttrsToList (
      clusterName: clusterCfg:
      let
        floes = clusterCfg.floes or { };
        k3dClusterName = clusterCfg.provisioner.k3d.clusterName or clusterName;
        upstream = "k3d-${k3dClusterName}-server-0";
        passthroughPort = clusterCfg.floes.gateway.tls.passthrough.port or 8444;

        mkEntry = name: gw: domain: {
          inherit
            name
            domain
            upstream
            passthroughPort
            ;
          cluster = clusterName;
          mode = gw.mode or "terminate";
        };

        isRealDomain = d: d != "" && d != "idm.example.com";

        # `gw` is `{ }` for a floe with no gateway block at all, which is why
        # this cannot read gw.tier directly.
        publiclyExposed = gw: (gw.tier or "public") != "internal";

        entriesFor =
          name: domain: gw:
          if (gw.enable or false) && isRealDomain domain && publiclyExposed gw then
            [ (mkEntry name gw domain) ] ++ map (d: mkEntry name gw d) (gw.extraDomains or [ ])
          else
            [ ];

        floeEntries = concatLists (
          mapAttrsToList (
            name: floe:
            let
              gw = floe.gateway or { };
              domain = if (gw.domain or "") != "" then gw.domain else (floe.domain or "");
            in
            if (floe.enable or false) then entriesFor name domain gw else [ ]
          ) floes
        );

        customEntries = concatLists (
          mapAttrsToList (
            appName: app:
            if (app.enable or false) then
              entriesFor "custom-${appName}" (app.gateway.domain or "") (app.gateway or { })
            else
              [ ]
          ) (if (floes.custom.enable or false) then (floes.custom.apps or { }) else { })
        );
      in
      floeEntries ++ customEntries
    ) config.lab.out.allClusters
  );

  terminateServices = filter (s: s.mode == "terminate") exposedServices;
  passthroughServices = filter (s: s.mode == "passthrough") exposedServices;

  terminateClusters = unique (map (s: s.upstream) terminateServices);

  passthroughClusters = unique (map (s: s.upstream) passthroughServices);

  haproxyConfig =
    let

      passthroughAcls = concatStringsSep "\n" (
        map (
          svc: "    use_backend bk_pass_${svc.cluster} if { req.ssl_sni -i ${svc.domain} }"
        ) passthroughServices
      );

      terminateAcls = concatStringsSep "\n" (
        map (
          svc: "    use_backend bk_http_${svc.cluster} if { hdr(host) -i ${svc.domain} }"
        ) terminateServices
      );

      httpBackends = concatStringsSep "\n\n" (
        map (
          upstream:
          let
            cluster = (builtins.head (filter (s: s.upstream == upstream) terminateServices)).cluster;
            target = if cfg.tls.enable then "${upstream}:443 ssl verify none" else "${upstream}:80";
          in
          ''
            backend bk_http_${cluster}
                mode http
                server srv1 ${target} init-addr none resolvers docker resolve-prefer ipv4''
        ) terminateClusters
      );

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
          timeout client ${cfg.idleTimeout}
          timeout server ${cfg.idleTimeout}
          timeout tunnel ${cfg.idleTimeout}
          log global

      ${
        if cfg.tls.enable then
          ''
            frontend ft_ssl
                bind *:443
                mode tcp
                tcp-request inspect-delay 5s
                tcp-request content accept if { req_ssl_hello_type 1 }

            ${passthroughAcls}

                default_backend bk_local_https

            backend bk_local_https
                mode tcp
                server loopback 127.0.0.1:8443

            frontend ft_https
                bind 127.0.0.1:8443 ssl crt /etc/haproxy/certs/lab.pem
                mode http

            ${terminateAcls}

            frontend ft_http
                bind *:80
                mode http
                http-request redirect scheme https code 301
          ''
        else
          ''
            frontend ft_http
                bind *:80
                mode http

            ${terminateAcls}
          ''
      }

      ${httpBackends}

      ${passthroughBackends}
    '';
in
{
  options.lab.proxy = {
    enable = mkEnableOption "Lab ingress (HAProxy for domain-based routing to k3d clusters)";

    tls = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Terminate TLS at the lab ingress, using a certificate minted
          from the lab CA.

          Turning this off makes the ingress a plaintext Host-header
          router on `httpPort`. No certificate is generated and nothing
          has to trust a lab CA, which is what you want for an example
          that should come up on any machine without touching the
          system trust store. `cert-generate` and `host-trust-install`
          are both dropped from the plan.
        '';
      };
    };

    idleTimeout = mkOption {
      type = types.str;
      default = "1h";
      description = ''
        How long the ingress holds a connection carrying no traffic
        (`timeout client`, `timeout server` and `timeout tunnel`).

        Long-lived streams are idle by design. A netbird peer registers
        with signal and then waits for connection candidates that may be
        minutes away; gRPC control planes, WebSockets, SSE and
        `kubectl logs -f` all behave the same way. HAProxy's short
        defaults close those connections mid-stream, and because the
        close is orderly the client reports whatever it happened to be
        waiting for rather than a timeout; netbird's signal client said
        `didn't receive a registration header` once every 30s, forever,
        with the mesh never coming up (mesh.local, 2026-08-04).

        This bounds only inactivity, so lowering it does not bound
        request duration; it bounds how long a working idle stream is
        allowed to live.
      '';
    };

    httpPort = mkOption {
      type = types.port;
      default = 80;
      description = "Host port for HTTP";
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
      default = "catallaxy-${config.lab.name}-ingress";
      description = "Docker container name for the ingress";
    };

    out = {
      service = mkOption {
        type = types.attrs;
        readOnly = true;
        description = "Computed container service definition for the lab ingress";
      };

      hosts = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        description = ''
          Every hostname the lab ingress routes, terminated and passthrough
          alike.

          This is the same list the generated haproxy config is built from.
          Publishing it means a check can ask what is routed without parsing
          haproxy's syntax back out of the rendered file.
        '';
      };
    };
  };

  config.lab.proxy.out = mkIf cfg.enable {
    hosts = unique (map (svc: svc.domain) exposedServices);

    service = {
      description = "HAProxy lab ingress (${config.lab.dns.zone})";
      container = cfg.containerName;
      image = cfg.image;
      ports = [
        "${toString cfg.httpPort}:80"
      ]
      ++ lib.optional cfg.tls.enable "${toString cfg.httpsPort}:443";
      volumes = {
        "/usr/local/etc/haproxy/haproxy.cfg" = {
          content = haproxyConfig;
        };
      };
      extraMounts = lib.optional cfg.tls.enable {

        host = "{{STATE_DIR}}/proxy/lab.pem";
        container = "/etc/haproxy/certs/lab.pem";
      };
      networks = [ config.lab.name ];
    };
  };
}
