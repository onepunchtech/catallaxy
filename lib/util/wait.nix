{ lib }:

let
  inherit (lib)
    concatStringsSep
    optionalAttrs
    optionalString
    hasAttr
    ;

  defaultKubectlImage = "alpine/k8s:1.32.4";
  defaultCurlImage = "curlimages/curl:8.10.1";
  defaultNetworkImage = "busybox:1.36";

  caBundleVolumeName = "ca-bundle";

  parseDurationSeconds =
    s:
    let
      m = builtins.match "([0-9]+)(s|m|h)" s;
    in
    if m == null then
      throw "wait.nix: invalid duration '${s}' (expected e.g. '5m', '30s', '1h')"
    else
      let
        n = lib.toInt (builtins.elemAt m 0);
        unit = builtins.elemAt m 1;
      in
      if unit == "s" then
        n
      else if unit == "m" then
        n * 60
      else
        n * 3600;

  divCeil = a: b: (a + b - 1) / b;

  loopPreamble = ''
    set -eu
    log() { echo "[wait] $*"; }
    trap 'log "ERROR at line $LINENO"' ERR
  '';

  renderCondition =
    p:
    let
      timeout = p.timeout or "5m";
      image = p.image or defaultKubectlImage;
    in
    {
      inherit image;
      command = [
        "kubectl"
        "wait"
        "--for=condition=${p.condition}=True"
        p.resource
        "-n"
        p.namespace
        "--timeout=${timeout}"
      ];
      args = [ ];
    };

  renderJsonpath =
    p:
    let
      timeout = p.timeout or "10m";
      image = p.image or defaultKubectlImage;

      valueSuffix = if p ? value then "=${toString p.value}" else "";
    in
    {
      inherit image;
      command = [
        "sh"
        "-c"
      ];
      args = [
        ''
          ${loopPreamble}
          log "waiting for ${p.namespace}/${p.resource} to be created"
          kubectl wait --for=create ${p.resource} -n ${p.namespace} --timeout=${timeout}
          log "waiting for ${p.jsonpath}${valueSuffix} on ${p.namespace}/${p.resource}"
          kubectl wait --for=jsonpath='${p.jsonpath}'${valueSuffix} ${p.resource} -n ${p.namespace} --timeout=${timeout}
          log "done"
        ''
      ];
    };

  renderExists =
    p:
    let
      timeout = p.timeout or "5m";
      image = p.image or defaultKubectlImage;
    in
    {
      inherit image;
      command = [
        "kubectl"
        "wait"
        "--for=create"
        p.resource
        "-n"
        p.namespace
        "--timeout=${timeout}"
      ];
      args = [ ];
    };

  renderHttp =
    p:
    let
      timeout = p.timeout or "10m";
      interval = p.interval or "15s";
      expectedStatus = toString (p.expectedStatus or 200);
      totalSeconds = parseDurationSeconds timeout;
      intervalSeconds = parseDurationSeconds interval;
      attempts = divCeil totalSeconds intervalSeconds;
      image = p.image or defaultCurlImage;
      caBundleMount = p.caBundleMount or null;

      caFilename = if caBundleMount == null then null else caBundleMount.filename or caBundleMount.key;
      caFlag = optionalString (caBundleMount != null) "--cacert ${caBundleMount.mountPath}/${caFilename}";
      caVolumeMount = optionalAttrs (caBundleMount != null) {
        volumeMounts = [
          {
            name = caBundleVolumeName;
            mountPath = caBundleMount.mountPath;
            readOnly = true;
          }
        ];
      };
    in
    {
      inherit image;
      command = [
        "sh"
        "-c"
      ];
      args = [
        ''
          ${loopPreamble}
          for attempt in $(seq 1 ${toString attempts}); do
            CODE=$(curl -s -o /dev/null -w '%{http_code}' ${caFlag} '${p.url}' 2>/dev/null || echo 000)
            if [ "$CODE" = "${expectedStatus}" ]; then
              log "'${p.url}' returned $CODE after $attempt attempt(s)"
              exit 0
            fi
            log "waiting for '${p.url}' (attempt $attempt/${toString attempts}, got HTTP $CODE)..."
            sleep ${toString intervalSeconds}
          done
          log "'${p.url}' never returned ${expectedStatus} after ${timeout}"
          exit 1
        ''
      ];
    }
    // caVolumeMount;

  renderTcp =
    p:
    let
      timeout = p.timeout or "5m";
      interval = p.interval or "5s";
      totalSeconds = parseDurationSeconds timeout;
      intervalSeconds = parseDurationSeconds interval;
      attempts = divCeil totalSeconds intervalSeconds;
      image = p.image or defaultNetworkImage;
    in
    {
      inherit image;
      command = [
        "sh"
        "-c"
      ];
      args = [
        ''
          ${loopPreamble}
          for attempt in $(seq 1 ${toString attempts}); do
            if nc -z -w 3 '${p.host}' ${toString p.port}; then
              log "'${p.host}:${toString p.port}' reachable after $attempt attempt(s)"
              exit 0
            fi
            log "waiting for '${p.host}:${toString p.port}' (attempt $attempt/${toString attempts})..."
            sleep ${toString intervalSeconds}
          done
          log "'${p.host}:${toString p.port}' never accepted a connection after ${timeout}"
          exit 1
        ''
      ];
    };

  renderDns =
    p:
    let
      timeout = p.timeout or "5m";
      interval = p.interval or "5s";
      totalSeconds = parseDurationSeconds timeout;
      intervalSeconds = parseDurationSeconds interval;
      attempts = divCeil totalSeconds intervalSeconds;
      image = p.image or defaultNetworkImage;
    in
    {
      inherit image;
      command = [
        "sh"
        "-c"
      ];
      args = [
        ''
          ${loopPreamble}
          for attempt in $(seq 1 ${toString attempts}); do
            if nslookup '${p.hostname}' >/dev/null 2>&1; then
              log "'${p.hostname}' resolves after $attempt attempt(s)"
              exit 0
            fi
            log "waiting for '${p.hostname}' to resolve (attempt $attempt/${toString attempts})..."
            sleep ${toString intervalSeconds}
          done
          log "'${p.hostname}' never resolved after ${timeout}"
          exit 1
        ''
      ];
    };

  renderScript =
    p:
    let
      image = p.image or defaultKubectlImage;
    in
    {
      inherit image;
      command = [
        "sh"
        "-c"
      ];
      args = [ p.script ];
    };

  renderers = {
    condition = renderCondition;
    jsonpath = renderJsonpath;
    exists = renderExists;
    http = renderHttp;
    tcp = renderTcp;
    dns = renderDns;
    script = renderScript;
  };

  renderProbe =
    probe:
    if !(probe ? kind) then
      throw "wait.nix: probe missing 'kind' field (attrs: ${toString (builtins.attrNames probe)})"
    else if !(hasAttr probe.kind renderers) then
      throw "wait.nix: unknown probe kind '${probe.kind}' (valid: ${concatStringsSep ", " (builtins.attrNames renderers)})"
    else
      renderers.${probe.kind} probe;

in
{
  inherit renderProbe caBundleVolumeName;

  mkWaitInitContainer =
    {
      probe,
      name ? "wait",
    }:
    let
      rendered = renderProbe probe;
    in
    {
      inherit name;
      inherit (rendered) image command;
    }

    // optionalAttrs (rendered.args or [ ] != [ ]) { inherit (rendered) args; }
    // optionalAttrs (rendered ? volumeMounts) { inherit (rendered) volumeMounts; };

  mkWaitJob =
    {
      probe,
      namespace,
      name,
      serviceAccountName,
      labels ? { },
    }:
    let
      rendered = renderProbe probe;
      commonLabels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
      }
      // labels;
      podSpec = {
        inherit serviceAccountName;
        restartPolicy = "OnFailure";
        containers = [
          (
            {
              name = "wait";
              inherit (rendered) image command;
            }

            // optionalAttrs (rendered.args or [ ] != [ ]) { inherit (rendered) args; }
            // optionalAttrs (rendered ? volumeMounts) { inherit (rendered) volumeMounts; }
          )
        ];
      }
      // optionalAttrs (rendered ? volumes) { inherit (rendered) volumes; };
    in
    {
      ${name} = {
        apiVersion = "batch/v1";
        kind = "Job";
        metadata = {
          inherit name namespace;
          labels = commonLabels;
        };
        spec = {
          backoffLimit = 3;
          template = {
            metadata.labels = commonLabels;
            spec = podSpec;
          };
        };
      };
    };
}
