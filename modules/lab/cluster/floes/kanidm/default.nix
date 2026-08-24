{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  contracts,
  lab,
  ...
}:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions refs;
  cfg = config.floes.kanidm;
in
{
  imports = [
    (floeOptions {
      name = "kanidm";
    })
    ./options.nix
    ./heal.nix
  ];

  options.floes.kanidm.exports = {
    identity = lib.mkOption {
      type = refs.mkCapability {
        instanceReady = refs.tokenOption ''
          "The kanidm instance is serving." Consumers that only need
          the OIDC endpoint to answer gate on this.
        '';
        provisioningReady = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            "Declared OAuth2 clients exist and their Secrets are
            minted." Null when nothing declares clients: a running
            kanidm is not the same as a provisioned one, and a
            consumer mounting a client Secret needs the difference.
          '';
        };
      };
      default = null;
      description = ''
        Identity provision, or null when this floe is off. Consumers
        assert on this rather than on `floes.kanidm.enable`.
      '';
    };
    host = lib.mkOption {
      type = lib.types.str;
      default = "kanidm.kanidm.svc.cluster.local";
      description = "In-cluster DNS name of the kanidm Service.";
    };
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "kanidm";
      description = "Namespace kanidm runs in.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = "Port the Service listens on.";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://kanidm.kanidm.svc.cluster.local:8443";
      description = "In-cluster URL, for peers that reach kanidm without leaving the cluster.";
    };
    externalUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Public HTTPS URL, or empty when no domain is set.";
    };

    externalHost = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Public hostname on its own, for a consumer that needs host and port apart.";
    };
    externalPort = lib.mkOption {
      type = lib.types.port;
      default = 443;
      description = "Public port.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Public domain, or empty when kanidm is internal only.";
    };
    instanceName = lib.mkOption {
      type = lib.types.str;
      default = "kanidm";
      description = "Name of the Kanidm custom resource, so a peer can address what the operator created.";
    };
    oidcIssuer = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "OIDC issuer URL a relying party should trust.";
    };
    oidcDiscovery = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "OIDC discovery document URL.";
    };
    authorizationEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Browser authorization endpoint, on the public origin.

        A user-agent flow must send the human to an address their
        browser can reach, so unlike the token and JWKS endpoints this
        one is deliberately public.
      '';
    };
    tokenEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Token endpoint on the public origin, for a flow whose
        redirect already went through a browser.
      '';
    };
    internalTokenEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        OAuth2 token endpoint on kanidm's in-cluster address.

        The discovery document is built from `origin`, which is the
        public URL a browser uses. A Pod that follows it reaches the
        gateway's public listener, which on an internal-tier lab is not
        served at all. Machine-to-machine callers take this instead of
        parsing discovery.
      '';
    };

    oauth2Clients = lib.mkOption {
      default = { };
      type = contracts.oidc.clientsType;
      description = ''
        Per-client OIDC records this identity provider publishes.

        Consumers take one of these as their own `oidc.client`
        option rather than reading this attrset by name, which is
        what makes the provider swappable.
      '';
    };

    oidcDiscoveryReadyProbe = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Probe a consumer can reuse to wait for discovery to answer, rather than restating the URL.";
    };

    adminPasswordsReadyProbe = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Probe a consumer can reuse to wait for the admin credentials to exist.";
    };
    caSecretRef = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Reference to the CA bundle a client needs to trust kanidm's certificate.";
    };

    serviceAccounts = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Name of the service account.";
            };
            namespace = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Namespace it belongs to.";
            };

            apiTokenSecrets = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    secretName = lib.mkOption {
                      type = lib.types.str;
                      default = "";
                      description = "Secret the token was written to.";
                    };
                    namespace = lib.mkOption {
                      type = lib.types.str;
                      default = "";
                      description = "Namespace that Secret is in.";
                    };
                    purpose = lib.mkOption {
                      type = lib.types.str;
                      default = "readonly";
                      description = "What the token may do.";
                    };
                  };
                }
              );
              description = "API tokens kanidm minted, keyed by the account they belong to.";
            };
            credentialsSecret = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Secret holding the admin credentials, or null when none was minted.";
            };
          };
        }
      );
      description = "Service accounts kanidm provisioned, so a peer can find one without guessing its name.";
    };

    groups = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Bare group name, as declared.";
            };
            spn = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                Security principal name, `<name>@<domain>`: the value
                kanidm emits in a `groups` claim.
              '';
            };
          };
        }
      );
      description = "Groups kanidm provisioned, so a peer can reference one without restating its name.";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      inherit (lib)
        mkIf
        mapAttrs
        mapAttrsToList
        optionalAttrs
        optional
        ;
      kaniopEnabled = config.floes.kaniop.exports.operator != null;

      chartRef = cfg.chart;

      listenerName =
        if cfg.gateway.mode == "passthrough" then
          "tls-passthrough"
        else
          config.floes.gateway.exports.terminatingListenerName or "https";

      gatewayParentRef = k8sHelpers.mkGatewayParentFor {
        inherit (cfg) gateway;
        inherit (config.floes.gateway.exports) internalGatewayName;
        sectionName = listenerName;
      };

      internalTierEnabled =
        cfg.gateway.enable
        && cfg.gateway.tier == "public"
        && (config.cluster.capabilities.resolved.api-gateway.internalEnabled or false);

      # Same Gateway namespace and listener, but pinned to the internal
      # Gateway rather than chosen by tier: this is the second route a public
      # kanidm also publishes inside the lab.
      internalGatewayParentRef = k8sHelpers.mkGatewayParentFor {
        inherit (cfg) gateway;
        inherit (config.floes.gateway.exports) internalGatewayName;
        name = config.floes.gateway.exports.internalGatewayName;
        sectionName = listenerName;
      };

      domainConfigured = cfg.domain != "" && cfg.domain != "idm.example.com";

      internalRouteResource = optionalAttrs (internalTierEnabled && domainConfigured) {
        kanidm-internal-route =
          if cfg.gateway.mode == "passthrough" then
            {
              apiVersion = "gateway.networking.k8s.io/v1alpha2";
              kind = "TLSRoute";
              metadata = {
                name = "kanidm-internal";
                namespace = cfg.namespace;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              spec = {
                parentRefs = [ internalGatewayParentRef ];
                hostnames = [ cfg.domain ];
                rules = [
                  {
                    backendRefs = [
                      {
                        name = cfg.instanceName;
                        port = 8443;
                      }
                    ];
                  }
                ];
              };
            }
          else
            {
              apiVersion = "gateway.networking.k8s.io/v1";
              kind = "HTTPRoute";
              metadata = {
                name = "kanidm-internal";
                namespace = cfg.namespace;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              spec = {
                parentRefs = [ internalGatewayParentRef ];
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
                        name = cfg.instanceName;
                        port = 8443;
                      }
                    ];
                  }
                ];
              };
            };
      };

      routeResource = optionalAttrs (cfg.gateway.enable && domainConfigured) {
        kanidm-route =
          if cfg.gateway.mode == "passthrough" then
            {
              apiVersion = "gateway.networking.k8s.io/v1alpha2";
              kind = "TLSRoute";
              metadata = {
                name = "kanidm";
                namespace = cfg.namespace;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              spec = {
                parentRefs = [ gatewayParentRef ];
                hostnames = [ cfg.domain ];
                rules = [
                  {
                    backendRefs = [
                      {
                        name = cfg.instanceName;
                        port = 8443;
                      }
                    ];
                  }
                ];
              };
            }
          else
            {
              apiVersion = "gateway.networking.k8s.io/v1";
              kind = "HTTPRoute";
              metadata = {
                name = "kanidm";
                namespace = cfg.namespace;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              spec = {
                parentRefs = [ gatewayParentRef ];
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
                        name = cfg.instanceName;
                        port = 8443;
                      }
                    ];
                  }
                ];
              };
            };
      };

      backendTlsPolicy = optionalAttrs (cfg.gateway.enable && cfg.gateway.mode == "terminate") {
        kanidm-backend-tls = {
          apiVersion = "gateway.networking.k8s.io/v1alpha3";
          kind = "BackendTLSPolicy";
          metadata = {
            name = "kanidm-backend-tls";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            targetRefs = [
              {
                group = "";
                kind = "Service";
                name = cfg.instanceName;
              }
            ];
            validation = {
              hostname = cfg.domain;
            }
            // (
              if hasTrustBundle then
                {
                  caCertificateRefs = [
                    {
                      group = "";
                      kind = "ConfigMap";
                      name = caBundle.name;
                    }
                  ];
                }
              else
                {
                  wellKnownCACertificates = "System";
                }
            );
          };
        };
      };

      caBundle = config.floes.cert-manager.exports.caBundle;
      hasTrustBundle = caBundle != null;

      kanidmCR = optionalAttrs kaniopEnabled {
        kanidm-cr = {
          apiVersion = "kaniop.rs/v1beta1";
          kind = "Kanidm";
          metadata = {
            name = cfg.instanceName;
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/managed-by" = "catallaxy";
            };
          };
          spec = {
            domain = cfg.domain;

            image = cfg.images.server.ref;
            replicaGroups = [
              {
                name = "default";
                replicas = cfg.replicas;
              }
            ];
          }
          // optionalAttrs (effectiveOauth2NamespaceSelector != null) {
            oauth2ClientNamespaceSelector = effectiveOauth2NamespaceSelector;
          }
          // optionalAttrs (cfg.tls.issuerRef != null) {
            tlsSecretName = cfg.tls.secretName;
          }
          // optionalAttrs (cfg.storage.storageClass != null) {

            storage = {
              volumeClaimTemplate = {
                spec = {
                  accessModes = [ "ReadWriteOnce" ];
                  resources.requests.storage = cfg.storage.size;
                  storageClassName = cfg.storage.storageClass;
                };
              };
            };
          };
        };
      };

      tlsCertResource = optionalAttrs (cfg.tls.issuerRef != null && domainConfigured) {
        kanidm-tls = {
          apiVersion = "cert-manager.io/v1";
          kind = "Certificate";
          metadata = {
            name = cfg.tls.secretName;
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/managed-by" = "catallaxy";
            };
          };
          spec = {
            secretName = cfg.tls.secretName;
            issuerRef = {
              name = cfg.tls.issuerRef.name;
              kind = cfg.tls.issuerRef.kind;
            };
            dnsNames = [
              cfg.domain
            ]

            ++ optional (!useAcme) "${cfg.instanceName}.${cfg.namespace}.svc.cluster.local";
          };
        };
      };

      provisioning = import ./provisioning.nix { inherit lib cfg; };
      inherit (provisioning)
        groupResources
        personResources
        oauth2Resources
        serviceAccountResources
        oauth2Namespaces
        hasCrossNamespaceClient
        effectiveOauth2NamespaceSelector
        hasProvisioning
        ;

      accountNames = lib.attrNames cfg.users ++ lib.attrNames cfg.serviceAccounts;
      groupNames = lib.attrNames cfg.groups;
      principals = accountNames ++ groupNames;

      namedOrNone = names: if names == [ ] then "none" else lib.concatStringsSep ", " names;

      danglingIn =
        path: known: names:
        map (name: { inherit path name; }) (lib.filter (n: !(builtins.elem n known)) names);

      danglingRefs =
        lib.concatLists (
          lib.mapAttrsToList (
            groupName: group: danglingIn "groups.${groupName}.members" principals group.members
          ) cfg.groups
        )
        ++ lib.concatLists (
          lib.mapAttrsToList (
            clientName: client:
            danglingIn "oauth2Clients.${clientName}.scopeMap" groupNames (map (s: s.group) client.scopeMap)
            ++ danglingIn "oauth2Clients.${clientName}.supScopeMap" groupNames (
              map (s: s.group) client.supScopeMap
            )
          ) cfg.oauth2Clients
        );

      internalHost = "${cfg.instanceName}.${cfg.namespace}.svc.cluster.local";

      useAcme =
        (config.floes.cert-manager.exports.issuance or null) != null
        && config.floes.cert-manager.exports.issuance.publicIssuer;
      effectiveHost = if useAcme then cfg.domain else internalHost;
      effectiveUrl = if useAcme then cfg.origin else "https://${internalHost}:8443";
    in
    {

      assertions = [
        {
          assertion = danglingRefs == [ ];
          message = ''
            kanidm: a reference names a principal this floe does not declare:

            ${lib.concatMapStringsSep "\n" (r: "  ${r.path} -> ${r.name}") danglingRefs}

            It declares accounts ${
              namedOrNone (lib.attrNames cfg.users ++ lib.attrNames cfg.serviceAccounts)
            } and groups ${namedOrNone (lib.attrNames cfg.groups)}.

            kanidm resolves these by name at reconcile time, so a name that
            matches nothing is not an error there either: the group comes up
            without the member, or the client grants its scopes to nobody.
            What looks like a permissions bug in the running lab is a typo
            here.
          '';
        }
        {
          assertion =
            !hasCrossNamespaceClient
            || cfg.oauth2ClientNamespaceSelector == null
            || cfg.oauth2ClientNamespaceSelector == { };
          message = ''
            kanidm: `oauth2ClientNamespaceSelector` is a label selector, but
            OAuth2 clients are declared in ${lib.concatStringsSep ", " oauth2Namespaces}.
            Namespaces created by `createNamespaces` carry no labels, so a
            label selector cannot match them and those clients would never
            be reconciled.

            Either use `{ }` (all namespaces), or drop the option entirely
            and let it derive from the clients you declared.
          '';
        }
      ];

      floes.kanidm.exports = {
        identity = {
          instanceReady = "kanidm/instance/ready";

          provisioningReady = if kaniopEnabled && hasProvisioning then "kanidm/provisioning/ready" else null;
        };
        host = effectiveHost;
        inherit (cfg) namespace domain instanceName;
        port = if useAcme then 443 else 8443;
        url = effectiveUrl;
        externalUrl = cfg.origin;
        externalHost = cfg.domain;
        externalPort = 443;
        oidcIssuer = "${cfg.origin}/oauth2/openid/";
        oidcDiscovery = "${cfg.origin}/.well-known/openid-configuration";
        authorizationEndpoint = "${cfg.origin}/ui/oauth2";
        tokenEndpoint = "${cfg.origin}/oauth2/token";
        internalTokenEndpoint = "${effectiveUrl}/oauth2/token";
        oauth2Clients = mapAttrs (
          name: _:
          let
            client = cfg.oauth2Clients.${name};
            clientNs = if client.namespace != null then client.namespace else cfg.namespace;
            secretName = "${name}-kanidm-oauth2-credentials";

            supFor =
              g:
              let
                m = lib.findFirst (s: s.group == g) null client.supScopeMap;
              in
              if m == null then [ ] else m.scopes;
            perGroupScopes = map (sm: lib.unique (sm.scopes ++ supFor sm.group)) client.scopeMap;
            grantedScopes =
              if perGroupScopes == [ ] then
                [ ]
              else
                lib.foldl' lib.intersectLists (builtins.head perGroupScopes) (builtins.tail perGroupScopes);
          in
          {
            issuer = "${cfg.origin}/oauth2/openid/${name}";
            internalIssuer = "${effectiveUrl}/oauth2/openid/${name}";
            internalJwksUri = "${effectiveUrl}/oauth2/openid/${name}/public_key.jwk";
            clientId = name;

            clientSecretRef =
              if client.public then
                null
              else
                {
                  name = secretName;
                  namespace = clientNs;
                  key = "CLIENT_SECRET";
                };

            readyProbe =
              if client.public then
                { }
              else
                {
                  kind = "jsonpath";
                  resource = "secret/${secretName}";
                  namespace = clientNs;
                  jsonpath = "{.data.CLIENT_SECRET}";
                  timeout = "10m";
                };
            inherit grantedScopes;

            claimValues = lib.listToAttrs (
              map (c: {
                name = c.name;
                value = lib.unique (lib.concatMap (v: v.values) c.valuesMap);
              }) client.claimMap
            );
            scopeMapGroups = lib.unique (
              map (m: lib.head (lib.splitString "@" m.group)) (client.scopeMap ++ client.supScopeMap)
            );
          }
        ) cfg.oauth2Clients;

        oidcDiscoveryReadyProbe = {
          kind = "http";
          url = "${cfg.origin}/.well-known/openid-configuration";
          expectedStatus = 200;
          timeout = "10m";
          interval = "15s";
        };

        adminPasswordsReadyProbe = {
          kind = "exists";
          resource = "secret/${cfg.instanceName}-admin-passwords";
          namespace = cfg.namespace;
          timeout = "10m";
        };
        caSecretRef = {
          name = cfg.tls.secretName;
          namespace = cfg.namespace;
          key = "ca.crt";
        };
        serviceAccounts = mapAttrs (name: sa: {
          inherit name;
          namespace = cfg.namespace;
          apiTokenSecrets = lib.listToAttrs (
            map (
              tok:
              lib.nameValuePair tok.label {
                inherit (tok) purpose secretName;
                namespace = cfg.namespace;
              }
            ) sa.apiTokens
          );
          credentialsSecret =
            if sa.generateCredentials then "${name}-kanidm-service-account-credentials" else null;
        }) cfg.serviceAccounts;

        groups = mapAttrs (name: _: {
          inherit name;
          spn = "${name}@${cfg.domain}";
        }) cfg.groups;
      };

      floes.kanidm.ops.kanidm.init-user = {
        description = "Reset a kanidm account's password, for a first login";
        args = [
          {
            name = "username";
            description = "kanidm account name (e.g. lab-admin)";
          }
        ];
        package = pkgs.writeShellApplication {
          name = "init-user";
          runtimeInputs = [
            pkgs.kubectl
            pkgs.jq
            pkgs.coreutils
          ];
          text = ''
            USER="''${1:?Usage: init-user <username>}"
            CONTEXT="''${KUBECONTEXT:-${config.cluster.ref.kubeContext or ""}}"
            NS="${cfg.namespace}"
            POD="${cfg.instanceName}-default-0"

            echo "Resetting password for '$USER'..."

            # `-o json` asks kanidmd for the password as a field. This used to
            # read it back out of the human-readable line with a `\K` PCRE
            # scrape, which is GNU-grep-only and silently yields nothing the
            # first time upstream rewords that line — and "nothing" here means
            # the operator is told no password at all.
            #
            # stderr is kept separate rather than folded in with `2>&1`,
            # because kanidmd logs there and a log line in the middle of the
            # document is not parseable as one.
            ERRLOG=$(mktemp)
            trap 'rm -f "$ERRLOG"' EXIT

            if ! OUTPUT=$(kubectl --context "$CONTEXT" -n "$NS" exec "$POD" -- \
              kanidmd recover-account "$USER" -o json 2>"$ERRLOG"); then
              echo "Failed:"
              cat "$ERRLOG" >&2
              echo "$OUTPUT"
              exit 1
            fi

            PASSWORD=$(printf '%s' "$OUTPUT" \
              | jq -r 'if type == "object" then (.password // .new_password // empty) else empty end' \
              2>/dev/null || true)

            if [ -z "$PASSWORD" ]; then
              # The reset itself succeeded, so the password exists — this
              # build just could not find it in the response. Show everything
              # rather than leaving the operator with nothing.
              echo "Could not read the new password out of kanidmd's response." >&2
              echo "Raw output follows:" >&2
              echo "$OUTPUT"
              cat "$ERRLOG" >&2
              exit 1
            else
              echo ""
              echo "Account '$USER' password has been reset."
              echo ""
              echo "  Login URL: ${cfg.origin}"
              echo "  Username:  $USER"
              echo "  Password:  $PASSWORD"
              echo ""
              echo "Log in and enroll a passkey or change the password."
            fi
          '';
        };
      };

      floes.gateway.internalHostnames =
        if cfg.gateway.enable && domainConfigured then [ cfg.domain ] else [ ];

      floes.kanidm.network = {

        declared = true;

        serves.https.port = 443;

      };

      floes.kanidm.imagesComplete = true;

      floes.kanidm.images.server = {

        repository = "kanidm/server";

        tag = cfg.version;

      };

      floes.kanidm.bundles = {
        kanidm = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };

          createNamespaces = [ cfg.namespace ];

          resources =
            (if kaniopEnabled then kanidmCR else { })
            // tlsCertResource
            // routeResource
            // internalRouteResource
            // backendTlsPolicy;

          provides = [
            "kanidm/instance/ready"
            "identity/instance/ready"
          ];
          # The two paths render different things, so they cannot share a
          # probe. kaniop reconciles a Kanidm CR that reports Available;
          # the chart renders a StatefulSet, which has no such condition and
          # would leave the probe waiting out its timeout and failing the
          # deploy.
          readyProbe =
            if kaniopEnabled then
              {
                kind = "condition";
                resource = "kanidm/${cfg.instanceName}";
                namespace = cfg.namespace;
                condition = "Available";
                timeout = "10m";
              }
            else
              {
                kind = "jsonpath";
                resource = "statefulset/kanidm";
                namespace = cfg.namespace;
                jsonpath = "{.status.readyReplicas}";
                value = toString cfg.replicas;
                timeout = "10m";
              };

          helmCharts = optionalAttrs (!kaniopEnabled) {
            kanidm = {
              chart = chartRef;
              releaseName = "kanidm";
              namespace = cfg.namespace;

              # The bundle already declares this namespace, and asking the
              # chart for it too renders a second Namespace with the same
              # name.
              createNamespace = false;
              # The chart hardcodes `kanidm/server:{{ .Chart.AppVersion }}` and
              # exposes no image value at all, so `version` reached nothing on
              # this path while working fine on the kaniop one. Patching is the
              # only way in, and without it the two paths deploy different
              # versions of kanidm from the same option.
              kustomize = {
                enable = true;
                patches = [
                  {
                    # The chart renders a Namespace unconditionally. Catallaxy
                    # creates lab namespaces itself, labelled for pod security
                    # and covered by the default-deny, so the chart's copy is a
                    # second resource with the same name and none of that.
                    target = {
                      kind = "Namespace";
                      name = cfg.namespace;
                    };
                    patch = ''
                      apiVersion: v1
                      kind: Namespace
                      metadata:
                        name: ${cfg.namespace}
                      $patch: delete
                    '';
                  }
                  {
                    target = {
                      kind = "StatefulSet";
                      name = "kanidm";
                    };
                    patch = ''
                      apiVersion: apps/v1
                      kind: StatefulSet
                      metadata:
                        name: kanidm
                      spec:
                        template:
                          spec:
                            containers:
                              - name: kanidm
                                image: ${cfg.images.server.ref}
                    '';
                  }
                ];
              };

              values = {
                replicas = cfg.replicas;

                kanidm = {
                  domain = cfg.domain;
                  origin = cfg.origin;
                };

                persistence = {
                  enabled = true;
                  size = cfg.storage.size;
                }
                // optionalAttrs (cfg.storage.storageClass != null) {
                  storageClass = cfg.storage.storageClass;
                };
              }
              // optionalAttrs (cfg.tls.issuerRef != null) {
                tls.secretName = cfg.tls.secretName;
              };
            };
          };

        };

        kanidm-provisioning = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };

          createNamespaces = lib.unique ([ cfg.namespace ] ++ oauth2Namespaces);

          resources =
            if kaniopEnabled && hasProvisioning then
              groupResources // personResources // oauth2Resources // serviceAccountResources
            else
              { };

          requires = lib.optionals (kaniopEnabled && hasProvisioning) [
            "kanidm/instance/ready"
          ];
          provides = lib.optionals (kaniopEnabled && hasProvisioning) [
            "kanidm/provisioning/ready"
            "identity/provisioning/ready"
          ];

          readyProbe =
            if kaniopEnabled && hasProvisioning && oauth2Resources != { } then
              {
                kind = "kubectl-wait";
                args = [
                  "--for=jsonpath={.status.ready}=true"
                  "kanidmoauth2clients.kaniop.rs"
                  "--all"
                ]
                ++ (

                  if lib.length oauth2Namespaces == 1 then
                    [
                      "-n"
                      (lib.head oauth2Namespaces)
                    ]
                  else
                    [ "-A" ]
                )
                ++ [ "--timeout=5m" ];
              }
            else
              null;
        };
      };
    }
  );
}
