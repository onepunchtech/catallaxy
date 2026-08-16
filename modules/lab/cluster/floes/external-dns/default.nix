{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe;
  planTokens = import ../../../../../lib/plan-tokens.nix { inherit lib; };
in
(mkFloe {
  name = "external-dns";
  version = "1.15.0";
  imports = [ ./options.nix ];
  module =
    {
      config,
      lib,
      cfg,
      ...
    }:
    let
      inherit (lib)
        mkIf
        mkMerge
        optionalAttrs
        mapAttrsToList
        ;

      rfc2136Args =
        optionalAttrs (cfg.provider == "rfc2136") {
          "rfc2136-host" = cfg.rfc2136.host;
          "rfc2136-port" = toString cfg.rfc2136.port;
          "rfc2136-zone" = lib.removeSuffix "." cfg.rfc2136.zone;
          "rfc2136-tsig-keyname" = cfg.rfc2136.tsigKeyname;
          "rfc2136-tsig-secret" = cfg.rfc2136.tsigSecret;
          "rfc2136-tsig-secret-alg" = cfg.rfc2136.tsigSecretAlg;
        }
        // optionalAttrs (cfg.provider == "rfc2136" && cfg.rfc2136.tsigAxfr) {
          "rfc2136-tsig-axfr" = null;
        };

      defaultTargetArgs = optionalAttrs (cfg.defaultTargets != [ ]) {
        "default-targets" = lib.concatStringsSep "," cfg.defaultTargets;
      };

      excludeInternalArgs = optionalAttrs cfg.excludeInternalGateway {
        "gateway-label-filter" = "catallaxy.io/network-tier=public";
      };

      allExtraArgs = rfc2136Args // defaultTargetArgs // excludeInternalArgs // cfg.extraArgs;

      formatExtraArgs = args: mapAttrsToList (k: v: if v == null then "--${k}" else "--${k}=${v}") args;

      intervalSeconds =
        let
          parts = builtins.match "([0-9]+)(s|m|h)" cfg.interval;
          scale = {
            s = 1;
            m = 60;
            h = 3600;
          };
        in
        if parts == null then
          60
        else
          lib.toInt (builtins.elemAt parts 0) * scale.${builtins.elemAt parts 1};

      reconcileDeadline = lib.min 180 (2 * intervalSeconds + 30);
    in
    mkMerge [
      {
        floes.external-dns.network = {
          declared = true;

          egress.internet.ports = [ 443 ];
        };

        floes.external-dns.imagesComplete = true;

        floes.external-dns.images.controller = {
          registry = "registry.k8s.io";
          repository = "external-dns/external-dns";
          tag = "v0.16.1";
        };

        bundles.external-dns = {

          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };
          includeInBootstrap = false;
          helmCharts.external-dns = {
            chart = cfg.chart;
            releaseName = "external-dns";
            namespace = cfg.namespace;
            createNamespace = true;
            values = {
              provider.name = cfg.provider;
              sources = cfg.sources;
              policy = cfg.policy;
              logLevel = cfg.logLevel;
              interval = cfg.interval;
              triggerLoopOnEvent = cfg.triggerLoopOnEvent;
              txtOwnerId = if cfg.txtOwnerId != null then cfg.txtOwnerId else config.cluster.name;
              txtPrefix = cfg.txtPrefix;
            }
            // optionalAttrs (cfg.domainFilters != [ ]) {
              domainFilters = cfg.domainFilters;
            }
            // optionalAttrs (cfg.excludeDomains != [ ]) {
              excludeDomains = cfg.excludeDomains;
            }
            // optionalAttrs (allExtraArgs != { }) {
              extraArgs = formatExtraArgs allExtraArgs;
            }
            // optionalAttrs (cfg.env != [ ]) {
              env = cfg.env;
            }
            // optionalAttrs (cfg.serviceAccount.annotations != { }) {
              serviceAccount.annotations = cfg.serviceAccount.annotations;
            };
          };
          createNamespaces = [ cfg.namespace ];

          provides = [ "external-dns/reconciler/ready" ];
          readyProbe = {
            kind = "condition";
            resource = "deployment/external-dns";
            namespace = cfg.namespace;
            condition = "Available";
            timeout = "3m";
          };
        };
      }

      (mkIf (cfg.policy == "sync" && (config.cluster.provider or null) != "docker") {
        steps.external-dns-purge-records = {
          kind = "run-script";
          direction = "teardown";
          description = "Delete external-dns-watched resources cluster-wide and wait for records to drain";
          provides = [ planTokens.lab.cleanup ];
          after = [ (planTokens.wants (planTokens.cluster config.cluster.name).cleanup) ];
          policy.onFailure = "continue";
          params.bin =
            let
              script = pkgs.writeShellApplication {
                name = "external-dns-purge-records";
                runtimeInputs = with pkgs; [
                  kubectl
                  coreutils
                  gawk
                ];
                text = ''
                  set -eu
                  CONTEXT="''${KUBECONTEXT:-${config.cluster.ref.kubeContext or ""}}"
                  if [ -z "$CONTEXT" ]; then
                    echo "no kube context resolved; skipping external-dns purge" >&2
                    exit 0
                  fi

                  if ! kubectl --context "$CONTEXT" get --raw=/healthz >/dev/null 2>&1; then
                    echo "cluster $CONTEXT unreachable; skipping external-dns purge"
                    exit 0
                  fi

                  echo "purging external-dns-watched resources on $CONTEXT"

                  for crd in httproutes.gateway.networking.k8s.io tlsroutes.gateway.networking.k8s.io; do
                    if kubectl --context "$CONTEXT" get crd "$crd" -o name >/dev/null 2>&1; then
                      kubectl --context "$CONTEXT" delete "$crd" -A --all \
                        --ignore-not-found=true --wait=false 2>/dev/null || true
                    fi
                  done

                  kubectl --context "$CONTEXT" delete ingress -A --all \
                    --ignore-not-found=true --wait=false 2>/dev/null || true

                  kubectl --context "$CONTEXT" get svc -A \
                    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
                    2>/dev/null | while IFS=/ read -r ns name; do
                      [ -n "$ns" ] || continue
                      case "$ns" in
                        kube-system|kube-public|kube-node-lease) continue ;;
                      esac
                      kubectl --context "$CONTEXT" -n "$ns" delete svc "$name" \
                        --ignore-not-found=true --wait=false 2>/dev/null || true
                    done

                  metrics() {
                    kubectl --context "$CONTEXT" get --raw \
                      "/api/v1/namespaces/${cfg.namespace}/services/external-dns:7979/proxy/metrics" \
                      2>/dev/null
                  }

                  metric() {
                    printf '%s\n' "$1" | awk -v key="$2" '$1 == key { print $2; exit }'
                  }

                  snapshot=$(metrics || true)
                  if [ -z "$snapshot" ]; then
                    echo "external-dns metrics unreachable; falling back to a fixed 60s wait" >&2
                    sleep 60
                    echo "external-dns purge hook done"
                    exit 0
                  fi

                  deadline=$((SECONDS + ${toString reconcileDeadline}))
                  misses=0
                  syncBefore=""

                  while [ "$SECONDS" -lt "$deadline" ]; do
                    if [ -z "$snapshot" ]; then
                      misses=$((misses + 1))
                      if [ "$misses" -ge 3 ]; then
                        echo "external-dns metrics stopped responding; not waiting further" >&2
                        break
                      fi
                    elif [ -z "$syncBefore" ]; then
                      if printf '%s\n' "$snapshot" | awk '
                        $1 == "external_dns_source_endpoints_total" && $2 == 0 { seen = 1 }
                        END { exit seen ? 0 : 1 }
                      '; then
                        syncBefore=$(metric "$snapshot" external_dns_controller_last_sync_timestamp_seconds)
                      fi
                      misses=0
                    else
                      syncNow=$(metric "$snapshot" external_dns_controller_last_sync_timestamp_seconds)
                      if [ -n "$syncNow" ] && [ "$syncNow" != "$syncBefore" ]; then
                        echo "external-dns reconcile observed after ''${SECONDS}s"
                        echo "external-dns purge hook done"
                        exit 0
                      fi
                      misses=0
                    fi

                    sleep 3
                    snapshot=$(metrics || true)
                  done

                  echo "external-dns did not confirm a reconcile within ${toString reconcileDeadline}s; continuing" >&2
                  echo "external-dns purge hook done"
                '';
              };
            in
            "${script}/bin/external-dns-purge-records";
        };
      })
    ];
})
  __floeModuleArgs
