{ lib }:

let
  autoedges = import ../eval/manifest-autoedges.nix { inherit lib; };
  graph = import ../eval/manifest-graph.nix { inherit lib; };
  inherit (autoedges) deriveAutoEdges;
  inherit (graph) computeWaves;

  b =
    attrs:
    {
      after = [ ];
      requires = [ ];
      provides = [ ];
      resources = { };
    }
    // attrs;

  ns = name: {
    kind = "Namespace";
    apiVersion = "v1";
    metadata.name = name;
  };
  crd = kind: {
    kind = "CustomResourceDefinition";
    apiVersion = "apiextensions.k8s.io/v1";
    metadata.name = "${kind}s.example.com";
    spec.names.kind = kind;
  };
  cr = kind: name: namespace: {
    inherit kind;
    apiVersion = "example.com/v1";
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

  sortedAfter = bundleName: augmented: lib.sort (a: b: a < b) augmented.${bundleName}.after;

  waveNamesOf =
    augmented:
    map (wave: map (b: b.name) wave) (computeWaves {
      bundles = lib.mapAttrs (
        n: b:
        b
        // {
          kind = null;
          floe = null;
        }
      ) augmented;
    });

in
lib.concatLists [

  (
    let
      augmented = deriveAutoEdges {
        bundles = {
          ns-app = b { resources.n = ns "app"; };
          workload = b { resources.d = workload "svc" "app"; };
        };
      };
    in
    assertEq "workload gets `bundle:ns-*` after its own namespace" (sortedAfter "workload" augmented) [
      "bundle:ns-app"
    ]
  )

  (
    let
      augmented = deriveAutoEdges {
        bundles = {
          ns-app = b { resources.n = ns "app"; };
          workload = b { resources.d = workload "svc" "app"; };
        };
      };
    in
    assertEq "namespace-defining bundle gets NO self-edge" (sortedAfter "ns-app" augmented) [ ]
  )

  (
    let
      augmented = deriveAutoEdges {
        bundles = {
          issuer-crd = b { resources.c = crd "Issuer"; };
          issuer-cr = b { resources.r = cr "Issuer" "default-issuer" "cert-manager"; };
        };
      };
    in
    assertEq "CR gets `bundle:*` after its CRD" (sortedAfter "issuer-cr" augmented) [
      "bundle:issuer-crd"
    ]
  )

  (
    let
      augmented = deriveAutoEdges {
        bundles = {

          both = b {
            resources = {
              c = crd "Widget";
              r = cr "Widget" "hello" "default";
            };
          };
        };
      };
    in
    assertEq "CR self-edge to same-bundle CRD is filtered" (sortedAfter "both" augmented) [ ]
  )

  (
    let
      augmented = deriveAutoEdges {
        bundles = {
          store = b { resources.s = secretStore "aws-store"; };
          es = b { resources.e = externalSecret "db-creds" "app" "aws-store"; };
        };
      };
    in
    assertEq "ExternalSecret gets `bundle:*` after its SecretStore" (sortedAfter "es" augmented) [
      "bundle:store"
    ]
  )

  (
    let
      augmented = deriveAutoEdges {
        bundles = {
          cluster-store = b { resources.s = clusterSecretStore "sops-store"; };
          es = b { resources.e = externalSecret "app-creds" "prod" "sops-store"; };
        };
      };
    in
    assertEq "ExternalSecret → ClusterSecretStore also matched" (sortedAfter "es" augmented) [
      "bundle:cluster-store"
    ]
  )

  (
    let
      augmented = deriveAutoEdges {
        bundles = {
          ns-app = b { resources.n = ns "app"; };
          issuer-crd = b { resources.c = crd "Issuer"; };

          my-issuer = b { resources.r = cr "Issuer" "primary" "app"; };
        };
      };
      wavesLists = waveNamesOf augmented;
    in
    assertEq "namespace + CRD form wave 0; CR consumer lands in wave 1" wavesLists [
      [
        "issuer-crd"
        "ns-app"
      ]
      [ "my-issuer" ]
    ]
  )

  (
    let
      augmented = deriveAutoEdges {
        bundles = {
          ns-x = b { resources.n = ns "x"; };
          workload = b {
            after = [ "kind:CustomKind" ];
            resources.d = workload "app" "x";
          };
        };
      };
    in
    assertEq "author `after` is unioned with auto-edges" (sortedAfter "workload" augmented) [
      "bundle:ns-x"
      "kind:CustomKind"
    ]
  )

  (
    let
      augmented = deriveAutoEdges {
        bundles = {
          workload = b { resources.d = workload "app" "no-such-ns"; };
        };
      };
    in
    assertEq "orphan namespace reference does not fabricate an edge" (sortedAfter "workload" augmented)
      [ ]
  )

  (
    let
      augmented = deriveAutoEdges {
        namespaceAggregate = "namespaces/_all";
        bundles = {
          "namespaces/_all" = b { };
          "apps/svc" = b {
            createNamespaces = [ "app" ];
            resources.d = workload "svc" "app";
          };
        };
      };
    in
    assertEq "createNamespaces consumer gates on the aggregate bundle"
      (sortedAfter "apps/svc" augmented)
      [ "bundle:namespaces/_all" ]
  )

  (
    let
      augmented = deriveAutoEdges {
        namespaceAggregate = "namespaces/_all";
        bundles = {
          "namespaces/_all" = b { };
          "ns-owner" = b { createNamespaces = [ "app" ]; };

          "apps/svc" = b { resources.d = workload "svc" "app"; };
        };
      };
    in
    assertEq "a namespace declared by one bundle gates consumers in another"
      (sortedAfter "apps/svc" augmented)
      [ "bundle:namespaces/_all" ]
  )

  (
    let
      augmented = deriveAutoEdges {
        bundles = {
          "namespaces/_all" = b { };
          "apps/svc" = b { resources.d = workload "svc" "app"; };
        };
      };
    in
    assertEq "without namespaceAggregate, createNamespaces namespaces have no provider"
      (sortedAfter "apps/svc" augmented)
      [ ]
  )

  (
    let
      augmented = deriveAutoEdges {
        namespaceAggregate = "namespaces/_all";
        bundles = {
          "namespaces/_all" = b { };
          "ns-app" = b { resources.n = ns "app"; };
          "apps/svc" = b { resources.d = workload "svc" "app"; };
        };
      };
    in
    assertEq "authored Namespace resource wins over the aggregate" (sortedAfter "apps/svc" augmented) [
      "bundle:ns-app"
    ]
  )

  (
    let
      augmented = deriveAutoEdges {
        namespaceAggregate = "namespaces/_all";
        bundles = {
          "namespaces/_all" = b { };
          "ops/thing" = b {
            createNamespaces = [ "ops" ];
          };
          "operators/chart" = b {
            helmCharts.thing = {
              namespace = "ops";
            };
          };
        };
      };
    in
    assertEq "helm chart namespace produces a namespace edge" (sortedAfter "operators/chart" augmented)
      [ "bundle:namespaces/_all" ]
  )
]
