{ lib }:

let
  autoedges = import ../eval/manifest-autoedges.nix { inherit lib; };
  graph = import ../eval/manifest-graph.nix { inherit lib; };
  inherit (autoedges) deriveAutoEdges;
  inherit (graph) computeWaves buildEdges;

  b =
    attrs:
    {
      after = [ ];
      requires = [ ];
      provides = [ ];
      conflicts = [ ];
      declaredBy = "cluster";
      resources = { };
    }
    // attrs;

  # Enough of the API server's own kinds for these fixtures. The real set comes
  # from the generated schemas.
  core = {
    ConfigMap = true;
    Deployment = true;
    Namespace = true;
    Secret = true;
    CustomResourceDefinition = true;
    SecretStore = true;
    ClusterSecretStore = true;
    ExternalSecret = true;
  };

  ns = name: {
    kind = "Namespace";
    apiVersion = "v1";
    metadata.name = name;
  };
  crd = group: kind: {
    kind = "CustomResourceDefinition";
    apiVersion = "apiextensions.k8s.io/v1";
    metadata.name = "${kind}s.${group}";
    spec = {
      inherit group;
      names.kind = kind;
    };
  };
  cr = group: kind: name: namespace: {
    inherit kind;
    apiVersion = "${group}/v1";
    metadata = { inherit name namespace; };
  };
  workload = name: namespace: {
    kind = "Deployment";
    apiVersion = "apps/v1";
    metadata = { inherit name namespace; };
  };
  secretStore = name: {
    kind = "SecretStore";
    apiVersion = "external-secrets.io/v1beta1";
    metadata.name = name;
  };
  clusterSecretStore = name: {
    kind = "ClusterSecretStore";
    apiVersion = "external-secrets.io/v1beta1";
    metadata.name = name;
  };
  externalSecret = name: namespace: storeName: {
    kind = "ExternalSecret";
    apiVersion = "external-secrets.io/v1beta1";
    metadata = { inherit name namespace; };
    spec.secretStoreRef.name = storeName;
  };

  assertEq =
    name: actual: expected:
    if actual == expected then
      [ ]
    else
      [
        {
          inherit name;
          message = "expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";
        }
      ];

  assertThrows =
    name: expr:
    let
      r = builtins.tryEval (builtins.deepSeq expr expr);
    in
    if r.success then
      [
        {
          inherit name;
          message = "expected a thrown error, got: ${builtins.toJSON r.value}";
        }
      ]
    else
      [ ];

  # Asserting on resolved predecessors rather than on the raw `after` strings:
  # the strings are the representation, the edges are the behaviour, and only
  # the second is what the deploy acts on.
  derive =
    args:
    deriveAutoEdges (
      {
        coreKinds = core;
      }
      // args
    );

  predsOf = bundleName: args: lib.sort (a: b: a < b) (buildEdges (derive args)).${bundleName};

  waveNamesOf =
    args:
    map (wave: map (x: x.name) wave) (computeWaves {
      bundles = derive args;
    });

in
lib.concatLists [

  (assertEq "a workload waits for the bundle holding its namespace" (predsOf "workload" {
    bundles = {
      ns-app = b { resources.n = ns "app"; };
      workload = b { resources.d = workload "svc" "app"; };
    };
  }) [ "ns-app" ])

  (assertEq "the namespace-defining bundle gets no self-edge" (predsOf "ns-app" {
    bundles = {
      ns-app = b { resources.n = ns "app"; };
      workload = b { resources.d = workload "svc" "app"; };
    };
  }) [ ])

  (assertEq "a custom resource waits for whoever installs its CRD" (predsOf "issuer-cr" {
    bundles = {
      issuer-crd = b { resources.c = crd "cert-manager.io" "Issuer"; };
      issuer-cr = b { resources.r = cr "cert-manager.io" "Issuer" "primary" "cert-manager"; };
    };
  }) [ "issuer-crd" ])

  (assertEq "a bundle holding both the CRD and the CR gets no self-edge" (predsOf "both" {
    bundles = {
      both = b {
        resources = {
          c = crd "example.com" "Widget";
          r = cr "example.com" "Widget" "hello" "default";
        };
      };
    };
  }) [ ])

  # The failure this whole derivation exists to make impossible. Eleven floes
  # wrote the cert-manager edge by hand and four forgot; forgetting it now is
  # not expressible.
  (assertThrows "a custom resource nobody installs a CRD for is refused" (
    predsOf "issuer-cr" {
      bundles = {
        issuer-cr = b { resources.r = cr "cert-manager.io" "Issuer" "primary" "cert-manager"; };
      };
    }
  ))

  (assertEq "a CRD delivered opaquely is covered by saying so once" (predsOf "issuer-cr" {
    bundles = {
      # `yamls`, a chart: eval cannot see the kinds either way, so the
      # bundle names them.
      crds-from-a-chart = b { provides = [ "kind:cert-manager.io/Issuer" ]; };
      issuer-cr = b { resources.r = cr "cert-manager.io" "Issuer" "primary" "cert-manager"; };
    };
  }) [ "crds-from-a-chart" ])

  # `Cluster` is CloudNativePG's, Cluster API's and Crossplane's. Keyed on the
  # kind alone, a cnpg Cluster would have been satisfied by Cluster API.
  (assertEq "the API group qualifies the kind" (predsOf "db" {
    bundles = {
      capi = b { provides = [ "kind:cluster.x-k8s.io/Cluster" ]; };
      cnpg = b { provides = [ "kind:postgresql.cnpg.io/Cluster" ]; };
      db = b { resources.c = cr "postgresql.cnpg.io" "Cluster" "pg" "app"; };
    };
  }) [ "cnpg" ])

  (assertEq "a core kind needs no provider" (predsOf "workload" {
    bundles = {
      workload = b { resources.d = workload "svc" "app"; };
    };
  }) [ ])

  (assertEq "an ExternalSecret waits for its SecretStore" (predsOf "es" {
    bundles = {
      store = b { resources.s = secretStore "aws-store"; };
      es = b { resources.e = externalSecret "db-creds" "app" "aws-store"; };
    };
  }) [ "store" ])

  (assertEq "a ClusterSecretStore answers the same reference" (predsOf "es" {
    bundles = {
      cluster-store = b { resources.s = clusterSecretStore "sops-store"; };
      es = b { resources.e = externalSecret "app-creds" "prod" "sops-store"; };
    };
  }) [ "cluster-store" ])

  (assertEq "namespace and CRD share wave 0; the consumer lands in wave 1"
    (waveNamesOf {
      bundles = {
        ns-app = b { resources.n = ns "app"; };
        issuer-crd = b { resources.c = crd "cert-manager.io" "Issuer"; };
        my-issuer = b { resources.r = cr "cert-manager.io" "Issuer" "primary" "app"; };
      };
    })
    [
      [
        "issuer-crd"
        "ns-app"
      ]
      [ "my-issuer" ]
    ]
  )

  (assertEq "an authored edge survives alongside the derived ones"
    (predsOf "workload" {
      bundles = {
        ns-x = b { resources.n = ns "x"; };
        gate = b { provides = [ "something/else/ready" ]; };
        workload = b {
          after = [ "something/else/ready" ];
          resources.d = workload "app" "x";
        };
      };
    })
    [
      "gate"
      "ns-x"
    ]
  )

  # A namespace the cluster already had, kube-system say, is nobody's to
  # create. Refusing here would make every lab declare namespaces it does not
  # own.
  (assertEq "a namespace nothing in the lab creates is not an error" (predsOf "workload" {
    bundles = {
      workload = b { resources.d = workload "app" "no-such-ns"; };
    };
  }) [ ])

  (assertEq "createNamespaces routes through the aggregate bundle" (predsOf "apps/svc" {
    namespaceAggregate = "namespaces/_all";
    bundles = {
      "namespaces/_all" = b { };
      "apps/svc" = b {
        createNamespaces = [ "app" ];
        resources.d = workload "svc" "app";
      };
    };
  }) [ "namespaces/_all" ])

  # Two bundles listing the same namespace in `createNamespaces` must not end
  # up waiting on each other. Each providing it is what made that happen.
  (assertEq "co-creators of one namespace do not wait on each other"
    (waveNamesOf {
      namespaceAggregate = "namespaces/_all";
      bundles = {
        "namespaces/_all" = b { };
        a = b {
          createNamespaces = [ "shared" ];
          resources.d = workload "a" "shared";
        };
        b2 = b {
          createNamespaces = [ "shared" ];
          resources.d = workload "b" "shared";
        };
      };
    })
    [
      [ "namespaces/_all" ]
      [
        "a"
        "b2"
      ]
    ]
  )

  (assertEq "a bundle in another bundle's declared namespace gates on it" (predsOf "apps/svc" {
    namespaceAggregate = "namespaces/_all";
    bundles = {
      "namespaces/_all" = b { };
      "ns-owner" = b { createNamespaces = [ "app" ]; };
      "apps/svc" = b { resources.d = workload "svc" "app"; };
    };
  }) [ "namespaces/_all" ])

  (assertEq "an authored Namespace object outranks the aggregate" (predsOf "apps/svc" {
    namespaceAggregate = "namespaces/_all";
    bundles = {
      "namespaces/_all" = b { };
      "ns-app" = b { resources.n = ns "app"; };
      "apps/svc" = b { resources.d = workload "svc" "app"; };
    };
  }) [ "ns-app" ])

  (assertEq "a chart's namespace produces the same edge as a resource's" (predsOf "operators/chart" {
    namespaceAggregate = "namespaces/_all";
    bundles = {
      "namespaces/_all" = b { };
      "ops/thing" = b { createNamespaces = [ "ops" ]; };
      "operators/chart" = b { helmCharts.thing.namespace = "ops"; };
    };
  }) [ "namespaces/_all" ])

  (assertEq "every bundle answers its own bundle: name" (predsOf "user" {
    bundles = {
      target = b { };
      user = b { after = [ "bundle:target" ]; };
    };
  }) [ "target" ])

  (assertEq "a stamped bundle answers its floe: name"
    (predsOf "user" {
      bundles = {
        issuers = b { declaredBy = "cert-manager"; };
        webhook = b { declaredBy = "cert-manager"; };
        user = b { after = [ "floe:cert-manager" ]; };
      };
    })
    [
      "issuers"
      "webhook"
    ]
  )
]
