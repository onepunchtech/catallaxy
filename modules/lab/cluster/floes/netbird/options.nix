{
  lib,
  config,
  pkgs,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  inherit (import ../../../../../lib/floe { inherit lib; }) refs;
  contracts = import ../../../../../lib/contracts { inherit lib; };
  ident = import ../../../../../lib/util/ident.nix { inherit lib; };
  cfg = config.floes.netbird;

  inherit (import ./names.nix { })
    clusterRouterKeyName
    setupKeySecretName
    setupKeySecretKey
    ;

  legacyRoutingRemovalHint = ''
    The scalar routing option was removed. Declare an entry under
    `floes.netbird.routing.resources` instead, with per-resource
    `sourceGroups`, so each resource is reachable by the groups that
    need it rather than by everyone on the mesh. The `mesh` example lab
    shows the shape.
  '';
in
{
  imports = [
    (lib.mkRemovedOptionModule [ "floes" "netbird" "routing" "serviceCIDR" ] legacyRoutingRemovalHint)
    (lib.mkRemovedOptionModule [ "floes" "netbird" "routing" "podCIDR" ] legacyRoutingRemovalHint)
    (lib.mkRemovedOptionModule [ "floes" "netbird" "routing" "apiServerHost" ] legacyRoutingRemovalHint)
    (lib.mkRemovedOptionModule [ "floes" "netbird" "routing" "sourceGroup" ]
      "Use `floes.netbird.routing.resources.<n>.sourceGroups` (per-resource) for policy sources; `floes.netbird.routing.sourceGroups` (plural) drives DNS distribution."
    )
  ];

  config.floes.netbird.version = lib.mkDefault (cfg.client.package.version or pkgs.netbird.version);

  options.floes.netbird = {

    versionCheck = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Assert at eval time that the host client and the management image
        agree on major.minor.

        The escape hatch is not optional decoration: `version` follows
        `client.package`, so pinning `version` alone contradicts the
        client and fails eval, and pinning the package back needs a
        fixed-output override with a fresh `vendorHash`. Set this false
        when you genuinely mean to run a skewed pair.
      '';
    };

    domain = mkOption {
      type = ident.types.fqdn;
      default = "vpn.example.com";
      description = ''
        Hostname the management API and dashboard are served on. Typed as an
        FQDN so a bare hostname is refused here rather than by an assertion
        that has already lost track of which option set it.
      '';
    };

    signal.domain = mkOption {
      type = types.str;
      default = "";
      description = "Signal server hostname. Defaults to signal-<domain> (e.g. signal-nb.example.com).";
    };

    gateway = {
      enable = mkOption {
        type = types.bool;

        default = cfg.management.enable;
        defaultText = lib.literalExpression "config.floes.netbird.management.enable";
        description = "Register this domain with the lab proxy for host-side routing.";
      };
      mode = mkOption {
        type = types.str;
        default = "terminate";
        description = "Proxy mode: 'terminate' for TLS termination at haproxy.";
      };
      extraDomains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional domains routed to the same cluster backend.";
      };
    };

    tls = {
      issuerRef = contracts.tls.issuerRefOption {
        default = contracts.tls.defaultIssuer config;
        description = "Issuer that signs the serving certificate. Null mints none.";
      };
      secretName = mkOption {
        type = types.str;
        default = "netbird-tls";
        description = "Secret the issued certificate lands in.";
      };
      caBundle = mkOption {
        type = refs.nullableMountableRef;
        default = config.floes.cert-manager.exports.caBundle;
        description = ''
          Lab CA bundle mounted into management (and the agent) so they
          trust `*.<zone>` internally. Null when nothing produces one.
        '';
      };
    };

    management = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run the mesh control plane (management + signal + relay, the
          prechart Secrets, and the OIDC bootstrap Job) in this cluster.

          Set false for a **peer-only** cluster: one that joins an
          existing mesh with `agent.enable = true` and advertises its own
          routes, but runs no server of its own. A mesh has exactly one
          control plane, so at most one cluster in a lab should leave
          this true.

          `enable` still has to be true, it gates the floe as a whole.
          A peer-only cluster therefore sets:

            floes.netbird = {
              enable = true;
              management.enable = false;
              agent = { enable = true; managementUrl = "https://nb.<zone>"; ... };
            };

          `operator` follows this flag by default, since it reconciles
          CRDs against the management API. `routing` and `dashboard` are
          off by default and should stay off on a peer.
        '';
      };

      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "How many management replicas to run.";
      };
      storage = {
        size = mkOption {
          type = types.str;
          default = "5Gi";
          description = "Size of the volume holding the management datastore.";
        };
        storageClass = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "StorageClass for it. Null takes the cluster default.";
        };
      };
    };

    signal.replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "How many signal replicas to run.";
    };

    stun = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Run a TURN server, for peers that cannot hole-punch a direct path.";
      };
      domain = mkOption {
        type = types.str;
        default = "turn.example.com";
        description = "Hostname the TURN server is reached on.";
      };
    };

    turn = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Run a relay server, the fallback when TURN also fails.";
      };
      domain = mkOption {
        type = types.str;
        default = "turn.example.com";
        description = "Hostname the relay is reached on.";
      };
    };

    lazyConnections = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Let peers defer their tunnels until traffic asks for one.

        Off, because a lab that resolves names over the mesh deadlocks
        on it: neither peer dials until traffic demands it, and the
        traffic that would demand it is the DNS query whose resolver
        sits behind the mesh. Both peers sit at
        `Peers count: 0/1 Connected` and every internal name is
        unresolvable (mesh.local, 2026-08-04).

        Worth turning on for a large mesh where most peer pairs never
        talk and holding every tunnel open is the greater cost.
      '';
    };

    sso = {
      forcePrompt = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Re-authenticate the operator on every join, even when they
          already hold a valid IdP session.

          The browser login window is a hardcoded 300s in the netbird
          client and cannot be extended, so forcing a prompt spends that
          fixed budget on credential entry, password manager and MFA included,
          before the callback can even be issued. Off by default so
          a live session redirects immediately.
        '';
      };
    };

    idp = {

      client = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              issuer = mkOption {
                type = types.str;
                example = "https://idm.example.com/oauth2/openid/netbird";
                description = ''
                  Public OIDC issuer URL for this client. Management
                  fetches `<issuer>/.well-known/openid-configuration` at
                  Pod startup and exits hard when it 404s, which is what
                  a client that does not exist at the provider looks
                  like from in here.
                '';
              };
              internalIssuer = mkOption {
                type = types.str;
                default = "";
                description = ''
                  In-cluster issuer for the same client, when the
                  provider is reachable on a Service address. Pods that
                  discover OIDC at start-up use this to avoid a hairpin
                  through the public gateway, and it keeps working when
                  public DNS does not.
                '';
              };
              clientId = mkOption {
                type = types.str;
                description = ''
                  OAuth2 `client_id`, and the audience management
                  expects in incoming JWTs.
                '';
              };
              publicIssuer = mkOption {
                type = types.str;
                default = "";
                description = ''
                  The issuer string management matches against a token's
                  `iss` claim. A provider stamps its public issuer into
                  every token regardless of which address the token was
                  requested from, so this is NOT interchangeable with
                  `issuer` when that points in-cluster: `AuthIssuer` is a
                  value to compare, `jwksUri` is a URL to fetch, and they
                  legitimately differ (mesh.local, 2026-08-01).

                  Defaults to `issuer`.
                '';
              };
              authorizationEndpoint = mkOption {
                type = types.str;
                default = "";
                description = ''
                  Where the CLI and dashboard send a human to log in.
                  Public by necessity: a browser has to reach it.

                  Required when `jwksUri` is set: supplying an explicit
                  key location turns off discovery, and discovery was
                  what used to populate the PKCE endpoints.
                '';
              };
              tokenEndpoint = mkOption {
                type = types.str;
                default = "";
                description = "Token endpoint for the browser PKCE exchange.";
              };
              jwksUri = mkOption {
                type = types.str;
                default = "";
                description = ''
                  Signing-key set management validates request JWTs
                  against. Take it from the provider: kanidm publishes
                  `exports.oauth2Clients.<id>.internalJwksUri`.

                  Empty means "follow the discovery document", whose
                  `jwks_uri` is built from the provider's public origin
                  and need not be routable from a Pod.
                '';
              };
            };
          }
        );
        default = null;
        description = ''
          The PUBLIC client used for interactive login, and the issuer
          management validates tokens against. Null disables OIDC
          entirely: a setup-key-only lab needs no identity provider.

          Wiring against kanidm: `config.floes.kanidm.exports.oauth2Clients.<id>` for a
          client declared `public = true`.
        '';
      };

      machine = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              tokenEndpoint = mkOption {
                type = types.str;
                default = "";
                description = ''
                  Token endpoint the exchange grant is POSTed to. Take it
                  from the provider: kanidm publishes
                  `exports.internalTokenEndpoint`.

                  Empty falls back to the `token_endpoint` in the
                  discovery document, which is built from the public
                  origin and need not be routable from a Pod.
                '';
              };
              tokenRef = mkOption {
                type = types.submodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      description = "Name of the Secret holding the token.";
                    };
                    namespace = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = ''
                        Namespace of the token Secret. Cross-namespace is
                        normal, since the provider usually lives in its own,
                        and the floe emits the Role+RoleBinding letting
                        the bootstrap Job's ServiceAccount read it.
                      '';
                    };
                    key = mkOption {
                      type = types.str;
                      default = "token";
                      description = "Key within that Secret.";
                    };
                  };
                };
                description = ''
                  Service-account API token the bootstrap Job presents as
                  the RFC 8693 `subject_token`. The account must belong to
                  a group in the client's scope map, or the grant fails
                  with HTTP 400.
                '';
              };
            };
          }
        );
        default = null;
        description = ''
          OPTIONAL server-side bootstrap: a service-account token the Job
          exchanges for an access token, used to mint the operator's PAT.

          The exchange runs as `client.clientId`, NOT as a second client.
          A provider issues the token audienced to the client that asked
          for it, and management only accepts its own audience, and kanidm
          rejects a cross-audience request outright with `invalid_target`.
          A separate "machine" client therefore produces tokens management
          can never accept (mesh.local, 2026-08-01). No client secret is
          involved: the grant authenticates by the subject token.

          Null means no bootstrap Job is emitted. Users still
          authenticate and their groups still arrive in JWT claims; what
          is lost is provisioning that needs a PAT.
        '';
      };
    };

    groups = mkOption {
      type = types.attrsOf (types.submodule { options = { }; });
      default = { };
      description = ''
        Netbird Groups to ensure exist. Two well-known groups
        (`routers`, `operators`) are always emitted; declare more here.
      '';
    };

    setupKeys = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            autoGroups = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Group names auto-assigned to peers using this key.";
            };
            duration = mkOption {
              type = types.str;
              default = "8760h";
              description = "Validity period (e.g. 24h, 30m, 8760h).";
            };
            ephemeral = mkOption {
              type = types.bool;
              default = false;
              description = "Peers joining with this key are removed when they go offline. Suits short-lived workloads, not routers.";
            };
          };
        }
      );
      default = { };
      description = ''
        Extra setup keys to emit. Two well-known keys
        (`cluster-router` → group `routers`, `operator` → group
        `operators`) are always emitted. The operator writes the
        minted key into Secret `setup-key-<name>` with key `setup-key`.
      '';
    };

    routing = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Provision a Netbird Network + Router + Resources + Policy +
          Nameserver via the management REST API at lab-up time.
          Requires `operator.enable` (the routing Job uses the
          operator's PAT). Without this, peers register but have no
          ACL rules and no DNS, so the mesh is useless for reaching
          internal services.
        '';
      };

      networks = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              routerGroup = mkOption {
                type = types.str;
                default = "routers";
                description = ''
                  Netbird group whose peers route this Network. Every
                  peer in it must be able to reach every resource
                  below, because netbird treats them as redundant
                  paths to one resource set and balances between
                  equal-metric routers.
                '';
              };

              resources = mkOption {
                default = { };
                example = lib.literalExpression ''
                  {
                    forgejo = {
                      address = "forgejo.forgejo.svc.cluster.local";
                      sourceGroups = [ "mesh-dev" "mesh-admin" ];
                      description = "Git, reachable to devs and admins";
                    };
                    grafana = {
                      address = "grafana.grafana.svc.cluster.local";
                      sourceGroups = [ "mesh-user" "mesh-admin" ];
                    };
                  }
                '';
                description = ''
                  Declarative netbird NetworkResources with per-resource
                  access policies. Each entry produces one NetworkResource
                  on the Network created by this routing job, plus one
                  Policy rule granting the named `sourceGroups` (netbird
                  group names, matching values in
                  `operator.autoGroupsFromJwt`) access to that resource.

                  Preferred addressing shape is an FQDN into the cluster
                  DNS (`<svc>.<ns>.svc.cluster.local`) so the resource
                  decouples from ClusterIP allocation. CIDR / single IP /
                  wildcard domain are also valid: netbird v0.32+ parses
                  the address syntax and routes accordingly.

                  Every `sourceGroups` entry MUST appear in
                  `operator.autoGroupsFromJwt`, enforced by an eval-time
                  assertion so typos fail at `nix flake check` rather than
                  silently producing a Policy rule with zero peer members.
                '';
                type = types.attrsOf (
                  types.submodule (
                    { name, ... }:
                    {
                      options = {
                        address = mkOption {
                          type = types.str;
                          example = "forgejo.forgejo.svc.cluster.local";
                          description = ''
                            NetworkResource address. Accepts a CIDR (e.g.
                            `10.96.0.0/12`), a single IP (`10.96.0.250`),
                            an FQDN, or a wildcard domain (`*.internal`).
                            Netbird's management server rejects garbage at
                            apply time, so no pre-classification here.
                          '';
                        };
                        sourceGroups = mkOption {
                          type = types.listOf types.str;
                          example = [ "mesh-dev" ];
                          description = ''
                            Netbird Group names allowed to reach this
                            resource. Each name must appear in
                            `operator.autoGroupsFromJwt`: those are the
                            Groups the framework materialises via
                            KanidmGroup CRs and matches against the JWT
                            claim named by `jwtGroupsClaimName`.

                            Empty list is legal but produces an unreachable
                            resource; the eval-time assertion warns.
                          '';
                        };
                        description = mkOption {
                          type = types.str;
                          default = "Managed by catallaxy";
                          description = "Description recorded on the netbird object, so an operator reading the netbird UI can tell what created it.";
                        };
                        enabled = mkOption {
                          type = types.bool;
                          default = true;
                          description = ''
                            Whether the NetworkResource is active. Disabled
                            resources remain on netbird's side (Policy rule
                            won't grant access). Flip to false to revoke
                            without deleting.
                          '';
                        };
                      };
                    }
                  )
                );
              };
            };
          }
        );
        default = { };
        description = ''
          Netbird Networks to provision, one per set of resources that
          share a reachability domain, in practice one per cluster.

          Routing peers attach to a Network, never to an individual
          resource, and netbird treats several of them as high
          availability for that Network's whole resource set. So a
          Network whose resources live in two clusters gets its traffic
          balanced across a router that can reach the target and one
          that cannot, which presents as intermittent rather than
          broken (mesh.local, 2026-08-05).

          Each entry becomes one Network, one NetworkRouter bound to
          `routerGroup`, its resources, and a Policy per resource.
        '';
      };

      dnsDomains = mkOption {
        type = types.listOf types.str;
        default =
          let
            internalDomain = config.floes.gateway.exports.internalDomain or "";
          in
          lib.optionals (internalDomain != "") [
            internalDomain
            "svc.cluster.local"
          ];
        defaultText = lib.literalExpression ''
          [ floes.gateway.exports.internalDomain "svc.cluster.local" ]
        '';
        description = ''
          Domains routed to `resolverIP` via a Netbird Nameserver
          Group. Empty list = no nameserver group created.

          Defaults to the internal tier's zone, which the gateway owns
          and publishes, plus the Kubernetes service domain. A mesh peer
          claims every domain listed here, so naming the lab's public
          zone makes public names unresolvable for anyone on the mesh, so
          take the gateway's zone rather than restating one.
        '';
      };

      resolverIP = mkOption {
        type = types.str;
        default =
          let
            subnet = config.cluster.network.serviceSubnet or "";
            octets = lib.splitString "." (lib.head (lib.splitString "/" subnet));
          in
          if subnet == "" then "10.43.0.10" else lib.concatStringsSep "." ((lib.take 3 octets) ++ [ "10" ]);
        defaultText = lib.literalExpression ''"<serviceSubnet first three octets>.10"'';
        description = ''
          IP of the in-cluster DNS resolver (CoreDNS) for
          `dnsDomains`.

          Derived from this cluster's service CIDR, where kube-dns
          conventionally takes the tenth address. k3s/k3d's default CIDR
          puts it at 10.43.0.10.
        '';
      };

      sourceGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Netbird group names whose peers receive DNS pushes via the
          NameserverGroup. Independent of Policy sources (which are
          set per-resource under `resources.<n>.sourceGroups`).

          Auto-derives from `operator.autoGroupsFromJwt` when
          non-empty (via mkDefault): the DNS distribution list is
          simply "every mesh peer that logged in with a role SPN",
          which matches the intent of the routes.

          Set explicitly to override that default.
        '';
      };

    };

    operator = {
      enable = mkOption {
        type = types.bool;

        default = cfg.management.enable;
        defaultText = lib.literalExpression "config.floes.netbird.management.enable";
        description = ''
          Deploy github.com/netbirdio/kubernetes-operator alongside
          the management server. Watches Group/NetworkResource/
          NetworkRouter/SetupKey/SidecarProfile CRDs and reconciles
          them via the management API. Requires a one-time
          `cata lab netbird bootstrap <lab>` to seed its PAT.
        '';
      };

      chart = mkOption {
        type = types.package;
        default = cataCharts.netbird-operator.chart;
        description = "Helm chart to install. Defaults to the chart catallaxy pins.";
      };

      crds = mkOption {
        type = types.nullOr types.path;
        default = cataCharts.netbird-operator.crds or null;
        description = "CRDs for the netbird operator. Null skips installing them, for a cluster where something else owns them.";
      };

      apiTokenSecretName = mkOption {
        type = types.str;
        default = "netbird-mgmt-api-key";
        description = "Secret the operator's API token is written to.";
      };

      apiTokenSecretKey = mkOption {
        type = types.str;
        default = "NB_API_KEY";
        description = "Key within that Secret.";
      };

      managementUrl = mkOption {
        type = types.str;
        default = "";
        description = ''
          URL the operator uses to reach the Netbird management API.
          Defaults to the in-cluster Service URL when blank.
        '';
      };

      autoGroupsFromJwt = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Values from the JWT claim named by `jwtGroupsClaimName`
          (default: `groups`) that netbird should map to
          framework-created netbird Groups. Each entry becomes a
          Group CR and a match target for peer auto-assignment.

          Two IdP patterns are supported, distinguished by which JWT
          claim carries the values:

          1. `jwtGroupsClaimName = "groups"` (default): netbird
             reads kanidm's standard `groups` claim. Kanidm may
             non-deterministically render a group as SPN or UUID
             per-token (see [[reference-kanidm-groups-claim-scopemap-
             quirk]]), so list every candidate SPN and rely on
             per-request survival probability. Fragile.

          2. `jwtGroupsClaimName = "mesh_roles"` (or any custom
             claim name): netbird reads a dedicated claim populated
             by kanidm's `claimMap` with deterministic literal
             values. Values here are the literals from claimMap
             (e.g. `["mesh-admin"]`), not group SPNs. Reliable, but
             claimMap output isn't subject to the SPN/UUID quirk.
             This is the recommended pattern for stable mesh authz.

          The bootstrap Job's `configure_account` also sets
          `jwt_allow_groups` to this list on the netbird account,
          so unrelated JWT groups (`idm_all_persons`, etc.) don't
          create junk netbird Groups.

          Empty list preserves 0.60-era behavior for non-kanidm IdPs
          that emit short-name group claims.
        '';
      };

      adminGroupsFromJwt = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "netbird-admins@idm.example.test" ];
        description = ''
          Netbird Group names (SPNs, matching values in
          `autoGroupsFromJwt`) whose members should hold Netbird
          `role = "admin"`. A reconciler CronJob polls the
          management API and promotes any user whose `auto_groups`
          include one of these groups.

          Every value MUST appear in `autoGroupsFromJwt` too, because
          otherwise a peer's `auto_groups` never contains the SPN
          and the promotion never fires. Enforced by an eval-time
          assertion.

          Netbird 0.73 has no native "JWT group → role" mapping
          (netbirdio/netbird#2083); this option encodes the
          recommended workaround via post-login `PUT /api/users/{id}`.
        '';
      };

      jwtGroupsClaimName = mkOption {
        type = types.str;
        default = "groups";
        example = "mesh_roles";
        description = ''
          Name of the JWT claim netbird reads for auto-group
          assignment. Written to netbird's account settings as
          `jwt_groups_claim_name` by the bootstrap Job.

          Default `"groups"` is the OIDC-standard claim kanidm
          populates from a user's group memberships, but kanidm's
          rendering (SPN vs UUID) is non-deterministic and multi-
          candidate `autoGroupsFromJwt` lists only reduce the
          failure rate.

          Set this to a custom claim name (e.g. `"mesh_roles"`)
          and populate it deterministically via kanidm's `claimMap`
          on the netbird OAuth2Client. Mesh authz then becomes
          reliable at eval-time-known values, not per-session
          probabilistic. See
          [[reference-kanidm-groups-claim-scopemap-quirk]] for the
          underlying issue this option works around.
        '';
      };
    };

    agent = {
      enable = mkEnableOption "Netbird agent (peer) in this cluster";

      namespace = mkOption {
        type = types.str;
        default = cfg.namespace;
        defaultText = lib.literalExpression "config.floes.netbird.namespace";
        description = ''
          Namespace for the agent Deployment. Defaults to the netbird
          component's namespace so the agent can mount the
          operator-minted setup-key Secret directly. Override only if
          you need namespace isolation; that requires arranging
          same-namespace delivery of the setup-key Secret yourself.
        '';
      };

      managementUrl = mkOption {
        type = types.str;
        default = "https://api.netbird.io:443";
        description = "URL of the management API this agent registers with. A peer cluster points at the cluster running management.";
      };

      setupKeyRef = mkOption {
        type = types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              default = setupKeySecretName clusterRouterKeyName;
              defaultText = lib.literalExpression ''"setup-key-cluster-router"'';
              description = "Secret holding the setup key this agent joins with.";
            };
            key = mkOption {
              type = types.str;
              default = setupKeySecretKey;
              description = "Key within that Secret.";
            };
          };
        };
        default = { };
        description = ''
          Secret holding the agent's setup-key. Defaults to the
          operator-managed `setup-key-cluster-router`.
        '';
      };

      hostname = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Name this peer appears under in netbird. Null lets netbird derive one.";
      };

      advertisedRoutes = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "CIDRs this peer advertises a route to, which is what makes it a router rather than a leaf.";
      };

      persistence = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Claim a volume for the agent's state, so it keeps its identity across restarts.";
        };
        size = mkOption {
          type = types.str;
          default = "1Gi";
          description = "Size of that volume.";
        };
        storageClass = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "StorageClass for it. Null takes the cluster default.";
        };
      };

      resources = mkOption {
        type = types.attrs;
        default = {
          requests = {
            cpu = "50m";
            memory = "64Mi";
          };
          limits = {
            cpu = "500m";
            memory = "256Mi";
          };
        };
        description = "Resource requests and limits for the agent container.";
      };
    };

    dashboard = {
      enable = mkEnableOption "netbird dashboard SPA";

      domain = mkOption {
        type = types.str;
        default = "";
        description = ''
          Hostname the dashboard serves at. Empty = derive by prefixing
          `nb-dashboard.` onto the parent zone of `cfg.domain` (e.g.
          `nb.lab.example.com` → `nb-dashboard.lab.example.com`).
        '';
      };
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "How many dashboard replicas to run.";
      };
      oidc = {
        clientId = mkOption {
          type = types.str;

          default = "netbird";
          description = "Client ID the dashboard presents to the issuer.";
        };
        client = mkOption {
          type = contracts.oidc.nullableClient;
          default = config.floes.kanidm.exports.oauth2Clients.${cfg.dashboard.oidc.clientId} or null;
          defaultText = lib.literalExpression "config.floes.kanidm.exports.oauth2Clients.\${dashboard.oidc.clientId}";
          description = ''
            The identity provider's published record for this client, or
            null when nothing in the lab publishes one.

            Defaults to kanidm's. Assign any floe's equivalent export to
            run against a different provider; the default names kanidm but
            the type does not.
          '';
        };
        issuerUrl = mkOption {
          type = types.str;
          default = "";
          description = ''
            Full OIDC issuer URL, e.g.
            `https://idm.<zone>/oauth2/openid/netbird-dashboard`. From the
            consumer, this is typically
            `config.floes.kanidm.exports.oauth2Clients.netbird-dashboard.issuer`.
          '';
        };
        scopes = mkOption {
          type = types.listOf types.str;

          default = [
            "openid"
            "profile"
            "email"
            "offline_access"
            "groups"
          ];
          description = "Scopes the dashboard requests at login.";
        };

        authRedirectPath = mkOption {
          type = types.str;
          default = "/auth/callback";
          description = "Path the issuer redirects back to after login.";
        };
        silentRedirectPath = mkOption {
          type = types.str;
          default = "/auth/silent-callback";
          description = "Path used for silent token renewal, which is what keeps a session alive without a visible redirect.";
        };
      };
      gateway = {
        tier = mkOption {
          type = types.enum [
            "public"
            "internal"
          ];
          default = "internal";
          description = ''
            Which gateway the dashboard's HTTPRoute attaches to.
            `internal` (default): dashboard is only reachable from
            netbird-mesh peers, matching the "peer/route management is a
            post-connect concern" model. `public` if the operator wants
            it externally accessible (login is still SSO-gated).
          '';
        };
      };
      tls.secretName = mkOption {
        type = types.str;
        default = "netbird-dashboard-tls";
        description = "Secret the dashboard's certificate lands in.";
      };
      resources = mkOption {
        type = types.attrs;
        default = {
          requests.cpu = "10m";
          requests.memory = "32Mi";
          limits.cpu = "200m";
          limits.memory = "128Mi";
        };
        description = "Resource requests and limits for the dashboard container.";
      };
    };

    wait = {
      attempts = mkOption {
        type = types.ints.positive;
        default = 360;
        description = ''
          Retry attempts for init containers polling Secrets and OIDC
          discovery, and for the bootstrap Job's wait-for-management loop.
        '';
      };
      intervalSeconds = mkOption {
        type = types.ints.positive;
        default = 5;
        description = ''
          Seconds between retry attempts. Default 360×5s = 30 minutes total budget.
        '';
      };
    };

  };
}
