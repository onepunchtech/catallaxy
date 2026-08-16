{ lib }:

let
  # Two clusters: `core` publishes, `obs` subscribes. The whole point of the
  # design is that neither reads the other's output, so these tests evaluate a
  # real two-cluster lab and assert on what each side rendered.
  evalLab =
    {
      core ? { },
      obs ? { },
      stores ? null,
    }:
    (lib.evalModules {
      modules = [
        ../../modules/lab
        {
          lab.name = "t";
          lab.dns.zone = "t.test";
          lab.secrets.stores =
            if stores != null then
              stores
            else
              {
                runtime = {
                  backend = "vault";
                  vault.server = "https://vault.t.test";
                };
              };
          lab.clusters.core = core;
          lab.clusters.obs = obs;
        }
      ];
    }).config;

  publishHarbor = {
    floes.external-secrets.enable = true;
    secrets.publish.harbor-puller = {
      namespace = "harbor";
      secret = "harbor-obs-puller";
    };
  };

  subscribeHarbor = {
    floes.external-secrets.enable = true;
    secrets.subscribe.harbor-puller = {
      from = "core";
      namespace = "default";
      secret = "harbor-pull";
    };
  };

  resourcesOf =
    cfg: cluster: bundle:
    (cfg.lab.clusters.${cluster}.bundles.${bundle} or { }).resources or { };

  failures =
    cfg: cluster:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (cfg.lab.clusters.${cluster}.assertions or [ ])
    );

  # An assertion fires iff its message appears. Comparing on a distinctive
  # fragment keeps these from passing on some unrelated failure.
  saysAny = msgs: fragment: builtins.any (m: lib.hasInfix fragment m) msgs;

  check =
    name: expected: actual:
    lib.optional (expected != actual) {
      inherit name expected actual;
    };
in
lib.concatLists [

  (
    let
      cfg = evalLab {
        core = publishHarbor;
        obs = subscribeHarbor;
      };
      push = (resourcesOf cfg "core" "secret-publications").push-harbor-puller;
      ext = (resourcesOf cfg "obs" "secret-subscriptions").subscribe-harbor-puller;
    in
    lib.concatLists [

      (check "a healthy pair asserts nothing on either side"
        [
          [ ]
          [ ]
        ]
        [
          (failures cfg "core")
          (failures cfg "obs")
        ]
      )

      # The crux: both sides compute the same address from the producer's
      # identity, without either reading the other's output.
      (check "publisher and subscriber agree on the address, unprompted" "t/core/harbor/harbor-obs-puller"
        (
          let
            pushed = (builtins.head push.spec.data).match.remoteRef.remoteKey;
            pulled = (builtins.head ext.spec.dataFrom).extract.key;
          in
          if pushed == pulled then pushed else "push=${pushed} pull=${pulled}"
        )
      )

      (check "the address names the producing cluster, not the consuming one" true (
        lib.hasInfix "/core/" (builtins.head ext.spec.dataFrom).extract.key
      ))

      # The generated schemas default every declared field, so the attribute
      # is always present. Absence is null, not a missing key.
      (check "publishing no named keys pushes the Secret whole" null (
        (builtins.head push.spec.data).match.secretKey
      ))

      (check "the publisher selects its own local Secret" "harbor-obs-puller"
        push.spec.selector.secret.name
      )

      (check "the subscriber materialises under its own chosen name" "harbor-pull" ext.spec.target.name)

      (check "both reference the same generated store"
        [ "catallaxy-runtime" "catallaxy-runtime" ]
        [
          (builtins.head push.spec.secretStoreRefs).name
          ext.spec.secretStoreRef.name
        ]
      )

      (check "a store is rendered where it is used" "ClusterSecretStore" (
        (resourcesOf cfg "obs" "secret-stores").secret-store-runtime.kind
      ))

      (check "the store dials what the lab declared" "https://vault.t.test" (
        (resourcesOf cfg "core" "secret-stores").secret-store-runtime.spec.provider.vault.server
      ))

      # PushSecret gets no automatic edge to its store, so the bundle has to
      # say so itself. If this regresses, a publication can apply first and
      # fail admission.
      (check "the publication bundle orders itself after the store" true (
        builtins.elem "secrets/stores/ready" cfg.lab.clusters.core.bundles.secret-publications.requires
      ))

      (check "a subscription provides its Secret so consumers can order on it" [
        "secret:default/harbor-pull"
      ] cfg.lab.clusters.obs.bundles.secret-subscriptions.provides)
    ]
  )

  # A cluster that does neither renders nothing at all.
  (
    let
      cfg = evalLab { };
    in
    check "a cluster that shares nothing gets no external-secrets resources" [ ] (
      builtins.attrNames (
        lib.filterAttrs (n: _: lib.hasPrefix "secret-" n) (cfg.lab.clusters.core.bundles or { })
      )
    )
  )

  # The contract is checked at build time. Each of these would otherwise be an
  # ExternalSecret waiting forever.
  (
    let
      cfg = evalLab {
        core = { };
        obs = subscribeHarbor;
      };
    in
    check "subscribing to something nobody publishes fails the build" true (
      saysAny (failures cfg "obs") "does not publish"
    )
  )

  (
    let
      cfg = evalLab {
        core = publishHarbor;
        obs = {
          floes.external-secrets.enable = true;
          secrets.subscribe.harbor-puller = {
            from = "nowhere";
            namespace = "default";
          };
        };
      };
    in
    check "subscribing from a cluster that does not exist fails the build" true (
      saysAny (failures cfg "obs") "cluster in this lab"
    )
  )

  (
    let
      cfg = evalLab {
        core.floes.external-secrets.enable = true;
        core.secrets.publish.harbor-puller = {
          namespace = "harbor";
          secret = "harbor-obs-puller";
          store = "sopsy";
        };
        stores = {
          sopsy.backend = "sops";
          runtime = {
            backend = "vault";
            vault.server = "https://vault.t.test";
          };
        };
      };
    in
    check "publishing into an authored store fails the build" true (
      saysAny (failures cfg "core") "authored"
    )
  )

  (
    let
      cfg = evalLab {
        core = publishHarbor;
        stores.runtime.backend = "external";
      };
    in
    check "a runtime store with no server address fails the build" true (
      saysAny (failures cfg "core") "vault.server"
    )
  )

  (
    let
      cfg = evalLab {
        core.secrets.publish.harbor-puller = {
          namespace = "harbor";
          secret = "harbor-obs-puller";
        };
      };
    in
    check "sharing without the controller that reconciles it fails the build" true (
      saysAny (failures cfg "core") "external-secrets.enable"
    )
  )

  # An in-cluster address resolves only where the store runs, so the moment a
  # second cluster reads it the ExternalSecret would wait on a name it cannot
  # reach. Caught at build time rather than in a pod that never becomes ready.
  (
    let
      cfg = evalLab {
        core = publishHarbor;
        obs = subscribeHarbor;
        stores.runtime = {
          backend = "vault";
          vault.server = "http://openbao.openbao.svc.cluster.local:8200";
        };
      };
    in
    check "an in-cluster store address is refused once two clusters use it" true (
      saysAny (failures cfg "core") "in-cluster DNS name"
    )
  )

  (
    let
      cfg = evalLab {
        core = publishHarbor;
        stores.runtime = {
          backend = "vault";
          vault.server = "http://openbao.openbao.svc.cluster.local:8200";
        };
      };
    in
    check "one cluster alone may use an in-cluster address" [ ] (failures cfg "core")
  )
]
