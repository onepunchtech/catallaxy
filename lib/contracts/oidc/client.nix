{ lib }:

let
  inherit (lib) mkOption types;

  secretRefType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        default = "";
        description = "Secret the provider materializes the client secret into.";
      };
      namespace = mkOption {
        type = types.str;
        default = "";
        description = ''
          Namespace holding it. Cross-namespace is normal: a provider
          usually reconciles the Secret into its own namespace, not the
          consumer's.
        '';
      };
      key = mkOption {
        type = types.str;
        default = "CLIENT_SECRET";
        description = "Key inside the Secret holding the client secret.";
      };
    };
  };

  clientOptions = {
    clientId = mkOption {
      type = types.str;
      default = "";
      description = "OIDC client_id (echoes the attribute key).";
    };

    issuer = mkOption {
      type = types.str;
      default = "";
      description = ''
        External OIDC issuer URL for this client, the one a browser
        follows.
      '';
    };

    internalIssuer = mkOption {
      type = types.str;
      default = "";
      description = ''
        In-cluster OIDC issuer URL: the same path as `issuer` but
        pointed at the provider's ClusterIP Service. Avoids a hairpin
        through the public gateway for Pods that discover OIDC on
        start-up.
      '';
    };

    internalJwksUri = mkOption {
      type = types.str;
      default = "";
      description = ''
        Signing-key set on the provider's in-cluster address.

        A relying party that follows the discovery document reaches
        `jwks_uri` on the public origin, which on an internal-tier lab
        has no TLS listener. It then fails every token with "unable to
        find appropriate key", which reads as a bad token rather than an
        unreachable keyset (mesh.local, 2026-08-01). Validators running
        in the cluster take this instead.
      '';
    };

    clientSecretRef = mkOption {
      type = types.nullOr secretRefType;
      default = null;
      description = ''
        Kubernetes Secret reference (name + namespace + key) the
        provider materializes for this client, or `null` when the client
        has no secret.

        Consumers use this instead of re-deriving the provider's Secret
        naming, so a rename upstream lands in one place.

        **Null means public.** A PKCE client has no secret and no Secret
        is minted for one, so a consumer branches on this rather than on
        the provider's own `public` input: null selects token-validation
        plus PKCE, non-null unlocks whatever needs machine credentials.
        Asking "is it public" asks about the provider's input; asking
        whether there is a secret asks for the capability.
      '';
    };

    readyProbe = mkOption {
      type = types.attrs;
      default = { };
      description = ''
        Wait probe consumers pass to
        `k8sHelpers.wait.mkWaitInitContainer` to block on the provider
        reconciling this client's Secret.
      '';
    };

    grantedScopes = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Intersection of scopes every mapped group grants.";
    };

    claimValues = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
      description = ''
        Claim name to every literal this client can emit for it.

        A consumer that auto-assigns on a claim value (netbird maps JWT
        groups to mesh groups) has to know which values can ever appear:
        one the provider never emits means peers join matching nothing.
        Exported so consumers stop reading the provider's raw claim
        declaration, which is its input rather than its interface.
      '';
    };

    scopeMapGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Groups this client's scope maps name, as bare names with any SPN
        domain stripped. Consumers cross-check their own group
        configuration against it.
      '';
    };
  };
in
{
  inherit secretRefType clientOptions;

  clientType = types.submodule { options = clientOptions; };
  clientsType = types.attrsOf (types.submodule { options = clientOptions; });
  nullableClient = types.nullOr (types.submodule { options = clientOptions; });
}
