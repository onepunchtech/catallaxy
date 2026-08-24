{ lib, ... }:
{
  options.floes.netbird.exports = {
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "netbird";
      description = "Kubernetes namespace the management plane runs in.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Public FQDN of the netbird management dashboard (echoes cfg.domain).";
    };
    signalDomain = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Public FQDN of the netbird signal service.";
    };
    host = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "In-cluster DNS name of the management Service.";
    };
    managementUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        External management URL (https). Agents outside the cluster
        (operator laptops joined to the mesh) point at this.
      '';
    };
    hostClient = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        This lab's host-side netbird, for a lab that wants to drive the
        mesh itself rather than take the `netbird-mesh-join` /
        `netbird-mesh-leave` steps the floe declares:

          cli      : wrapper carrying this lab's --service /
                     --daemon-addr / --config / --log-file, so an
                     invocation cannot reach the operator's own daemon
          joinBin  : the SSO login the join step runs
          leaveBin : the counterpart the leave step runs
          package  : the netbird derivation everything above is built
                     from, and the version all four server images follow

        Empty when the floe is disabled, so a consumer reading it in an
        option default gets `{ }` rather than an eval error.
      '';
    };
    managementInternalUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        In-cluster management URL (http). Agents running as Pods
        inside the same cluster should use this, which avoids a hairpin
        through the public gateway and the TLS-terminating LB.
      '';
    };
    signalHost = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "In-cluster DNS name of the signal Service.";
    };
    signalPort = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = ''
        In-cluster port for the signal Service: the primary listener,
        serving gRPC over HTTP with the WebSocket proxy, which is what
        a current agent dials.

        The Service also carries `grpc-compat` on 10000. That is
        netbird's legacy bare-gRPC listener, which signal runs only to
        keep agents that were already connected on the old default
        port from dropping. Dialing it for a new connection is not the
        supported path.
      '';
    };
    oauthRedirectUrls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Loopback callback URLs this lab's `netbird up` may listen on,
        derived from `client.callbackPorts`.

        The IdP client that netbird logs in through must register every
        one of them: netbird picks whichever port is free at login
        time, and an unregistered redirect URI is refused by the IdP.
        Read this rather than restating the literals; the port set is
        netbird's to choose.
      '';
    };
    clusterRouterSecret = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Name of the Secret holding the cluster-router SetupKey. The
        operator's `netbird-agent` in-cluster Pod reads this to join
        the mesh as a routing peer.
      '';
    };
    operatorSecret = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Name of the Secret holding the operator SetupKey, used to
        onboard human operator devices.
      '';
    };
    setupKeyDataKey = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Data key inside the SetupKey Secrets that holds the key value.";
    };
    apiTokenSecretName = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Name of the Secret holding the PAT used by the bootstrap Job
        to call netbird's management API for one-time provisioning.
      '';
    };
  };
}
