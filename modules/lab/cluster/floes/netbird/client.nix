{
  lib,
  pkgs,
  client,
}:

let
  socketPath = lib.removePrefix "unix://" client.daemonAddr;
  runDir = builtins.dirOf client.pidFile;
  stateDir = builtins.dirOf client.configFile;

  socketTimeoutSeconds = 30;

  unitName = client.serviceName;

  runtimeSubdir =
    if lib.hasPrefix "/run/" runDir then
      lib.removePrefix "/run/" runDir
    else if lib.hasPrefix "/var/run/" runDir then
      lib.removePrefix "/var/run/" runDir
    else
      null;

  useSystemd = pkgs.stdenv.isLinux && runtimeSubdir != null;

  mkDaemonArgs = logTarget: [
    "service"
    "run"
    "--service ${client.serviceName}"
    "--daemon-addr ${client.daemonAddr}"
    "--config ${client.configFile}"
    "--log-file ${logTarget}"
    "--log-level ${client.logLevel}"
  ];

  supervisedArgLine = lib.concatStringsSep " " (mkDaemonArgs "console");
  unsupervisedArgLine = lib.concatStringsSep " " (mkDaemonArgs client.logFile);

  tracesTransport = client.logLevel == "debug" || client.logLevel == "trace";

  grpcTransportEnv = lib.optionals tracesTransport [
    "GRPC_GO_LOG_SEVERITY_LEVEL=info"
    "GRPC_GO_LOG_VERBOSITY_LEVEL=99"
  ];

  globalFlags = [
    "--service ${client.serviceName}"
    "--daemon-addr ${client.daemonAddr}"
    "--config ${client.configFile}"
    "--log-file ${client.logFile}"
  ];
  flagLine = lib.concatStringsSep " \\\n    " globalFlags;
in
{
  cli = pkgs.writeShellApplication {
    name = client.serviceName;
    runtimeInputs = [ client.package ];
    text = ''
      exec netbird \
        ${flagLine} \
        "$@"
    '';
  };

  daemon = pkgs.writeShellApplication {
    name = "${client.serviceName}-daemon";
    runtimeInputs = [
      client.package
      pkgs.coreutils
      pkgs.procps
    ]
    ++ lib.optional pkgs.stdenv.isLinux pkgs.systemd
    ++ lib.optional pkgs.stdenv.isLinux pkgs.util-linux;
    text =
      let
        awaitSocket = ''
          await_socket() {
            for _ in $(seq 1 ${toString socketTimeoutSeconds}); do
              [ -S "${socketPath}" ] && return 0
              sleep 1
            done
            return 1
          }
        '';

        sweepLegacy = ''
          sweep_unsupervised() {
            pids=$(pgrep -f "netbird service run --service ${client.serviceName}" 2>/dev/null || true)
            if [ -n "$pids" ]; then
              echo ">>> Clearing unsupervised netbird daemon(s) from an earlier run" >&2
              # shellcheck disable=SC2086
              sudo kill $pids 2>/dev/null || true
              sleep 2
              pids=$(pgrep -f "netbird service run --service ${client.serviceName}" 2>/dev/null || true)
              # shellcheck disable=SC2086
              [ -n "$pids" ] && sudo kill -9 $pids 2>/dev/null || true
            fi
            sudo rm -f ${client.pidFile} 2>/dev/null || true
          }
        '';
      in
      if useSystemd then
        ''
          ${awaitSocket}
          ${sweepLegacy}

          if systemctl is-active --quiet ${unitName}.service; then
            if await_socket; then
              exit 0
            fi
            echo ">>> ${unitName} is active but never opened its socket; restarting" >&2
            sudo systemctl stop ${unitName}.service 2>/dev/null || true
          fi

          sweep_unsupervised
          sudo systemctl reset-failed ${unitName}.service 2>/dev/null || true

          echo ">>> Starting this lab's netbird daemon (sudo required, once per boot)"
          setenv=(${lib.concatMapStringsSep " " (e: "--setenv=${e}") grpcTransportEnv})
          if [ -n "''${SSL_CERT_FILE:-}" ] && [ -r "''${SSL_CERT_FILE}" ]; then
            setenv+=(--setenv=SSL_CERT_FILE="''${SSL_CERT_FILE}")
          fi

          sudo systemd-run \
            --unit=${unitName} \
            --collect \
            --description="netbird client for lab ${client.serviceName}" \
            --property=RuntimeDirectory=${runtimeSubdir} \
            --property=RuntimeDirectoryMode=0755 \
            --property=RuntimeDirectoryPreserve=yes \
            --property=KillMode=control-group \
            --property=Restart=no \
            "''${setenv[@]}" \
            ${client.package}/bin/netbird ${supervisedArgLine} >/dev/null

          if await_socket; then
            exit 0
          fi

          sudo systemctl stop ${unitName}.service 2>/dev/null || true
          echo "netbird daemon socket ${socketPath} did not appear within ${toString socketTimeoutSeconds}s." >&2
          echo "Logs: journalctl -u ${unitName}.service" >&2
          exit 1
        ''
      else
        ''
          ${awaitSocket}
          ${sweepLegacy}

          if [ -S "${socketPath}" ] && pgrep -f "netbird service run --service ${client.serviceName}" >/dev/null 2>&1; then
            exit 0
          fi

          sweep_unsupervised

          echo ">>> Starting this lab's netbird daemon (sudo required, once per boot)"
          sudo install -d -m 0755 ${runDir}
          sudo install -d -m 0700 ${stateDir}
          setenv=(${
            lib.optionalString (grpcTransportEnv != [ ]) (
              "env " + lib.concatMapStringsSep " " (e: "\"${e}\"") grpcTransportEnv
            )
          })
          if [ -n "''${SSL_CERT_FILE:-}" ] && [ -r "''${SSL_CERT_FILE}" ]; then
            [ ''${#setenv[@]} -eq 0 ] && setenv=(env)
            setenv+=("SSL_CERT_FILE=''${SSL_CERT_FILE}")
          fi

          sudo "''${setenv[@]}" sh -c \
            'nohup ${client.package}/bin/netbird ${unsupervisedArgLine} >/dev/null 2>&1 & echo $! > ${client.pidFile}'

          if await_socket; then
            exit 0
          fi

          sweep_unsupervised
          echo "netbird daemon socket ${socketPath} did not appear within ${toString socketTimeoutSeconds}s." >&2
          echo "Log: ${client.logFile}" >&2
          exit 1
        '';
  };

  stop = pkgs.writeShellApplication {
    name = "${client.serviceName}-stop";
    runtimeInputs = [
      client.package
      pkgs.coreutils
      pkgs.procps
    ]
    ++ lib.optional pkgs.stdenv.isLinux pkgs.systemd
    ++ lib.optional pkgs.stdenv.isLinux pkgs.iproute2;
    text = ''
      ${lib.optionalString useSystemd ''
        if systemctl list-units --all --plain --no-legend ${unitName}.service 2>/dev/null | grep -q .; then
          echo ">>> Stopping this lab's netbird daemon (sudo required)"
          sudo systemctl stop ${unitName}.service 2>/dev/null || true
          sudo systemctl reset-failed ${unitName}.service 2>/dev/null || true
        fi
      ''}

      pids=$(pgrep -f "netbird service run --service ${client.serviceName}" 2>/dev/null || true)
      if [ -n "$pids" ]; then
        echo ">>> Clearing remaining netbird daemon(s) (sudo required)"
        # shellcheck disable=SC2086
        sudo kill $pids 2>/dev/null || true
        for _ in $(seq 1 15); do
          pgrep -f "netbird service run --service ${client.serviceName}" >/dev/null 2>&1 || break
          sleep 1
        done
        pids=$(pgrep -f "netbird service run --service ${client.serviceName}" 2>/dev/null || true)
        # shellcheck disable=SC2086
        [ -n "$pids" ] && sudo kill -9 $pids 2>/dev/null || true
      fi

      if [ "$(uname)" = "Linux" ] && ip link show ${client.interfaceName} >/dev/null 2>&1; then
        sudo ip link delete ${client.interfaceName} 2>/dev/null || true
      fi
      sudo rm -f ${client.pidFile} 2>/dev/null || true
      sudo rm -rf ${stateDir} 2>/dev/null || true
    '';
  };
}
