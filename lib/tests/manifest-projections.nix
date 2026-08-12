{ lib }:

let
  projections = import ../eval/manifest-projections.nix { inherit lib; };
  inherit (projections) consumedProjections withProjectionRequires;

  projectionSet = {
    do-credentials.namespace = "crossplane-system";
    app-secret.namespace = "apps";
  };

  b = resources: {
    requires = [ ];
    inherit resources;
  };

  check =
    name: expected: actual:
    lib.optional (expected != actual) {
      inherit name expected actual;
    };
in
lib.concatLists [

  (check "cluster-scoped consumer with an explicit secretRef.namespace" [ "do-credentials" ]
    (consumedProjections {
      inherit projectionSet;
      bundle = b {
        pc = {
          apiVersion = "digitalocean.crossplane.io/v1beta1";
          kind = "ProviderConfig";
          metadata.name = "default";
          spec.credentials.secretRef = {
            name = "do-credentials";
            namespace = "crossplane-system";
            key = "token";
          };
        };
      };
    })
  )

  (check "namespaced consumer, reference inherits the resource namespace" [ "app-secret" ]
    (consumedProjections {
      inherit projectionSet;
      bundle = b {
        dep = {
          kind = "Deployment";
          metadata = {
            name = "app";
            namespace = "apps";
          };
          spec.template.spec.containers = [
            { env = [ { valueFrom.secretKeyRef.name = "app-secret"; } ]; }
          ];
        };
      };
    })
  )

  (check "namespace mismatch produces no edge" [ ] (consumedProjections {
    inherit projectionSet;
    bundle = b {
      dep = {
        kind = "Deployment";
        metadata = {
          name = "app";
          namespace = "other";
        };
        spec.template.spec.containers = [
          { env = [ { valueFrom.secretKeyRef.name = "app-secret"; } ]; }
        ];
      };
    };
  }))

  (check "reference namespace overrides the resource namespace" [ ] (consumedProjections {
    inherit projectionSet;
    bundle = b {
      pc = {
        kind = "ProviderConfig";
        metadata = {
          name = "x";
          namespace = "crossplane-system";
        };
        spec.credentials.secretRef = {
          name = "do-credentials";
          namespace = "somewhere-else";
        };
      };
    };
  }))

  (check "unprojected secret name is ignored" [ ] (consumedProjections {
    inherit projectionSet;
    bundle = b {
      dep = {
        kind = "Deployment";
        metadata = {
          name = "app";
          namespace = "apps";
        };
        spec.template.spec.volumes = [ { secret.secretName = "not-a-projection"; } ];
      };
    };
  }))

  (check "secretName volume shape is matched" [ "app-secret" ] (consumedProjections {
    inherit projectionSet;
    bundle = b {
      dep = {
        kind = "Deployment";
        metadata = {
          name = "app";
          namespace = "apps";
        };
        spec.template.spec.volumes = [ { secret.secretName = "app-secret"; } ];
      };
    };
  }))

  (check "consumers gain the projection token"
    [
      "already-there"
      "secret:crossplane-system/do-credentials"
    ]
    (
      (withProjectionRequires {
        inherit projectionSet;
        bundles.consumer = {
          requires = [ "already-there" ];
          resources.pc = {
            kind = "ProviderConfig";
            metadata.name = "default";
            spec.credentials.secretRef = {
              name = "do-credentials";
              namespace = "crossplane-system";
            };
          };
        };
      }).consumer.requires
    )
  )
]
