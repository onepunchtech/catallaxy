{
  lib,
  pkgs,
  lab ? { },
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;

  slug = lab.contextPrefix or "netbird";

  runDir = "/var/run/catallaxy/netbird/${slug}";
  stateDir = "/var/lib/catallaxy/netbird/${slug}";

  ifname =
    let
      readable = "nb-${slug}";
    in
    if builtins.stringLength readable <= 15 then
      readable
    else
      "nb-${builtins.substring 0 12 (builtins.hashString "sha256" slug)}";
in
{
  options.floes.netbird = {

    client = {
      package = mkOption {
        type = types.package;
        default = pkgs.netbird;
        defaultText = lib.literalExpression "pkgs.netbird";
        description = ''
          The netbird client this lab runs on the operator's machine.

          The lab supplies it rather than requiring a global install: the
          CLI has to match the daemon it talks to over a socket, and the
          daemon has to match the management server, so a host install
          pins every lab on the machine to one version. Overriding this
          is the supported way to stage a netbird upgrade:
          `floes.netbird.version` follows it and every server image tag
          follows that.

          A consumer flake supplies one from its own nixpkgs by threading
          it in as a closure argument, the way
          `templates/consumer/flake.nix` threads `myFloes` (module
          `imports` cannot depend on `config`):

            mkLab { modules = [ (import ./lab.nix { inherit (pkgs) netbird; }) ]; }
        '';
      };

      serviceName = mkOption {
        type = types.str;
        default = "catallaxy-${slug}";
        description = "netbird system service name (`--service`).";
      };

      statusTimeoutSeconds = mkOption {
        type = types.ints.positive;
        default = 30;
        description = ''
          How long to wait for the daemon to answer `netbird status`.

          Sent SIGTERM at this deadline and SIGKILL five seconds later:
          `netbird status` catches SIGTERM and does not exit while blocked
          in a gRPC call, so a plain `timeout` does not bound it
          (mesh.local, 2026-08-03).

          Unbounded, a wedged daemon hangs the join with no diagnosis. The
          failure looks like the browser login never completed, when
          the login had in fact succeeded and only the confirmation was
          stuck (mesh.local, 2026-08-03).
        '';
      };

      profileName = mkOption {
        type = types.str;
        default = "lab-${slug}";
        description = ''
          netbird profile this lab operates under.

          netbird 0.74 keeps profiles in a store shared by every client on
          the machine, and `netbird up` acts on whichever is ACTIVE. The
          per-lab `--config` path overrides only the default profile file,
          not which profile is selected, so without an explicit select a
          lab inherits whatever another lab left active and dials that
          lab's management server (mesh.local, 2026-08-01).
        '';
      };

      interfaceName = mkOption {
        type = types.str;
        default = ifname;
        defaultText = lib.literalExpression ''"nb-<lab.contextPrefix>", hashed when over 15 bytes'';
        description = ''
          WireGuard interface name (`--interface-name`). netbird's own
          default is `wt0`, which is the operator's personal daemon.
        '';
      };

      wireguardPort = mkOption {
        type = types.port;
        default = 51830;
        description = ''
          WireGuard listen port (`--wireguard-port`). netbird's default is
          51820, i.e. the operator's own daemon; two labs up at once need
          two distinct values here. See the allocation table in
          `examples/labs/README.md`.
        '';
      };

      callbackPorts = mkOption {
        type = types.nonEmptyListOf types.port;
        default = [
          53010
          53011
          53012
          53013
        ];
        description = ''
          Loopback ports the PKCE browser callback may land on, in
          preference order. `netbird up` takes the first one that is free
          and binds its HTTP server there.

          netbird's own default is 53000, i.e. the operator's personal
          daemon, which holds that port for the duration of any login it
          is attempting, the same reasoning as `wireguardPort`.

          More than one is not redundancy. netbird probes a port with a
          dial and binds it later, so a retry re-collides with the
          listener the previous attempt is still shutting down, and with
          a single candidate there is nothing to fall back to: every
          attempt fails to bind, the browser login succeeds, and the
          callback has nowhere to land (mesh.local, 2026-08-03).

          Every port here is registered with the IdP through
          `exports.oauthRedirectUrls`, so whichever one is chosen is one
          the IdP will accept.
        '';
      };

      joinGraceSeconds = mkOption {
        type = types.ints.positive;
        default = 300;
        description = ''
          How long to keep asking the daemon whether it joined after
          `netbird up` has given up.

          `up` waits about 50s for the engine to become ready, and a
          cold daemon does not make it: the signal client refuses to
          open a stream while its channel is still `CONNECTING`, then
          backs off and succeeds on the retry roughly 60s in. A lab that
          starts a fresh daemon every run pays that every run, so `up`
          reports failure for a join that completes seconds later.

          The daemon's own state is what says whether this lab is on the
          mesh; `up`'s exit code only says whether it was still watching
          at the time (mesh.local, 2026-08-04).
        '';
      };

      logLevel = mkOption {
        type = types.enum [
          "error"
          "warn"
          "info"
          "debug"
          "trace"
        ];
        default = "info";
        description = ''
          Log level the daemon runs at (`--log-level`).

          At `info` the daemon does not say which callback port a login
          flow bound, whether a browser callback arrived, or which flow a
          token was delivered to. A join that fails with
          `waiting for browser login failed: context deadline exceeded`
          cannot be told apart from one where the callback reached a
          different flow without raising this to `debug`.
        '';
      };

      daemonAddr = mkOption {
        type = types.str;
        default = "unix://${runDir}/sock";
        description = "CLI↔daemon socket (`--daemon-addr`).";
      };

      configFile = mkOption {
        type = types.str;
        default = "${stateDir}/profile.json";
        description = "Profile file (`--config`).";
      };

      logFile = mkOption {
        type = types.str;
        default = "${stateDir}/client.log";
        description = "Daemon log path (`--log-file`).";
      };

      pidFile = mkOption {
        type = types.str;
        default = "${runDir}/pid";
        description = "Where the detached daemon's pid is recorded.";
      };

      dnsResolverAddress = mkOption {
        type = types.str;
        default = "";
        description = ''
          `--dns-resolver-address`. Empty means let the daemon discover
          one, which is right on a systemd-resolved host: netbird
          registers `~<zone>` as a routing domain on its own link and
          nothing is shared. Set it (to distinct values per lab) on a
          host without systemd-resolved, where netbird instead rewrites
          `/etc/resolv.conf` and runs a stub resolver on a discovered
          address, a namespace two daemons contend for.
        '';
      };

      extraUpArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Extra arguments for `netbird up`. `--disable-firewall` belongs
          here if two labs' daemons turn out to fight over netbird's
          firewall chains.
        '';
      };
    };
  };
}
