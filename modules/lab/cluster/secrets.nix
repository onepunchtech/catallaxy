{
  config,
  lib,
  lab,
  ...
}:

let
  inherit (lib) mkOption types;
  projectionsLib = import ../../../lib/eval/manifest-projections.nix { inherit lib; };

  projectionKeyType = types.submodule {
    options = {
      from = mkOption {
        type = types.str;
        description = "Source key name in the managed secret";
      };

      transform = mkOption {
        type = types.enum [
          "none"
          "base64"
          "json-wrap"
        ];
        default = "none";
        description = ''
          Transform to apply when projecting:
          - none: passthrough
          - base64: base64-encode the value
          - json-wrap: wrap as JSON object {"<jsonKey>": "<value>"}
        '';
      };

      jsonKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "JSON key name for json-wrap transform (defaults to the projection key name)";
      };
    };
  };

  projectionType = types.submodule (
    { name, config, ... }:
    {
      options = {
        source = mkOption {
          type = types.str;
          description = "Name of the lab-level managed secret (lab.secrets.managed.<name>)";
        };

        namespace = mkOption {
          type = types.str;
          default = "default";
          description = "Kubernetes namespace for the projected Secret";
        };

        keys = mkOption {
          type = types.attrsOf projectionKeyType;
          default = { };
          description = "Key mappings from source managed secret to K8s Secret keys";
        };

        ref = mkOption {
          type = types.attrs;
          readOnly = true;
          description = "Computed references for this projected secret";
        };
      };

      config.ref = {
        inherit name;
        inherit (config) namespace;
        secretRef = { inherit name; };
        envFrom = {
          secretRef = { inherit name; };
        };
        volume = {
          secret.secretName = name;
        };
      };
    }
  );

  projectionAssertions = lib.concatLists (
    lib.mapAttrsToList (
      projName: proj:
      let
        managedSecret = lab.secrets.managed.${proj.source} or null;
        managedSecretKeys = if managedSecret != null then builtins.attrNames managedSecret.keys else [ ];
      in
      [
        {
          assertion = managedSecret != null;
          message = "Projection '${projName}' references managed secret '${proj.source}' which does not exist in lab.secrets.managed";
        }
      ]
      ++ lib.mapAttrsToList (keyName: keyDef: {
        assertion = managedSecret == null || builtins.elem keyDef.from managedSecretKeys;
        message = "Projection '${projName}' key '${keyName}' references source key '${keyDef.from}' which does not exist in managed secret '${proj.source}'. Available keys: ${builtins.concatStringsSep ", " managedSecretKeys}";
      }) proj.keys
    ) config.secrets.projections
  );

  projectionPhaseAssertions =
    let
      waves = config.cluster.out.manifestWaves;
      waveIndex = lib.foldl' (
        acc: idx:
        acc
        // (lib.listToAttrs (
          map (b: {
            name = b.name;
            value = idx;
          }) (builtins.elemAt waves idx)
        ))
      ) { } (lib.genList (i: i) (builtins.length waves));
    in
    lib.concatLists (
      lib.mapAttrsToList (
        projName: proj:
        let
          projKey = "projection/${projName}";
          projWave = waveIndex.${projKey} or null;

          consumers = lib.concatLists (
            lib.mapAttrsToList (
              bundleName: bundle:
              let
                consumerWave = waveIndex.${bundleName} or null;
              in
              lib.filter (r: r != null) (
                lib.mapAttrsToList (
                  resName: res:
                  if
                    builtins.elem projName (
                      projectionsLib.consumedProjections {
                        bundle = {
                          resources.${resName} = res;
                        };
                        projectionSet = {
                          ${projName} = { inherit (proj) namespace; };
                        };
                      }
                    )
                  then
                    { inherit bundleName resName consumerWave; }
                  else
                    null
                ) (bundle.resources or { })
              )
            ) config.bundles
          );

          earliestConsumer =
            if consumers == [ ] || projWave == null then
              null
            else
              lib.foldl' (
                acc: c: if c.consumerWave != null && c.consumerWave < acc.consumerWave then c else acc
              ) (lib.head consumers) consumers;
        in
        lib.optional (earliestConsumer != null && earliestConsumer.consumerWave < projWave) {
          assertion = false;
          message = "Projection '${projName}' materialises in wave ${toString projWave}, but resource '${earliestConsumer.resName}' in bundle '${earliestConsumer.bundleName}' (wave ${toString earliestConsumer.consumerWave}) references Secret '${projName}' in namespace '${proj.namespace}'. The Secret won't exist when that resource deploys: add an explicit DAG anchor on the consumer so the projection lands in an earlier wave.";
        }
      ) config.secrets.projections
    );

  storeOf = name: lab.secrets.stores.${name} or null;

  # Rendering. Typing comes from the `kind` literal, not from an import, so
  # these are plain attrsets checked against the generated external-secrets
  # schemas. Those schemas are freeform, which means a misspelled key reaches
  # the manifest silently; the tests assert on rendered output for that reason.
  storeResourceName = name: "catallaxy-${name}";

  sharedStoreNames = lib.unique (
    lib.filter (n: n != null && storeOf n != null) (
      lib.mapAttrsToList (_: p: p.store) config.secrets.publish
      ++ lib.mapAttrsToList (_: sub: sub.store) config.secrets.subscribe
    )
  );

  # A subscriber reads the producer's namespace and Secret name off the
  # producing cluster's own declaration rather than restating them, so the two
  # sides cannot drift. An assertion above has already established that the
  # entry exists.
  publicationFor = name: sub: (lab.clusters.${sub.from} or { }).secrets.publish.${name} or null;

  addressOf =
    name: sub:
    let
      pub = publicationFor name sub;
    in
    if pub == null then
      null
    else
      remoteKeyFor {
        cluster = sub.from;
        inherit (pub) namespace secret;
      };

  labCaBundle = config.floes.cert-manager.exports.caBundle or null;

  # A store the lab hosts is reached at a lab hostname over TLS the lab's own
  # CA signed, and external-secrets verifies against the pod's trust store,
  # which has never heard of it. The cluster already carries that CA in every
  # namespace: `cata lab up` imports it as the cert-manager issuer's secret
  # and trust-manager distributes it. Nothing pointed the store at it, so
  # every lab-hosted store failed with `InvalidProviderConfig`.
  #
  # A store somewhere else is signed by a public CA and must keep using the
  # pod's own roots, so this is keyed on the address being one of the lab's.
  labCaFor =
    store:
    let
      server = store.vault.server or "";
      inLabZone = lib.hasSuffix ".${lab.dns.zone}" (
        lib.head (lib.splitString "/" (lib.removePrefix "https://" server))
      );
    in
    if labCaBundle == null || !(lib.hasPrefix "https://" server) || !inLabZone then
      null
    else
      {
        type = "ConfigMap";
        inherit (labCaBundle) name key;
        inherit (store.vault.tokenSecret) namespace;
      };

  anyStoreUsesLabCa = lib.any (name: labCaFor (storeOf name) != null) sharedStoreNames;

  clusterSecretStores = lib.listToAttrs (
    map (
      name:
      let
        store = storeOf name;
      in
      lib.nameValuePair "secret-store-${name}" {
        apiVersion = "external-secrets.io/v1beta1";
        kind = "ClusterSecretStore";
        metadata = {
          name = storeResourceName name;
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        spec.provider.vault = {
          inherit (store.vault) server path version;
          auth.tokenSecretRef = {
            inherit (store.vault.tokenSecret) name key namespace;
          };
        }
        // lib.optionalAttrs (labCaFor store != null) {
          caProvider = labCaFor store;
        };
      }
    ) sharedStoreNames
  );

  # `keys = [ ]` publishes the Secret whole: one entry naming only the remote
  # key, which is what a credential minted as a unit wants. Naming keys
  # publishes each as a property under the same address.
  pushDataFor =
    pub: address:
    if pub.keys == [ ] then
      [ { match.remoteRef.remoteKey = address; } ]
    else
      map (key: {
        match = {
          secretKey = key;
          remoteRef = {
            remoteKey = address;
            property = key;
          };
        };
      }) pub.keys;

  pushSecrets = lib.mapAttrs' (
    name: pub:
    lib.nameValuePair "push-${name}" {
      apiVersion = "external-secrets.io/v1alpha1";
      kind = "PushSecret";
      metadata = {
        inherit name;
        inherit (pub) namespace;
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };
      spec = {
        updatePolicy = "Replace";
        deletionPolicy = "Delete";
        secretStoreRefs = [
          {
            name = storeResourceName pub.store;
            kind = "ClusterSecretStore";
          }
        ];
        selector.secret.name = pub.secret;
        data = pushDataFor pub (remoteKeyFor {
          cluster = config.cluster.name;
          inherit (pub) namespace secret;
        });
      };
    }
  ) (lib.filterAttrs (_: p: p.store != null) config.secrets.publish);

  externalSecrets = lib.mapAttrs' (
    name: sub:
    lib.nameValuePair "subscribe-${name}" {
      apiVersion = "external-secrets.io/v1beta1";
      kind = "ExternalSecret";
      metadata = {
        inherit name;
        inherit (sub) namespace;
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };
      spec = {
        inherit (sub) refreshInterval;
        secretStoreRef = {
          name = storeResourceName sub.store;
          kind = "ClusterSecretStore";
        };
        target = {
          name = sub.secret;
          creationPolicy = "Owner";
        }
        // lib.optionalAttrs (sub.labels != { } || sub.annotations != { } || sub.fields != { }) {
          template = {
            engineVersion = "v2";
          }
          // lib.optionalAttrs (sub.labels != { } || sub.annotations != { }) {
            metadata =
              lib.optionalAttrs (sub.labels != { }) { inherit (sub) labels; }
              // lib.optionalAttrs (sub.annotations != { }) { inherit (sub) annotations; };
          }
          // lib.optionalAttrs (sub.fields != { }) {
            data = sub.fields;
          };
        };
        dataFrom = [ { extract.key = addressOf name sub; } ];
      };
    }
  ) (lib.filterAttrs (n: sub: sub.store != null && addressOf n sub != null) config.secrets.subscribe);

  sharingAssertions =
    let
      declaredStores = lib.concatStringsSep ", " (lib.attrNames (lab.secrets.stores or { }));

      # Reading a sibling cluster's `publish` is safe: it is a plain option
      # with a default, not gated on any floe being enabled, so folding over
      # lab.clusters here cannot cycle. coredns-internal.nix reads siblings
      # the same way.
      publishedBy = cluster: lib.attrNames ((lab.clusters.${cluster} or { }).secrets.publish or { });

      storeAssertion =
        what: entryName: storeName:
        let
          store = if storeName == null then null else storeOf storeName;
        in
        if storeName == null then
          [
            {
              assertion = false;
              message = ''
                secrets.${what}.${entryName} names no store, and the lab has
                ${
                  if runtimeStoreNames == [ ] then
                    "no runtime store to default to. Declare one: a store whose backend is `vault` or `external`."
                  else
                    "more than one runtime store (${lib.concatStringsSep ", " runtimeStoreNames}), so there is nothing to default to. Set `store`."
                }
              '';
            }
          ]
        else if store == null then
          [
            {
              assertion = false;
              message = ''
                secrets.${what}.${entryName}.store is "${storeName}", which is
                not one of the declared stores (${declaredStores}).
              '';
            }
          ]
        else
          [
            {
              assertion = store.direction == "runtime";
              message = ''
                secrets.${what}.${entryName} uses store "${storeName}", whose
                backend is "${store.backend}" and so `authored`. An authored
                store is read-only and top-down: you write the value and it is
                projected into every cluster that needs it, and a cluster
                cannot write back.

                Sharing a value the lab mints at runtime needs a `runtime`
                store, whose backend is `vault` or `external`. If this value
                exists before the lab does, declare it in
                `lab.secrets.managed` and use `secrets.projections` instead.
              '';
            }
            {
              assertion = store.vault.server != null;
              message = ''
                secrets.${what}.${entryName} uses store "${storeName}", which
                has no `vault.server`. The generated ClusterSecretStore has
                nothing to dial.
              '';
            }
          ];
    in
    lib.concatLists (
      lib.mapAttrsToList (n: p: storeAssertion "publish" n p.store) config.secrets.publish
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (n: sub: storeAssertion "subscribe" n sub.store) config.secrets.subscribe
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        storeName: _:
        let
          store = storeOf storeName;
          server = if store == null then "" else (store.vault.server or "");

          # Every cluster that touches this store, from its own declaration.
          # Reading siblings this way is the same safe fold coredns-internal
          # already does: publish and subscribe are plain options with
          # defaults, gated on nothing.
          usedBy = lib.filter (
            c:
            let
              cc = lab.clusters.${c} or { };
              uses = a: lib.any (e: e.store == storeName) (lib.attrValues (cc.secrets.${a} or { }));
            in
            uses "publish" || uses "subscribe"
          ) (lib.attrNames (lab.clusters or { }));
        in
        lib.optional (lib.length usedBy > 1 && lib.hasInfix ".svc.cluster.local" server) {
          assertion = false;
          message = ''
            store "${storeName}" is used by more than one cluster
            (${lib.concatStringsSep ", " usedBy}) but its `vault.server` is
            ${server}, which is an in-cluster DNS name. It resolves only
            inside the cluster that runs the store, so every other cluster's
            ExternalSecret would wait forever on an address it cannot reach.

            Expose the store and point `vault.server` at the address that
            works from outside it. A floe hosting one publishes that as an
            export; `floes.openbao.exports.externalAddress` is the case this
            was written for.
          '';
        }
      ) (lab.secrets.stores or { })
    )
    ++
      lib.optional
        (
          (config.secrets.publish != { } || config.secrets.subscribe != { })
          && !(config.floes.external-secrets.enable or false)
        )
        {
          assertion = false;
          message = ''
            this cluster publishes or subscribes to shared secrets, but
            `floes.external-secrets.enable` is false. The PushSecret and
            ExternalSecret resources are reconciled by that controller, and its
            validating webhook rejects them outright when it is not running.

            Enable it on every cluster that shares a secret.
          '';
        }
    ++ lib.concatLists (
      lib.mapAttrsToList (
        n: sub:
        let
          known = lab.clusters or { };
        in
        if !(known ? ${sub.from}) then
          [
            {
              assertion = false;
              message = ''
                secrets.subscribe.${n}.from is "${sub.from}", which is not a
                cluster in this lab (${lib.concatStringsSep ", " (lib.attrNames known)}).
              '';
            }
          ]
        else
          [
            {
              assertion = builtins.elem n (publishedBy sub.from);
              message = ''
                secrets.subscribe.${n} reads from cluster "${sub.from}", but
                that cluster does not publish "${n}". It publishes: ${
                  let
                    got = publishedBy sub.from;
                  in
                  if got == [ ] then "nothing" else lib.concatStringsSep ", " got
                }.

                Both sides derive the same address from the producer's
                identity, so a name that does not match on both sides would
                leave the ExternalSecret waiting forever. Checking it here is
                the point of naming the producer rather than asking it.
              '';
            }
          ]
      ) config.secrets.subscribe
    );

  # The address a shared secret has in the runtime store. It is a pure
  # function of the producer's identity, so the publisher derives it from its
  # own name and every subscriber derives the same string from the cluster it
  # names. Nothing is negotiated, so nothing can cycle and a publisher never
  # learns who reads it.
  remoteKeyFor =
    {
      cluster,
      namespace,
      secret,
    }:
    "${lab.name}/${cluster}/${namespace}/${secret}";

  runtimeStores = lib.filterAttrs (_: st: st.direction == "runtime") (lab.secrets.stores or { });
  runtimeStoreNames = lib.attrNames runtimeStores;
  defaultRuntimeStore =
    if lib.length runtimeStoreNames == 1 then lib.head runtimeStoreNames else null;

  publishType = types.submodule (
    { name, ... }:
    {
      options = {
        namespace = mkOption {
          type = types.str;
          description = "Namespace holding the Secret to publish.";
        };

        secret = mkOption {
          type = types.str;
          default = name;
          description = "Name of the Secret to publish. Defaults to the attribute name.";
        };

        keys = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Keys to publish. Empty publishes every key the Secret has, which
            is what you want for a credential minted as a whole.
          '';
        };

        store = mkOption {
          type = types.nullOr types.str;
          default = defaultRuntimeStore;
          description = ''
            Runtime store to publish into. Defaults to the lab's runtime
            store when there is exactly one.
          '';
        };
      };
    }
  );

  subscribeType = types.submodule (
    { name, ... }:
    {
      options = {
        from = mkOption {
          type = types.str;
          description = "Cluster that publishes this secret.";
        };

        namespace = mkOption {
          type = types.str;
          description = "Namespace to materialise the Secret in, here.";
        };

        secret = mkOption {
          type = types.str;
          default = name;
          description = "Name to give the Secret here. Defaults to the attribute name.";
        };

        refreshInterval = mkOption {
          type = types.str;
          default = "1h";
          description = "How often external-secrets re-reads the value.";
        };

        store = mkOption {
          type = types.nullOr types.str;
          default = defaultRuntimeStore;
          description = "Runtime store to read from.";
        };

        labels = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = ''
            Labels to put on the Secret materialised here.

            What reads a secret often finds it by label rather than by name:
            argocd treats a Secret labelled
            `argocd.argoproj.io/secret-type: repository` as a repository
            registration. Without this a subscriber can receive the value and
            still have nothing notice it arrived.
          '';
        };

        annotations = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Annotations to put on the Secret materialised here.";
        };

        fields = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = lib.literalExpression ''
            {
              type = "git";
              url = "https://git.example.test/org/repo.git";
              username = "platform-bot";
              password = "{{ .token }}";
            }
          '';
          description = ''
            The keys the Secret should have here, when they are not the keys
            the publisher stored.

            A credential is published as whatever the minting cluster called
            it, and the consumer usually wants it under different names beside
            some constants: a token becomes `password`, next to the `url` and
            `username` that identify what it opens. `{{ .<key> }}` reads a
            published key; everything else is literal.

            Empty materialises the published keys unchanged.
          '';
        };
      };
    }
  );

in
{
  imports = [
    ./sops.nix
  ];

  options.secrets.projections = mkOption {
    type = types.attrsOf projectionType;
    default = { };
    description = ''
      Secret projections map lab-level managed secrets into Kubernetes Secrets.
      Each projection creates one K8s Secret with keys derived from a source
      managed secret, optionally transformed (base64, json-wrap).
    '';
  };

  options.secrets.publish = mkOption {
    type = types.attrsOf publishType;
    default = { };
    description = ''
      Secrets this cluster mints at runtime and makes available to the rest
      of the lab, through a runtime store.

      A value that exists before the lab does does not belong here: author it
      in a store and project it into each cluster that needs it. This is for
      values only the running lab can produce.
    '';
  };

  options.secrets.subscribe = mkOption {
    type = types.attrsOf subscribeType;
    default = { };
    description = ''
      Secrets another cluster publishes that this one needs. The producing
      cluster is named, never asked: it publishes to an address derived from
      its own identity and subscribers read the same address.
    '';
  };

  options.secrets.managed = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
    internal = true;
    description = "Deprecated: use lab.secrets.managed + secrets.projections";
  };

  config = {
    assertions = projectionAssertions ++ projectionPhaseAssertions ++ sharingAssertions;

    bundles = lib.mkMerge [
      (lib.mkIf (clusterSecretStores != { }) {
        secret-stores = {
          declaredBy = "cluster";
          resources = clusterSecretStores;
          # The external-secrets validating webhook intercepts these kinds, so
          # applying before it answers fails. This token implies the CRD one.
          #
          # A store verifying the lab CA also waits for the bundle carrying
          # it: trust-manager writes that ConfigMap into each namespace, and a
          # store created first reads as `InvalidProviderConfig` rather than
          # as waiting.
          requires = [
            "external-secrets/webhook/ready"
          ]
          ++ lib.optional (anyStoreUsesLabCa && labCaBundle.readyToken != null) labCaBundle.readyToken;
          provides = [ "secrets/stores/ready" ];
        };
      })

      (lib.mkIf (pushSecrets != { }) {
        secret-publications = {
          declaredBy = "cluster";
          resources = pushSecrets;
          # PushSecret gets no automatic edge to its store: the auto-edge
          # resolver reads the singular `secretStoreRef`, and PushSecret uses
          # the plural `secretStoreRefs`. ExternalSecret below is ordered for
          # free; this one has to say so.
          requires = [ "secrets/stores/ready" ];
        };
      })

      (lib.mkIf (externalSecrets != { }) {
        secret-subscriptions = {
          declaredBy = "cluster";
          resources = externalSecrets;
          requires = [ "secrets/stores/ready" ];
          provides = lib.mapAttrsToList (_: sub: "secret:${sub.namespace}/${sub.secret}") (
            lib.filterAttrs (n: sub: sub.store != null && addressOf n sub != null) config.secrets.subscribe
          );
        };
      })
    ];
  };
}
