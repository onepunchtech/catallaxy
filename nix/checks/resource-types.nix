{
  lib,
  pkgs,
  labForce,
  labRefusal,
}:

let
  labFixture = unchecked: resource: {
    lab.name = "typed-fixture";
    lab.environment = "development";
    lab.dns.enable = false;
    lab.registry.enable = false;
    lab.proxy.enable = false;
    lab.clusters.app =
      { lab, ... }:
      {
        cluster.name = "app";
        cluster.provisioner = "k3d";
        provisioner.k3d.network = lab.name;
        cluster.kubernetes.uncheckedResources = unchecked;
        bundles.t.declaredBy = "cluster";
        bundles.t.resources.r = resource;
      };
  };

  labAllowing =
    unchecked: resource:
    labForce {
      force = config: config.lab.clusters.app.bundles.t.resources.r.spec;
      modules = [ (labFixture unchecked resource) ];
    };

  labWith = labAllowing [ ];

  deployment = spec: {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata.name = "x";
    inherit spec;
  };

  workload = {
    selector.matchLabels.app = "x";
    template = {
      metadata.labels.app = "x";
      spec.containers = [
        {
          name = "c";
          image = "nginx:1.27-alpine";
        }
      ];
    };
  };

  valid = labWith (deployment workload);

  wrongType = labWith (deployment (workload // { replicas = "three"; }));

  # Everything above is `apps/v1`, which comes from the k8s schemas. The CRD
  # schemas are a separate 200k lines loaded by a separate function, and a
  # Deployment passing says nothing about whether they are wired at all.
  externalSecret = spec: {
    apiVersion = "external-secrets.io/v1beta1";
    kind = "ExternalSecret";
    metadata.name = "x";
    inherit spec;
  };

  subscription = {
    refreshInterval = "1h";
    secretStoreRef = {
      name = "runtime";
      kind = "ClusterSecretStore";
    };
    target.name = "x";
  };

  validCrd = labWith (externalSecret subscription);

  wrongTypeInCrd = labWith (
    externalSecret (
      subscription
      // {
        target = subscription.target // {
          immutable = "yes";
        };
      }
    )
  );

  # A kind whose schema is wired but that is not one of the two above, so a
  # check that happens to special-case ExternalSecret does not pass either.
  otherCrd = labWith {
    apiVersion = "cert-manager.io/v1";
    kind = "Certificate";
    metadata.name = "x";
    spec = {
      secretName = "x-tls";
      issuerRef = {
        name = "lab-ca";
        kind = "ClusterIssuer";
      };
      dnsNames = [ "x.local" ];
    };
  };

  wrongTypeInOtherCrd = labWith {
    apiVersion = "cert-manager.io/v1";
    kind = "Certificate";
    metadata.name = "x";
    spec = {
      secretName = "x-tls";
      issuerRef = {
        name = "lab-ca";
        kind = "ClusterIssuer";
      };
      dnsNames = "x.local";
    };
  };

  # Gateway API ships as raw CRD YAML rather than through a chart, so it loads
  # by a third route again. Its kinds evaluated untyped until the generator was
  # run over the standalone bundle.
  httpRoute = rules: {
    apiVersion = "gateway.networking.k8s.io/v1";
    kind = "HTTPRoute";
    metadata.name = "x";
    spec = {
      parentRefs = [ { name = "public"; } ];
      hostnames = [ "x.local" ];
      inherit rules;
    };
  };

  backend = [
    {
      backendRefs = [
        {
          name = "svc";
          port = 8080;
        }
      ];
    }
  ];

  validGatewayCrd = labWith (httpRoute backend);

  wrongTypeInGatewayCrd = labWith (httpRoute [
    {
      backendRefs = [
        {
          name = "svc";
          port = "8080";
        }
      ];
    }
  ]);

  # A kind alone does not pick a schema. Sixteen kinds in this tree are
  # declared under more than one apiVersion: `HorizontalPodAutoscaler` in
  # autoscaling/v1 and v2, `Backup` in velero's group and CloudNativePG's,
  # `Cluster` in CloudNativePG's, Cluster API's and Crossplane's. Resolving on
  # kind alone silently picked whichever the fold happened to visit last.
  hpa = apiVersion: spec: {
    inherit apiVersion;
    kind = "HorizontalPodAutoscaler";
    metadata.name = "x";
    scaleTargetRef = {
      kind = "Deployment";
      name = "x";
    };
    inherit spec;
  };

  hpaV1Only = labWith (
    hpa "autoscaling/v1" {
      scaleTargetRef = {
        kind = "Deployment";
        name = "x";
      };
      maxReplicas = 3;
      targetCPUUtilizationPercentage = 50;
    }
  );

  hpaV2RejectsAV1Shape = labWith (
    hpa "autoscaling/v2" {
      scaleTargetRef = {
        kind = "Deployment";
        name = "x";
      };
      maxReplicas = 3;
      metrics = "cpu";
    }
  );

  cnpgCluster = labWith {
    apiVersion = "postgresql.cnpg.io/v1";
    kind = "Cluster";
    metadata.name = "x";
    spec.instances = "three";
  };

  # A kind the tree has schemas for, under an apiVersion it does not. That is
  # a resource which reads as validated and is not, so it is refused unless
  # the pair is named. Crossplane's Cluster is the real instance: its CRDs
  # arrive at runtime through the provider, so the schema is never in tree.
  crossplaneClusterPair = "kubernetes.digitalocean.crossplane.io/v1alpha1/Cluster";

  crossplaneCluster = {
    apiVersion = "kubernetes.digitalocean.crossplane.io/v1alpha1";
    kind = "Cluster";
    metadata.name = "x";
    spec.instances = "three";
  };

  uncheckedPairRefusals = labRefusal { modules = [ (labFixture [ ] crossplaneCluster) ]; };

  uncheckedPairIsAllowedWhenNamed = labAllowing [ crossplaneClusterPair ] crossplaneCluster;

  unknownKind = labWith {
    apiVersion = "example.com/v1";
    kind = "SomethingNoSchemaKnows";
    metadata.name = "x";
    spec.anything = {
      shape = "arbitrary";
    };
  };

  failures =
    lib.optional (!valid.success) "a well-formed Deployment should evaluate, but it threw"
    ++ lib.optional wrongType.success "spec.replicas = \"three\" should fail evaluation, but the Deployment evaluated"
    ++ lib.optional (
      !unknownKind.success
    ) "a kind outside the generated schemas should still evaluate, but it threw"
    ++ lib.optional (!validCrd.success) "a well-formed ExternalSecret should evaluate, but it threw"
    ++ lib.optional wrongTypeInCrd.success "spec.target.immutable = \"yes\" should fail evaluation, but the ExternalSecret evaluated"
    ++ lib.optional (!otherCrd.success) "a well-formed Certificate should evaluate, but it threw"
    ++ lib.optional wrongTypeInOtherCrd.success "spec.dnsNames as a bare string should fail evaluation, but the Certificate evaluated"
    ++ lib.optional (!validGatewayCrd.success) "a well-formed HTTPRoute should evaluate, but it threw"
    ++ lib.optional wrongTypeInGatewayCrd.success "a backendRef port of \"8080\" should fail evaluation, but the HTTPRoute evaluated"
    ++ lib.optional (
      !hpaV1Only.success
    ) "an autoscaling/v1 HorizontalPodAutoscaler should evaluate against the v1 schema, but it threw"
    ++ lib.optional hpaV2RejectsAV1Shape.success "spec.metrics = \"cpu\" should fail evaluation, but the autoscaling/v2 HorizontalPodAutoscaler evaluated"
    ++ lib.optional cnpgCluster.success "spec.instances = \"three\" should fail evaluation, but the CloudNativePG Cluster evaluated"
    ++
      lib.optional
        (
          uncheckedPairRefusals == null
          || !(lib.any (
            m: lib.hasInfix "The schemas in this tree know that kind only as" m
          ) uncheckedPairRefusals)
        )
        "a kind with schemas but not for its apiVersion should be refused by an assertion saying so, but it was not"
    ++
      lib.optional (!uncheckedPairIsAllowedWhenNamed.success)
        "naming the pair in `cluster.kubernetes.uncheckedResources` should let it through, but it still threw";
in
{
  resource-types-are-applied = pkgs.runCommand "resource-types-are-applied" { } (
    if failures == [ ] then
      ''
        echo "generated Kubernetes types validate typed resources" > $out
      ''
    else
      ''
        cat >&2 <<'EOF'
        The generated Kubernetes types are not doing what they should.

        modules/lab/cluster/lib/kubernetes/types.nix resolves a resource's
        `kind` against the generated K8s and CRD types and uses that type for
        `spec`. If that wiring is removed the 41MB of committed schema goes
        back to validating nothing, which is how it sat before: `kindType`
        was computed and never referenced.

        The CRD schemas load through a different path than the core ones, so
        both are exercised here. A Deployment passing says nothing about
        whether generated/index.nix wired a single CRD.

        ${lib.concatStringsSep "\n" (map (f: "  - ${f}") failures)}
        EOF
        exit 1
      ''
  );
}
