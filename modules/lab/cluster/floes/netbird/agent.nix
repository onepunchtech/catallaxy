{
  config,
  lib,
  pkgs,
  k8sHelpers,
  ...
}:
let
  cfg = config.floes.netbird;
  nb = import ./lib.nix { inherit lib cfg; };
  planTokens = import ../../../../../lib/plan-tokens.nix { inherit lib; };

  inherit (lib) mkIf optional optionalAttrs;
  inherit (nb)
    hasCaBundle
    waitTimeoutStr
    owner
    managedBy
    ;

  mkWaitForSecrets =
    secrets:
    map (
      s:
      k8sHelpers.wait.mkWaitInitContainer {
        name = "wait-for-${s.name}";
        probe = {
          kind = "jsonpath";
          resource = "secret/${s.secret}";
          namespace = cfg.namespace;
          jsonpath = "{.data.${s.key}}";
          timeout = waitTimeoutStr;
        };
      }
    ) secrets;
in
{
  config = lib.mkMerge [
    (mkIf cfg.agent.enable {
      floes.netbird.steps.netbird-agent-peer-cleanup = {
        kind = "run-script";
        direction = "teardown";
        description = "Deregister this cluster's Netbird agent peer";

        provides = [
          planTokens.lab.cleanup
          (planTokens.cluster config.cluster.name).cleanup

          "netbird/agent-deregistered"
        ];

        policy.onFailure = "continue";
        params.bin =
          let
            script = pkgs.writeShellApplication {
              name = "netbird-agent-peer-cleanup";
              runtimeInputs = with pkgs; [ kubectl ];
              text = ''
                set -eu
                CONTEXT="''${KUBECONTEXT:-${config.cluster.ref.kubeContext or ""}}"
                if [ -z "$CONTEXT" ]; then
                  echo "no kube context resolved; skipping agent deregistration" >&2
                  exit 0
                fi
                kubectl --context "$CONTEXT" -n ${cfg.agent.namespace} \
                  delete deployment netbird-agent --wait=true --timeout=60s 2>/dev/null || true
                echo "Netbird agent deregistered (context=$CONTEXT)"
              '';
            };
          in
          "${script}/bin/netbird-agent-peer-cleanup";
      };
    })

    (mkIf cfg.agent.enable {
      floes.netbird.bundles.netbird-agent = {
        inherit owner;
        createNamespaces = [ cfg.agent.namespace ];

        awaitRollout = true;

        # The agent cannot start without its setup key, so wait for the
        # Secret rather than for the rollout alone. On the management
        # cluster the operator mints it; on a peer cluster it is projected
        # from the lab's secret store. Either way the wave blocks until the
        # value is really there, and the init container below stays as
        # defence in depth against it disappearing later.
        readyProbe = {
          kind = "jsonpath";
          resource = "secret/${cfg.agent.setupKeyRef.name}";
          namespace = cfg.agent.namespace;
          jsonpath = "{.data.${cfg.agent.setupKeyRef.key}}";
          timeout = "5m";
        };

        requires = lib.optionals cfg.management.enable [

          "netbird/setup-keys/ready"

          "netbird/management/ready"
          "gateway/tls/ready"
        ];
        resources = {
          netbird-agent-sa = {
            apiVersion = "v1";
            kind = "ServiceAccount";
            metadata = {
              name = "netbird-agent";
              namespace = cfg.agent.namespace;
              labels = managedBy;
            };
          };

          netbird-agent-setup-key-reader-role = {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "Role";
            metadata = {
              name = "netbird-agent-setup-key-reader";
              namespace = cfg.agent.namespace;
              labels = managedBy;
            };
            rules = [
              {
                apiGroups = [ "" ];
                resources = [ "secrets" ];
                resourceNames = [ cfg.agent.setupKeyRef.name ];

                verbs = [
                  "get"
                  "list"
                  "watch"
                ];
              }
            ];
          };

          netbird-agent-setup-key-reader-rb = {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "RoleBinding";
            metadata = {
              name = "netbird-agent-setup-key-reader";
              namespace = cfg.agent.namespace;
              labels = managedBy;
            };
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "Role";
              name = "netbird-agent-setup-key-reader";
            };
            subjects = [
              {
                kind = "ServiceAccount";
                name = "netbird-agent";
                namespace = cfg.agent.namespace;
              }
            ];
          };

          netbird-agent-state = mkIf cfg.agent.persistence.enable {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            metadata = {
              name = "netbird-agent-state";
              namespace = cfg.agent.namespace;
              labels = managedBy;
            };
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = cfg.agent.persistence.size;
            }
            // optionalAttrs (cfg.agent.persistence.storageClass != null) {
              storageClassName = cfg.agent.persistence.storageClass;
            };
          };

          netbird-agent = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "netbird-agent";
              namespace = cfg.agent.namespace;
              labels = managedBy // {
                "app.kubernetes.io/name" = "netbird-agent";
                "app.kubernetes.io/component" = "vpn-peer";
              };
            };
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels."app.kubernetes.io/name" = "netbird-agent";
              template = {
                metadata.labels."app.kubernetes.io/name" = "netbird-agent";
                spec = {
                  serviceAccountName = "netbird-agent";
                  terminationGracePeriodSeconds = 30;
                  initContainers = [
                    {
                      name = "init-tun";
                      image = cfg.images.wait.ref;
                      command = [
                        "sh"
                        "-c"
                        ''
                          set -eu
                          if [ ! -c /dev/net/tun ]; then
                            mkdir -p /dev/net
                            mknod /dev/net/tun c 10 200 || true
                            chmod 0666 /dev/net/tun || true
                          fi
                        ''
                      ];
                      securityContext = {
                        privileged = true;
                        runAsUser = 0;
                      };
                      volumeMounts = [
                        {
                          name = "dev";
                          mountPath = "/dev";
                        }
                      ];
                    }
                  ]

                  ++ mkWaitForSecrets [
                    {
                      name = "setup-key";
                      secret = cfg.agent.setupKeyRef.name;
                      key = cfg.agent.setupKeyRef.key;
                    }
                  ];
                  containers = [
                    {
                      name = "netbird";
                      image = cfg.images.agent.ref;
                      imagePullPolicy = "IfNotPresent";
                      env = [
                        {
                          name = "NB_SETUP_KEY";
                          valueFrom.secretKeyRef = {
                            name = cfg.agent.setupKeyRef.name;
                            key = cfg.agent.setupKeyRef.key;
                          };
                        }
                        {
                          name = "NB_MANAGEMENT_URL";
                          value = cfg.agent.managementUrl;
                        }
                        {
                          name = "NB_LOG_LEVEL";
                          value = "info";
                        }
                      ]
                      ++ optional hasCaBundle {

                        name = "SSL_CERT_DIR";
                        value = "/etc/ssl/certs:/etc/netbird-ca";
                      }
                      ++ optional (cfg.agent.hostname != null) {
                        name = "NB_HOSTNAME";
                        value = cfg.agent.hostname;
                      }
                      ++ optional (cfg.agent.advertisedRoutes != [ ]) {
                        name = "NB_EXTRA_IFACE_FOUND_ROUTES";
                        value = lib.concatStringsSep "," cfg.agent.advertisedRoutes;
                      };
                      securityContext = {
                        capabilities.add = [
                          "NET_ADMIN"
                          "SYS_RESOURCE"
                          "SYS_ADMIN"
                        ];
                      };
                      lifecycle.preStop.exec.command = [
                        "sh"
                        "-c"
                        "netbird down --force || true; sleep 2"
                      ];
                      volumeMounts = [
                        {
                          name = "netbird-state";
                          mountPath = "/var/lib/netbird";
                        }
                        {
                          name = "dev-net-tun";
                          mountPath = "/dev/net/tun";
                        }
                      ]
                      ++ optional hasCaBundle {
                        name = "lab-ca-dir";
                        mountPath = "/etc/netbird-ca";
                        readOnly = true;
                      };
                      resources = cfg.agent.resources;
                    }
                  ];
                  volumes = [
                    (
                      if cfg.agent.persistence.enable then
                        {
                          name = "netbird-state";
                          persistentVolumeClaim.claimName = "netbird-agent-state";
                        }
                      else
                        {
                          name = "netbird-state";
                          emptyDir = { };
                        }
                    )
                    {
                      name = "dev";
                      hostPath.path = "/dev";
                    }
                    {
                      name = "dev-net-tun";
                      hostPath = {
                        path = "/dev/net/tun";
                        type = "CharDevice";
                      };
                    }
                  ]
                  ++ optional hasCaBundle {
                    name = "lab-ca-dir";
                    configMap = {
                      name = cfg.tls.caBundle.name;
                      items = [
                        {
                          key = cfg.tls.caBundle.key;
                          path = "lab-ca.crt";
                        }
                      ];
                    };
                  };
                };
              };
            };
          };
        };
      };
    })
  ];
}
