{
  lib,
  pkgs,
  mkLab,
}:

let
  labWith =
    resource:
    builtins.tryEval (
      let
        result = mkLab {
          modules = [
            {
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
                  bundles.t.resources.r = resource;
                };
            }
          ];
        };
      in
      builtins.deepSeq result.config.lab.clusters.app.bundles.t.resources.r.spec "evaluated"
    );

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
    ++ lib.optional wrongTypeInOtherCrd.success "spec.dnsNames as a bare string should fail evaluation, but the Certificate evaluated";
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
