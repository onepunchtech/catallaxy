{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
  verifyTypes = import ../../../verify-types.nix { inherit lib; };
in
(mkFloe {
  name = "cert-manager";
  version = "v1.16.1";
  imports = [ ./options.nix ];
  exports =
    { lib, ... }:
    {

      namespace = lib.mkOption {
        type = lib.types.str;
        default = "cert-manager";
        description = "Namespace cert-manager runs in.";
      };
      defaultIssuerRef = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = ''
          Issuer reference for `Certificate.spec.issuerRef`. Precedence:
          intermediate > ACME > self-signed root. Empty attrset when
          no issuer is configured.
        '';
      };
      internalIssuerRef = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = ''
          Issuer reference for certs signing INTERNAL DNS names
          (`*.svc`, `*.svc.cluster.local`): admission-webhook TLS,
          in-cluster mTLS, etc. Precedence: intermediate > self-signed
          root. NEVER ACME (public CAs reject non-public SANs; that
          failure mode is silent-until-deploy). Empty attrset when the
          lab has no self-signed CA; consumers must assert on that.
        '';
      };
      caBundle = lib.mkOption {
        type = refs.nullableMountableRef;
        default = null;
        description = ''
          The lab CA bundle, as a ConfigMap consumers can mount.

          **Null means nothing will ever create it**; no self-signed
          CA, or no trust-manager to reconcile the Bundle CR into a
          ConfigMap. Mount it only when non-null; a volume naming a
          ConfigMap that does not exist keeps the pod out of `Running`
          for good, and the kubelet never gives up.

          Existence and ordering arrive together on purpose. Consumers
          used to answer "does this exist" themselves, by ANDing
          `floes.trust-manager.enable` with
          `floes.cert-manager.selfSignedCA.enable`: a predicate only
          this floe can compute, reconstructed in two others and wrong
          in both (2026-07-30).
        '';
      };
      caBundleSecret = lib.mkOption {
        type = refs.nullableMountableRef;
        default = null;
        description = ''
          Same bundle, same gating, as a Secret. For runtimes that read
          CAs only from Secret volumes (harbor's `caBundleSecret`, many
          Go apps) and cannot ingest a ConfigMap.
        '';
      };
      caBundleNamespaceLabel = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          "catallaxy.io/trust-bundle" = "true";
        };
        description = ''
          Namespace label that gates trust-bundle distribution.
          Apply on any namespace that needs the lab CA mounted.
        '';
      };
      issuance = lib.mkOption {
        type = refs.mkCapability {
          webhookReady = refs.tokenOption ''
            "The admission webhook will admit a Certificate." Anything
            emitting a Certificate CR puts this in its `requires`.

            Exported rather than left for consumers to spell out, so
            this floe can rename its own bundle tokens without silently
            breaking the thirteen bundles gating on this one.
          '';
          defaultIssuerReady = refs.tokenOption ''
            "`defaultIssuerRef` resolves to a ClusterIssuer that is
            Ready." Stronger than `webhookReady`: this one waits for an
            issuer that can actually sign.
          '';
          publicIssuer = lib.mkOption {
            type = lib.types.bool;
            description = ''
              Whether the default issuer is a public CA (ACME). Consumers
              use this to decide what they may put in a certificate:
              ACME rejects `*.svc.cluster.local` and other non-public
              suffixes, so a floe that wants an internal SAN must know.
            '';
          };
        };
        default = null;
        description = ''
          X.509 issuance, or null when this floe is off. Consumers assert
          on this rather than on `floes.cert-manager.enable`: the
          question is "can I get a certificate", which is ours to answer.
        '';
      };
    };
  module =
    {
      lib,
      cfg,
      peers,
      cataCharts,
      ...
    }:
    let

      defaultIssuerRef =
        if cfg.acme.enable then
          {
            name = cfg.acme.issuerName;
            kind = "ClusterIssuer";
          }
        else if cfg.selfSignedCA.enable && cfg.selfSignedCA.intermediate.enable then
          {
            name = cfg.selfSignedCA.intermediate.issuerName;
            kind = "ClusterIssuer";
          }
        else if cfg.selfSignedCA.enable then
          {
            name = cfg.selfSignedCA.issuerName;
            kind = "ClusterIssuer";
          }
        else
          { };

      internalIssuerRef =
        if cfg.selfSignedCA.enable && cfg.selfSignedCA.intermediate.enable then
          {
            name = cfg.selfSignedCA.intermediate.issuerName;
            kind = "ClusterIssuer";
          }
        else if cfg.selfSignedCA.enable then
          {
            name = cfg.selfSignedCA.issuerName;
            kind = "ClusterIssuer";
          }
        else
          { };

      webhookReadyToken = "cert-manager/webhook/ready";
      defaultIssuerReadyToken = "cert-manager/default-issuer/ready";

      bundleDistribution = peers.trust-manager.bundleDistribution;
      distributesCaBundle = cfg.selfSignedCA.enable && bundleDistribution != null;
    in
    {
      floes.cert-manager.verify.issuers-ready = {
        description = "Every ClusterIssuer is Ready, so certificates can actually be signed";
        reject = [
          {
            apiVersion = "cert-manager.io/v1";
            kind = "ClusterIssuer";
            ${verifyTypes.conditionIsNot { type = "Ready"; }} = true;
          }
        ];
      };

      floes.cert-manager.exports = {
        inherit (cfg) namespace;
        inherit defaultIssuerRef;
        inherit internalIssuerRef;

        caBundle =
          if distributesCaBundle then
            {
              name = "lab-ca-bundle";
              key = "ca.crt";
              readyToken = defaultIssuerReadyToken;

              readyProbe = {
                kind = "exists";
                resource = "configmap/lab-ca-bundle";
                namespace = cfg.namespace;
                timeout = "5m";
              };
            }
          else
            null;
        caBundleSecret =
          if distributesCaBundle then
            {
              name = "lab-ca-bundle-secret";
              key = "ca.crt";
              readyToken = defaultIssuerReadyToken;
              readyProbe = {
                kind = "exists";
                resource = "secret/lab-ca-bundle-secret";
                namespace = cfg.namespace;
                timeout = "5m";
              };
            }
          else
            null;
        caBundleNamespaceLabel = {
          "catallaxy.io/trust-bundle" = "true";
        };
        issuance = {
          webhookReady = webhookReadyToken;
          defaultIssuerReady = defaultIssuerReadyToken;
          publicIssuer = cfg.acme.enable;
        };
      };

      assertions = [
        {
          assertion =
            !(cfg.selfSignedCA.enable && cfg.selfSignedCA.intermediate.enable) || bundleDistribution != null;
          message = ''
            cert-manager 2-tier PKI (selfSignedCA.intermediate.enable = true)
            requires trust-manager to distribute the root CA bundle.
            Enable `floes.trust-manager.enable = true` or turn the
            intermediate off.
          '';
        }
      ];

      floes.cert-manager.network = {

        declared = true;

        serves.webhook = {

          port = 443;

          fromApiServer = true;

        };

        egress.internet.ports = [ 443 ];

      };

      floes.cert-manager.imagesComplete = true;

      floes.cert-manager.images.controller = {

        registry = "quay.io";

        repository = "jetstack/cert-manager-controller";

        tag = "v1.17.2";

      };

      floes.cert-manager.images.cainjector = {

        registry = "quay.io";

        repository = "jetstack/cert-manager-cainjector";

        tag = "v1.17.2";

      };

      floes.cert-manager.images.webhook = {

        registry = "quay.io";

        repository = "jetstack/cert-manager-webhook";

        tag = "v1.17.2";

      };

      bundles.cert-manager-crds = {
        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        yamls = [ cataCharts.cert-manager.crds ];

        provides = [ "cert-manager/crds/established" ];
      };

      bundles.cert-manager = {

        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        helmCharts.cert-manager = {
          chart = cfg.chart;
          releaseName = "cert-manager";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            installCRDs = false;
          };
        };
        createNamespaces = [ cfg.namespace ];

        requires = [ "cert-manager/crds/established" ];
        provides = [ webhookReadyToken ];

        readyProbe = {
          kind = "condition";
          resource = "deployment/cert-manager-webhook";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };

      bundles.cert-manager-issuers.owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };

      bundles.cert-manager-issuers.requires = [
        webhookReadyToken
      ]

      ++ lib.optional distributesCaBundle bundleDistribution.readyToken;
      bundles.cert-manager-issuers.provides = [
        defaultIssuerReadyToken
      ];
      bundles.cert-manager-issuers.readyProbe = {
        kind = "condition";
        resource = "clusterissuer/${defaultIssuerRef.name}";
        namespace = cfg.namespace;
        condition = "Ready";
        timeout = "3m";
      };
      bundles.cert-manager-issuers.resources =
        let

          rootIssuer = lib.optionalAttrs (cfg.selfSignedCA.enable && !cfg.selfSignedCA.intermediate.enable) {
            "${cfg.selfSignedCA.issuerName}" = {
              apiVersion = "cert-manager.io/v1";
              kind = "ClusterIssuer";
              metadata.name = cfg.selfSignedCA.issuerName;
              spec.ca.secretName = "${cfg.selfSignedCA.issuerName}-ca-secret";
            };
          };

          intermediateIssuer =
            lib.optionalAttrs (cfg.selfSignedCA.enable && cfg.selfSignedCA.intermediate.enable)
              {
                "${cfg.selfSignedCA.intermediate.issuerName}" = {
                  apiVersion = "cert-manager.io/v1";
                  kind = "ClusterIssuer";
                  metadata.name = cfg.selfSignedCA.intermediate.issuerName;
                  spec.ca.secretName = cfg.selfSignedCA.intermediate.secretName;
                };
              };

          trustBundle = lib.optionalAttrs distributesCaBundle {
            "lab-ca-bundle" = {
              apiVersion = "trust.cert-manager.io/v1alpha1";
              kind = "Bundle";
              metadata.name = "lab-ca-bundle";
              spec = {
                sources = [
                  {
                    secret = {
                      name = "${cfg.selfSignedCA.issuerName}-ca-secret";
                      key = "tls.crt";
                    };
                  }
                ];
                target = {
                  configMap = {
                    key = "ca.crt";
                  };
                  namespaceSelector = { };
                };
              };
            };

            "lab-ca-bundle-secret" = {
              apiVersion = "trust.cert-manager.io/v1alpha1";
              kind = "Bundle";
              metadata.name = "lab-ca-bundle-secret";
              spec = {
                sources = [
                  {
                    secret = {
                      name = "${cfg.selfSignedCA.issuerName}-ca-secret";
                      key = "tls.crt";
                    };
                  }
                ];
                target = {
                  secret = {
                    key = "ca.crt";
                  };
                  namespaceSelector = { };
                };
              };
            };
          };

          acmeResources =
            let
              dns01Cfg = cfg.acme.dns01;

              cloudflareSolver = [
                {
                  dns01.cloudflare = {
                    apiTokenSecretRef = {
                      name = dns01Cfg.cloudflare.apiTokenSecretName;
                      key = "api-token";
                    };
                  };
                }
              ];

              route53Solver = [
                {
                  dns01.route53 = {
                    region = dns01Cfg.route53.region;
                  }
                  // lib.optionalAttrs (dns01Cfg.route53.hostedZoneID != "") {
                    hostedZoneID = dns01Cfg.route53.hostedZoneID;
                  }
                  // lib.optionalAttrs (dns01Cfg.route53.accessKeyID != "") {
                    accessKeyID = dns01Cfg.route53.accessKeyID;
                    secretAccessKeySecretRef = {
                      name = dns01Cfg.route53.secretAccessKeySecretName;
                      key = "secret-access-key";
                    };
                  };
                }
              ];

              effectiveSolvers =
                if cfg.acme.solvers != [ ] then
                  cfg.acme.solvers
                else if dns01Cfg.provider == "cloudflare" then
                  cloudflareSolver
                else if dns01Cfg.provider == "route53" then
                  route53Solver
                else
                  [ ];
            in
            lib.optionalAttrs cfg.acme.enable (
              {
                "${cfg.acme.issuerName}" = {
                  apiVersion = "cert-manager.io/v1";
                  kind = "ClusterIssuer";
                  metadata.name = cfg.acme.issuerName;
                  spec.acme = {
                    email = cfg.acme.email;
                    server = cfg.acme.server;
                    privateKeySecretRef.name = "${cfg.acme.issuerName}-account-key";
                    solvers = effectiveSolvers;
                  };
                };
              }
              // lib.optionalAttrs (dns01Cfg.provider == "cloudflare" && dns01Cfg.cloudflare.apiToken != null) {
                "${dns01Cfg.cloudflare.apiTokenSecretName}" = {
                  apiVersion = "v1";
                  kind = "Secret";
                  metadata = {
                    name = dns01Cfg.cloudflare.apiTokenSecretName;
                    namespace = cfg.namespace;
                  };
                  type = "Opaque";
                  stringData = {
                    "api-token" = dns01Cfg.cloudflare.apiToken;
                  };
                };
              }
              // lib.optionalAttrs (dns01Cfg.provider == "route53" && dns01Cfg.route53.secretAccessKey != null) {
                "${dns01Cfg.route53.secretAccessKeySecretName}" = {
                  apiVersion = "v1";
                  kind = "Secret";
                  metadata = {
                    name = dns01Cfg.route53.secretAccessKeySecretName;
                    namespace = cfg.namespace;
                  };
                  type = "Opaque";
                  stringData = {
                    "secret-access-key" = dns01Cfg.route53.secretAccessKey;
                  };
                };
              }
            );
        in
        rootIssuer // intermediateIssuer // trustBundle // acmeResources;
    };
})
  __floeModuleArgs
