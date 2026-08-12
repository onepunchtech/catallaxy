{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  contracts,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
in
(mkFloe {
  name = "harbor";
  version = "1.19.1";
  imports = [ ./options.nix ];

  requires = [
    "gateway"
    "cert-manager"
  ];
  module =
    {
      config,
      lib,
      cataCharts,
      k8sHelpers,
      cfg,
      peers,
      contracts,
      ...
    }:
    let
      inherit (lib)
        optionalAttrs
        optional
        ;
      kappLib = import ../../../../../lib/util/kapp.nix { inherit lib; };

      chartRef = cfg.chart;

      hasCaBundle = cfg.tls.caBundle != null;

      httpRouteResource = optionalAttrs (cfg.gateway.enable && cfg.domain != "") {
        harbor-route = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            name = "harbor";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            parentRefs = [
              (
                {
                  name =
                    if cfg.gateway.tier == "internal" then
                      config.floes.gateway.exports.internalGatewayName
                    else
                      cfg.gateway.gatewayRef;

                  sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
                }
                // optionalAttrs (cfg.gateway.gatewayNamespace != null) {
                  namespace = cfg.gateway.gatewayNamespace;
                }
              )
            ];
            hostnames = [ cfg.domain ];
            rules = [
              {
                matches = [
                  {
                    path = {
                      type = "PathPrefix";
                      value = "/";
                    };
                  }
                ];
                backendRefs = [
                  {
                    name = "harbor-nginx";
                    port = 80;
                  }
                ];
              }
            ];
          };
        };
      };

      tlsCertResource = optionalAttrs (cfg.tls.issuerRef != null && cfg.domain != "") {
        harbor-tls = {
          apiVersion = "cert-manager.io/v1";
          kind = "Certificate";
          metadata = {
            name = cfg.tls.secretName;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            secretName = cfg.tls.secretName;
            issuerRef = {
              name = cfg.tls.issuerRef.name;
              kind = cfg.tls.issuerRef.kind;
            };
            dnsNames = [ cfg.domain ];
          };
        };
      };

      adminBootstrapResource = {
        harbor-admin-sa = {
          apiVersion = "v1";
          kind = "ServiceAccount";
          metadata = {
            name = "harbor-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
        };
        harbor-admin-role = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          metadata = {
            name = "harbor-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          rules = [
            {
              apiGroups = [ "" ];
              resources = [ "secrets" ];
              verbs = [
                "get"
                "create"
                "update"
                "patch"
              ];
            }
          ];
        };
        harbor-admin-rb = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          metadata = {
            name = "harbor-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "harbor-bootstrap";
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = "harbor-bootstrap";
              namespace = cfg.namespace;
            }
          ];
        };
        harbor-admin-bootstrap = {
          apiVersion = "batch/v1";
          kind = "Job";
          metadata = {
            name = "harbor-admin-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
            annotations."kapp.k14s.io/update-strategy" = "fallback-on-replace";
          };
          spec = {
            backoffLimit = 5;
            template = {
              metadata.labels.app = "harbor-admin-bootstrap";
              spec = {
                serviceAccountName = "harbor-bootstrap";
                restartPolicy = "OnFailure";
                containers = [
                  {
                    name = "bootstrap";
                    image = cfg.bootstrapImage;
                    command = [
                      "bash"
                      "-c"
                    ];
                    args = [
                      ''
                        set -eu
                        if kubectl -n ${cfg.namespace} get secret ${cfg.adminPasswordSecret} >/dev/null 2>&1; then
                          echo "Admin secret '${cfg.adminPasswordSecret}' already exists, leaving alone"
                        else
                          PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
                          kubectl -n ${cfg.namespace} create secret generic ${cfg.adminPasswordSecret} \
                            --from-literal=HARBOR_ADMIN_PASSWORD="$PASS"
                          echo "Created admin secret with random password"
                        fi

                        if kubectl -n ${cfg.namespace} get secret ${cfg.secretKeySecret} >/dev/null 2>&1; then
                          echo "Secret-key secret already exists"
                        else
                          KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
                          kubectl -n ${cfg.namespace} create secret generic ${cfg.secretKeySecret} \
                            --from-literal=secretKey="$KEY"
                          echo "Created harbor-secret-key with 16-char key"
                        fi
                      ''
                    ];
                  }
                ];
              };
            };
          };
        };
      };

      oidcClientSecretNs =
        if cfg.oidc.clientSecretRef != null then
          (
            if cfg.oidc.clientSecretRef.namespace != null then
              cfg.oidc.clientSecretRef.namespace
            else
              cfg.namespace
          )
        else
          null;

      oidcRbacResource =
        optionalAttrs
          (cfg.oidc.enable && cfg.oidc.clientSecretRef != null && oidcClientSecretNs != cfg.namespace)
          {
            harbor-oidc-secret-reader-role = {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "Role";
              metadata = {
                name = "harbor-oidc-secret-reader";
                namespace = oidcClientSecretNs;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              rules = [
                {
                  apiGroups = [ "" ];
                  resources = [ "secrets" ];
                  resourceNames = [ cfg.oidc.clientSecretRef.name ];
                  verbs = [
                    "get"
                    "list"
                    "watch"
                  ];
                }
              ];
            };
            harbor-oidc-secret-reader-rb = {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "RoleBinding";
              metadata = {
                name = "harbor-oidc-secret-reader";
                namespace = oidcClientSecretNs;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = "Role";
                name = "harbor-oidc-secret-reader";
              };
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = "harbor-bootstrap";
                  namespace = cfg.namespace;
                }
              ];
            };
          };

      oidcBootstrapResource = optionalAttrs cfg.oidc.enable {
        harbor-oidc-bootstrap = {
          apiVersion = "batch/v1";
          kind = "Job";
          metadata = {
            name = "harbor-oidc-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
            annotations."kapp.k14s.io/update-strategy" = "fallback-on-replace";
          };
          spec = {
            backoffLimit = 10;
            template = {
              metadata.labels.app = "harbor-oidc-bootstrap";
              spec = {
                serviceAccountName = "harbor-bootstrap";
                restartPolicy = "OnFailure";

                initContainers = lib.optional (cfg.oidc.clientSecretRef != null) (
                  k8sHelpers.wait.mkWaitInitContainer {
                    name = "wait-for-oauth2-secret";
                    probe = config.floes.kanidm.exports.oauth2Clients.${cfg.oidc.clientId}.readyProbe;
                  }
                );
                containers = [
                  {
                    name = "configure-oidc";
                    image = cfg.bootstrapImage;
                    env = [
                      {
                        name = "HARBOR_URL";
                        value = "http://harbor-core.${cfg.namespace}.svc.cluster.local";
                      }
                      {
                        name = "ADMIN_PASSWORD";
                        valueFrom.secretKeyRef = {
                          name = cfg.adminPasswordSecret;
                          key = "HARBOR_ADMIN_PASSWORD";
                        };
                      }
                    ];
                    command = [
                      "bash"
                      "-c"
                    ];
                    args = [
                      ''
                        set -eu
                        ${
                          if cfg.oidc.clientSecretRef != null then
                            ''
                              OIDC_CLIENT_SECRET=$(kubectl -n ${oidcClientSecretNs} get secret ${cfg.oidc.clientSecretRef.name} \
                                -o jsonpath='{.data.${cfg.oidc.clientSecretRef.key}}' | base64 -d)
                            ''
                          else
                            ''OIDC_CLIENT_SECRET=""''
                        }
                        while true; do
                          CODE=$(curl -sk -o /dev/null -w '%{http_code}' "$HARBOR_URL/api/v2.0/ping" 2>/dev/null || echo "000")
                          [ "$CODE" = "200" ] && break
                          echo "Waiting for Harbor API (HTTP $CODE)..."
                          sleep 5
                        done
                        echo "Harbor API reachable, applying OIDC configuration"
                        cat >/tmp/payload.json <<EOF
                        {
                          "auth_mode": "oidc_auth",
                          "oidc_name": ${builtins.toJSON cfg.oidc.providerName},
                          "oidc_endpoint": ${builtins.toJSON cfg.oidc.issuerUrl},
                          "oidc_client_id": ${builtins.toJSON cfg.oidc.clientId},
                          ${
                            if cfg.oidc.clientSecretRef != null then ''"oidc_client_secret": "$OIDC_CLIENT_SECRET",'' else ""
                          }
                          "oidc_scope": ${builtins.toJSON (lib.concatStringsSep "," cfg.oidc.scopes)},
                          "oidc_groups_claim": ${builtins.toJSON cfg.oidc.groupsClaim},
                          "oidc_admin_group": ${
                            builtins.toJSON (
                              if cfg.oidc.adminGroup != "" then cfg.oidc.adminGroup + cfg.oidc.groupSuffix else ""
                            )
                          },
                          "oidc_user_claim": ${builtins.toJSON cfg.oidc.userClaim},
                          "oidc_auto_onboard": ${if cfg.oidc.autoOnboard then "true" else "false"},
                          "oidc_verify_cert": ${if cfg.oidc.verifyCert then "true" else "false"}
                        }
                        EOF
                        HTTP=$(curl -sk -w '%{http_code}' -o /tmp/resp.txt \
                          -u "admin:$ADMIN_PASSWORD" \
                          -H 'Content-Type: application/json' \
                          -X PUT \
                          -d @/tmp/payload.json \
                          "$HARBOR_URL/api/v2.0/configurations")
                        if [ "$HTTP" != "200" ]; then
                          echo "Failed to apply OIDC config (HTTP $HTTP):"
                          cat /tmp/resp.txt
                          exit 1
                        fi
                        echo "OIDC configuration applied"
                      ''
                    ];
                    volumeMounts = optional hasCaBundle {
                      name = "lab-ca";
                      mountPath = "/etc/ssl/certs/lab-ca.crt";
                      subPath = cfg.tls.caBundle.key;
                      readOnly = true;
                    };
                  }
                ];
                volumes = optional hasCaBundle {
                  name = "lab-ca";
                  configMap.name = cfg.tls.caBundle.name;
                };
              };
            };
          };
        };
      };

      robotBootstrapResource = optionalAttrs (cfg.robots != { }) {
        harbor-robot-bootstrap = {
          apiVersion = "batch/v1";
          kind = "Job";
          metadata = {
            name = "harbor-robot-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
            annotations."kapp.k14s.io/update-strategy" = "fallback-on-replace";
          };
          spec = {
            backoffLimit = 10;
            template = {
              metadata.labels.app = "harbor-robot-bootstrap";
              spec = {
                serviceAccountName = "harbor-bootstrap";
                restartPolicy = "OnFailure";
                containers = [
                  {
                    name = "create-robots";
                    image = cfg.bootstrapImage;
                    env = [
                      {
                        name = "HARBOR_URL";
                        value = "http://harbor-core.${cfg.namespace}.svc.cluster.local";
                      }
                      {
                        name = "HARBOR_EXTERNAL_HOST";
                        value = cfg.domain;
                      }
                      {
                        name = "ADMIN_PASSWORD";
                        valueFrom.secretKeyRef = {
                          name = cfg.adminPasswordSecret;
                          key = "HARBOR_ADMIN_PASSWORD";
                        };
                      }
                    ];
                    command = [
                      "bash"
                      "-c"
                    ];
                    args = [
                      ''
                        set -eu
                        while true; do
                          CODE=$(curl -sk -o /dev/null -w '%{http_code}' "$HARBOR_URL/api/v2.0/ping" 2>/dev/null || echo "000")
                          [ "$CODE" = "200" ] && break
                          echo "Waiting for Harbor API (HTTP $CODE)..."
                          sleep 5
                        done

                        create_robot() {
                          local NAME="$1" SECRET="$2" PAYLOAD_FILE="$3"
                          if kubectl -n ${cfg.namespace} get secret "$SECRET" >/dev/null 2>&1; then
                            echo "Secret $SECRET already exists; skipping robot creation for $NAME"
                            return 0
                          fi
                          RESP=$(curl -sk -u "admin:$ADMIN_PASSWORD" \
                            -H 'Content-Type: application/json' \
                            -X POST -d @"$PAYLOAD_FILE" \
                            "$HARBOR_URL/api/v2.0/robots")
                          ROBOT_NAME=$(echo "$RESP" | jq -r '.name // empty')
                          ROBOT_SECRET=$(echo "$RESP" | jq -r '.secret // empty')
                          if [ -z "$ROBOT_NAME" ] || [ -z "$ROBOT_SECRET" ]; then
                            echo "Failed to create robot '$NAME': $RESP" >&2
                            return 1
                          fi
                          kubectl -n ${cfg.namespace} create secret docker-registry "$SECRET" \
                            --docker-server="$HARBOR_EXTERNAL_HOST" \
                            --docker-username="$ROBOT_NAME" \
                            --docker-password="$ROBOT_SECRET"
                          echo "Created robot '$ROBOT_NAME' → Secret $SECRET"
                        }

                        ${lib.concatStrings (
                          lib.mapAttrsToList (
                            name: robot:
                            let
                              payload = builtins.toJSON {
                                name = name;
                                duration = robot.duration;
                                description = robot.description;
                                disable = false;
                                level = robot.level;
                                permissions = robot.permissions;
                              };
                              payloadJson = builtins.toJSON payload;
                            in
                            ''
                              echo ${lib.escapeShellArg payload} > /tmp/${name}.json
                              create_robot ${lib.escapeShellArg name} ${lib.escapeShellArg robot.secretName} /tmp/${name}.json
                            ''
                          ) cfg.robots
                        )}
                        echo "All robot bootstraps complete"
                      ''
                    ];
                    volumeMounts = optional hasCaBundle {
                      name = "lab-ca";
                      mountPath = "/etc/ssl/certs/lab-ca.crt";
                      subPath = cfg.tls.caBundle.key;
                      readOnly = true;
                    };
                  }
                ];
                volumes = optional hasCaBundle {
                  name = "lab-ca";
                  configMap.name = cfg.tls.caBundle.name;
                };
              };
            };
          };
        };
      };

      projectBootstrapResource =
        let
          roleId = {
            projectAdmin = 1;
            developer = 2;
            guest = 3;
            maintainer = 4;
            limitedGuest = 5;
          };
          entityTypeId = {
            user = 1;
            group = 2;
          };

          boolStr = b: if b then "true" else "false";

          projectPayload =
            name: p:
            {
              project_name = name;
              metadata = {
                public = boolStr p.public;
                auto_scan = boolStr p.autoScan;
                prevent_vul = boolStr p.preventVuln;
                reuse_sys_cve_allowlist = boolStr p.reuseSysCveAllowlist;
              }
              // optionalAttrs (p.severity != null) {
                severity = p.severity;
              };
            }
            // optionalAttrs (p.storageQuota >= 0) {
              storage_limit = p.storageQuota;
            };

          registryName = projectName: "proxy-cache-${projectName}";

          registryPayload =
            projectName: pc:
            {
              name = registryName projectName;
              type = pc.registryType;
              url = pc.endpointUrl;
              insecure = false;
              description = "Proxy cache for ${projectName}";
            }
            // optionalAttrs (pc.credentialUsername != null) {
              credential = {
                type = "basic";
                access_key = pc.credentialUsername;
                access_secret = "<<PASSWORD>>";
              };
            };

          retentionPayload = p: {
            algorithm = "or";
            rules = p.retention.rules;
            trigger = {
              kind = "Schedule";
              references = { };
              settings.cron = p.retention.schedule;
            };
            scope = {
              level = "project";
              ref = 0;
            };
          };

          cveAllowlistPayload = p: {
            items = map (cve: { cve_id = cve; }) p.cveAllowlist;
            expires_at = null;
          };

          projectBlock =
            name: p:
            let
              createJson = builtins.toJSON (projectPayload name p);
              regJson = if p.proxyCache != null then builtins.toJSON (registryPayload name p.proxyCache) else "";
              retentionJson = if p.retention != null then builtins.toJSON (retentionPayload p) else "";
              cveJson = if p.cveAllowlist != [ ] then builtins.toJSON (cveAllowlistPayload p) else "";

              credSecretName =
                if (p.proxyCache != null && p.proxyCache.credentialPasswordRef != null) then
                  p.proxyCache.credentialPasswordRef.name
                else
                  "";
              credSecretKey =
                if (p.proxyCache != null && p.proxyCache.credentialPasswordRef != null) then
                  p.proxyCache.credentialPasswordRef.key
                else
                  "";

              memberBlocks = lib.concatStrings (
                lib.mapAttrsToList (
                  mname: m:
                  let

                    effectiveName = mname + lib.optionalString (m.entityType == "group") cfg.oidc.groupSuffix;
                  in
                  ''
                    ensure_member ${lib.escapeShellArg name} ${lib.escapeShellArg effectiveName} ${
                      toString entityTypeId.${m.entityType}
                    } ${toString roleId.${m.role}}
                  ''
                ) p.members
              );

              immutableBlocks = lib.concatStrings (
                lib.imap0 (i: rule: ''
                  echo ${lib.escapeShellArg (builtins.toJSON rule)} > /tmp/imm-${name}-${toString i}.json
                  apply_immutable_rule ${lib.escapeShellArg name} /tmp/imm-${name}-${toString i}.json
                '') p.immutableTagRules
              );
            in
            ''
              echo "==> Project: ${name}"
              echo ${lib.escapeShellArg createJson} > /tmp/proj-${name}.json

              REG_ID=""
            ''
            + lib.optionalString (p.proxyCache != null) ''
              echo ${lib.escapeShellArg regJson} > /tmp/reg-${name}.json
              PASSWORD=""
              if [ -n ${lib.escapeShellArg credSecretName} ]; then
                PASSWORD=$(kubectl -n ${cfg.namespace} get secret ${lib.escapeShellArg credSecretName} \
                  -o jsonpath="{.data.${credSecretKey}}" | base64 -d)
                jq --arg p "$PASSWORD" '.credential.access_secret=$p' /tmp/reg-${name}.json \
                  > /tmp/reg-${name}.json.t && mv /tmp/reg-${name}.json.t /tmp/reg-${name}.json
              fi
              REG_ID=$(ensure_registry ${lib.escapeShellArg (registryName name)} /tmp/reg-${name}.json)
              if [ -n "$REG_ID" ]; then
                jq --argjson r "$REG_ID" '.registry_id=$r' /tmp/proj-${name}.json \
                  > /tmp/proj-${name}.json.t && mv /tmp/proj-${name}.json.t /tmp/proj-${name}.json
              fi
            ''
            + ''
              PID=$(ensure_project ${lib.escapeShellArg name} /tmp/proj-${name}.json)
              if [ -z "$PID" ]; then
                echo "ERROR: failed to resolve project id for ${name}" >&2
                exit 1
              fi
            ''
            + lib.optionalString (p.storageQuota >= 0) ''
              set_storage_quota "$PID" ${toString p.storageQuota}
            ''
            + memberBlocks
            + lib.optionalString (p.retention != null) ''
              echo ${lib.escapeShellArg retentionJson} > /tmp/ret-${name}.json
              jq --argjson pid "$PID" '.scope.ref=$pid' /tmp/ret-${name}.json \
                > /tmp/ret-${name}.json.t && mv /tmp/ret-${name}.json.t /tmp/ret-${name}.json
              set_retention "$PID" /tmp/ret-${name}.json
            ''
            + immutableBlocks
            + lib.optionalString (p.cveAllowlist != [ ]) ''
              echo ${lib.escapeShellArg cveJson} > /tmp/cve-${name}.json
              set_cve_allowlist ${lib.escapeShellArg name} /tmp/cve-${name}.json
            '';
        in
        optionalAttrs (cfg.projects != { }) {
          harbor-project-bootstrap = {
            apiVersion = "batch/v1";
            kind = "Job";
            metadata = {
              name = "harbor-project-bootstrap";
              namespace = cfg.namespace;
              labels."app.kubernetes.io/managed-by" = "catallaxy";
              annotations."kapp.k14s.io/update-strategy" = "fallback-on-replace";
            };
            spec = {
              backoffLimit = 10;
              template = {
                metadata.labels.app = "harbor-project-bootstrap";
                spec = {
                  serviceAccountName = "harbor-bootstrap";
                  restartPolicy = "OnFailure";
                  containers = [
                    {
                      name = "create-projects";
                      image = cfg.bootstrapImage;
                      env = [
                        {
                          name = "HARBOR_URL";
                          value = "http://harbor-core.${cfg.namespace}.svc.cluster.local";
                        }
                        {
                          name = "ADMIN_PASSWORD";
                          valueFrom.secretKeyRef = {
                            name = cfg.adminPasswordSecret;
                            key = "HARBOR_ADMIN_PASSWORD";
                          };
                        }
                      ];
                      command = [
                        "bash"
                        "-c"
                      ];
                      args = [
                        ''
                          set -eu
                          while true; do
                            CODE=$(curl -sk -o /dev/null -w '%{http_code}' "$HARBOR_URL/api/v2.0/ping" 2>/dev/null || echo "000")
                            [ "$CODE" = "200" ] && break
                            echo "Waiting for Harbor API (HTTP $CODE)..."
                            sleep 5
                          done

                          api() {
                            local M="$1" P="$2" B="''${3:-}"
                            if [ -n "$B" ]; then
                              curl -sk -u "admin:$ADMIN_PASSWORD" \
                                -H 'Content-Type: application/json' \
                                -X "$M" -d @"$B" "$HARBOR_URL$P"
                            else
                              curl -sk -u "admin:$ADMIN_PASSWORD" \
                                -H 'Content-Type: application/json' \
                                -X "$M" "$HARBOR_URL$P"
                            fi
                          }

                          api_code() {
                            local M="$1" P="$2" B="''${3:-}"
                            if [ -n "$B" ]; then
                              curl -sk -u "admin:$ADMIN_PASSWORD" \
                                -H 'Content-Type: application/json' \
                                -o /dev/null -w '%{http_code}' \
                                -X "$M" -d @"$B" "$HARBOR_URL$P"
                            else
                              curl -sk -u "admin:$ADMIN_PASSWORD" \
                                -o /dev/null -w '%{http_code}' \
                                -X "$M" "$HARBOR_URL$P"
                            fi
                          }

                          ensure_registry() {
                            local NAME="$1" PAYLOAD="$2"
                            local ID
                            ID=$(api GET "/api/v2.0/registries?q=name=$NAME" | jq -r '.[0].id // empty')
                            if [ -z "$ID" ]; then
                              api POST "/api/v2.0/registries" "$PAYLOAD" >/dev/null
                              ID=$(api GET "/api/v2.0/registries?q=name=$NAME" | jq -r '.[0].id // empty')
                              echo "Created registry endpoint '$NAME' (id=$ID)" >&2
                            fi
                            printf "%s" "$ID"
                          }

                          ensure_project() {
                            local NAME="$1" PAYLOAD="$2"
                            local PID
                            PID=$(api GET "/api/v2.0/projects?name=$NAME" \
                              | jq -r --arg n "$NAME" '.[] | select(.name==$n) | .project_id' | head -1)
                            if [ -z "$PID" ]; then
                              api POST "/api/v2.0/projects" "$PAYLOAD" >/dev/null
                              PID=$(api GET "/api/v2.0/projects?name=$NAME" \
                                | jq -r --arg n "$NAME" '.[] | select(.name==$n) | .project_id' | head -1)
                              echo "Created project '$NAME' (id=$PID)" >&2
                            else
                              api PUT "/api/v2.0/projects/$PID" "$PAYLOAD" >/dev/null
                              echo "Updated project '$NAME' (id=$PID)" >&2
                            fi
                            printf "%s" "$PID"
                          }

                          set_storage_quota() {
                            local PID="$1" LIMIT="$2"
                            local QID
                            QID=$(api GET "/api/v2.0/quotas?reference=project&reference_id=$PID" \
                              | jq -r '.[0].id // empty')
                            if [ -z "$QID" ]; then
                              echo "No quota object for project $PID; skipping" >&2
                              return 0
                            fi
                            printf '{"hard":{"storage":%s}}' "$LIMIT" > /tmp/quota.json
                            api PUT "/api/v2.0/quotas/$QID" /tmp/quota.json >/dev/null
                            echo "Set quota for project $PID to $LIMIT bytes" >&2
                          }

                          ensure_member() {
                            local PNAME="$1" ENTITY="$2" ETYPE="$3" ROLE_ID="$4"
                            local EXIST MID CUR_ROLE
                            EXIST=$(api GET "/api/v2.0/projects/$PNAME/members?entityname=$ENTITY" \
                              | jq -r --arg n "$ENTITY" '.[]? | select(.entity_name==$n) | "\(.id):\(.role_id)"' | head -1)
                            if [ -z "$EXIST" ]; then
                              if [ "$ETYPE" = "2" ]; then
                                printf '{"role_id":%s,"member_group":{"group_name":"%s","group_type":2}}' \
                                  "$ROLE_ID" "$ENTITY" > /tmp/member.json
                              else
                                printf '{"role_id":%s,"member_user":{"username":"%s"}}' \
                                  "$ROLE_ID" "$ENTITY" > /tmp/member.json
                              fi
                              api POST "/api/v2.0/projects/$PNAME/members" /tmp/member.json >/dev/null
                              echo "Added member '$ENTITY' to project '$PNAME' (role=$ROLE_ID)" >&2
                            else
                              MID="''${EXIST%%:*}"
                              CUR_ROLE="''${EXIST##*:}"
                              if [ "$CUR_ROLE" != "$ROLE_ID" ]; then
                                printf '{"role_id":%s}' "$ROLE_ID" > /tmp/member.json
                                api PUT "/api/v2.0/projects/$PNAME/members/$MID" /tmp/member.json >/dev/null
                                echo "Updated member '$ENTITY' on '$PNAME' (role=$ROLE_ID)" >&2
                              fi
                            fi
                          }

                          set_retention() {
                            local PID="$1" PAYLOAD="$2"
                            local RID
                            RID=$(api GET "/api/v2.0/retentions?project=$PID" 2>/dev/null \
                              | jq -r '.id // empty' 2>/dev/null || true)
                            if [ -z "$RID" ]; then
                              api POST "/api/v2.0/retentions" "$PAYLOAD" >/dev/null
                              echo "Created retention policy for project $PID" >&2
                            else
                              api PUT "/api/v2.0/retentions/$RID" "$PAYLOAD" >/dev/null
                              echo "Updated retention policy $RID for project $PID" >&2
                            fi
                          }

                          apply_immutable_rule() {
                            local PNAME="$1" RULE_FILE="$2"
                            local CODE
                            CODE=$(api_code POST "/api/v2.0/projects/$PNAME/immutabletagrules" "$RULE_FILE")
                            if [ "$CODE" != "201" ] && [ "$CODE" != "409" ]; then
                              echo "Failed immutable rule for '$PNAME': HTTP $CODE" >&2
                              return 1
                            fi
                          }

                          set_cve_allowlist() {
                            local PNAME="$1" PAYLOAD="$2"
                            api PUT "/api/v2.0/projects/$PNAME/cve-allowlist" "$PAYLOAD" >/dev/null
                            echo "Set CVE allowlist for '$PNAME'" >&2
                          }

                          ${lib.concatStrings (lib.mapAttrsToList projectBlock cfg.projects)}
                          echo "All project bootstraps complete"
                        ''
                      ];
                      volumeMounts = optional hasCaBundle {
                        name = "lab-ca";
                        mountPath = "/etc/ssl/certs/lab-ca.crt";
                        subPath = cfg.tls.caBundle.key;
                        readOnly = true;
                      };
                    }
                  ];
                  volumes = optional hasCaBundle {
                    name = "lab-ca";
                    configMap.name = cfg.tls.caBundle.name;
                  };
                };
              };
            };
          };
        };

      harborValues = {
        expose = {
          type = "clusterIP";
          tls.enabled = false;
          clusterIP.name = "harbor-nginx";
        };
        externalURL = "https://${cfg.domain}";
        existingSecretAdminPassword = cfg.adminPasswordSecret;
        existingSecretAdminPasswordKey = "HARBOR_ADMIN_PASSWORD";
        existingSecretSecretKey = cfg.secretKeySecret;
      }

      // optionalAttrs (cfg.tls.caBundleSecret != null) {
        caBundleSecretName = cfg.tls.caBundleSecret.name;
      }
      // {
        persistence =
          let
            scAttrs = optionalAttrs (cfg.storage.storageClass != null) {
              storageClass = cfg.storage.storageClass;
            };
          in
          {
            enabled = true;
            persistentVolumeClaim = {
              registry = {
                size = cfg.storage.registry.size;
              }
              // scAttrs;
              jobservice.jobLog = {
                size = cfg.storage.jobLog.size;
              }
              // scAttrs;
              database = {
                size = cfg.storage.database.size;
              }
              // scAttrs;
              redis = {
                size = cfg.storage.redis.size;
              }
              // scAttrs;
              trivy = {
                size = cfg.storage.trivy.size;
              }
              // scAttrs;
            };
          };
        trivy.enabled = cfg.trivy.enable;
        internalTLS.enabled = false;
        database.type = "internal";
        redis.type = "internal";
        metrics.enabled = cfg.metrics.enable;
      };

    in
    {
      cluster.registryDomains = lib.optional (cfg.domain != "") cfg.domain;

      assertions = [
        {
          assertion = !cfg.oidc.enable || cfg.oidc.client != null;
          message = "harbor OIDC login is enabled but no identity provider publishes an OAuth2 client named \"${cfg.oidc.clientId}\".";
        }
      ]
      ++ lib.optional cfg.oidc.enable (
        contracts.oidc.scopeAssertion {
          consumer = "harbor";
          inherit (cfg.oidc) clientId scopes client;
        }
      );

      floes.gateway.internalHostnames =
        if cfg.gateway.enable && cfg.gateway.tier == "internal" && cfg.domain != "" then
          [ cfg.domain ]
        else
          [ ];

      bundles.harbor = {
        resources =
          httpRouteResource
          // tlsCertResource
          // adminBootstrapResource
          // oidcRbacResource
          // oidcBootstrapResource
          // robotBootstrapResource
          // projectBootstrapResource;

        helmCharts.harbor = {
          chart = chartRef;
          releaseName = "harbor";
          namespace = cfg.namespace;
          createNamespace = true;

          kustomize = {
            enable = true;
            patches = kappLib.mkPreserveRuntimePatches [
              {
                kind = "Secret";
                name = "harbor-registryctl";
              }
            ];
          };
          values = harborValues;
        };

        createNamespaces = [ cfg.namespace ];

        requires =
          refs.needs peers.cert-manager.issuance "webhookReady"
          ++ refs.needs peers.gateway.routing "publicReady"

          ++ optional (hasCaBundle && cfg.tls.caBundle.readyToken != null) cfg.tls.caBundle.readyToken;
        provides = [ "harbor/registry/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/harbor-core";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "10m";
        };
      };
    };
})
  __floeModuleArgs
