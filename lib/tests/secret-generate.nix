{ lib, pkgs }:

let
  # A generated secret has no author, so these evaluate a real lab and assert
  # on what was rendered. The generated CRD specs carry
  # `freeformType = types.attrs`, so eval succeeding proves nothing about the
  # keys: every case reads the field it cares about.
  evalLab =
    cluster:
    (lib.evalModules {
      modules = [
        ../../modules/lab
        {
          _module.args.pkgs = pkgs;
          _module.args.cataCharts = {
            netbird-operator.chart = pkgs.emptyDirectory;
            harbor.chart = pkgs.emptyDirectory;
          };
          lab.name = "t";
          lab.dns.zone = "t.test";
          lab.clusters.c = cluster;
        }
      ];
    }).config;

  eso = {
    floes.external-secrets.enable = true;
  };

  bundleOf = cfg: name: cfg.lab.clusters.c.bundles.${name} or { };

  resourcesOf = cfg: name: (bundleOf cfg name).resources or { };

  failures =
    cfg: map (a: a.message) (builtins.filter (a: !a.assertion) (cfg.lab.clusters.c.assertions or [ ]));

  saysAny = msgs: fragment: builtins.any (m: lib.hasInfix fragment m) msgs;

  waveIndexOf =
    cfg: name:
    let
      indexed = lib.imap0 (i: wave: {
        inherit i;
        names = map (b: b.name) wave;
      }) cfg.lab.clusters.c.cluster.out.manifestWaves;
      hit = builtins.filter (w: builtins.elem name w.names) indexed;
    in
    if hit == [ ] then null else (builtins.head hit).i;

  # The auto-edge is applied while the waves are computed, not written back
  # into `config.bundles`, so an edge nobody declared is only visible here.
  resolvedRequiresOf =
    cfg: name:
    let
      hit = lib.filter (b: b.name == name) (lib.concatLists cfg.lab.clusters.c.cluster.out.manifestWaves);
    in
    if hit == [ ] then null else (builtins.head hit).requires;

  # A consumer that reads the generated Secret the ordinary way, to prove the
  # edge appears without anyone declaring it.
  consumer = evalLab (
    eso
    // {
      secrets.generate.app-token.namespace = "app";
      bundles.consumer.resources.app = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          name = "app";
          namespace = "app";
        };
        spec = {
          selector.matchLabels.app = "app";
          template = {
            metadata.labels.app = "app";
            spec.containers = [
              {
                name = "app";
                image = "nginx:1.27-alpine";
                env = [
                  {
                    name = "TOKEN";
                    valueFrom.secretKeyRef = {
                      name = "app-token";
                      key = "password";
                    };
                  }
                ];
              }
            ];
          };
        };
      };
    }
  );

  plain = evalLab (
    eso
    // {
      secrets.generate.app-token.namespace = "app";
    }
  );

  renamed = evalLab (
    eso
    // {
      secrets.generate.harbor-admin = {
        namespace = "harbor";
        key = "HARBOR_ADMIN_PASSWORD";
        length = 24;
      };
    }
  );

  encoded = evalLab (
    eso
    // {
      secrets.generate.enc-key = {
        namespace = "netbird";
        key = "key";
        length = 32;
        encoding = "base64";
      };
    }
  );

  withoutEso = evalLab { secrets.generate.app-token.namespace = "app"; };

  # Harbor is the first floe to use this, and its two Secrets reach the chart
  # as helm values, which is the case the auto-edge cannot see. Asserted here
  # rather than in the floe's own suite because `secrets.generate` is a
  # cluster option: evaluated in isolation a floe leaves it an unmerged mkIf.
  harbor = evalLab (
    eso
    // {
      floes.harbor.enable = true;
      floes.harbor.domain = "reg.t.test";
    }
  );

  esFor = cfg: name: (resourcesOf cfg "secret-generator-${name}")."${name}-external-secret";
  genFor = cfg: name: (resourcesOf cfg "secret-generator-${name}")."${name}-generator";
in
lib.runTests {

  # `allowRepeat`, `length` and `noUpper` carry no default in the generated
  # schema, so every one of them has to be set or eval fails.
  testGeneratorSpecIsComplete = {
    expr = (genFor plain "app-token").spec;
    expected = {
      length = 24;
      digits = null;
      symbols = 0;
      symbolCharacters = null;
      allowRepeat = true;
      noUpper = false;
    };
  };

  testGeneratorIsTheRightKind = {
    expr = [
      (genFor plain "app-token").apiVersion
      (genFor plain "app-token").kind
    ];
    expected = [
      "generators.external-secrets.io/v1alpha1"
      "Password"
    ];
  };

  # The one field that decides whether this is a mint or a rotation. A
  # generator runs again on every refresh, so anything but zero replaces the
  # value underneath whatever already read it.
  testTheValueIsMintedOnceAndNotRotated = {
    expr = (esFor plain "app-token").spec.refreshInterval;
    expected = "0";
  };

  # The generator emits the key `password`, so the default key needs no
  # renaming. Null rather than absent: a typed submodule always has the
  # attribute, which is why `? rewrite` would pass on every case.
  testTheDefaultKeyNeedsNoRewrite = {
    expr = (builtins.head (esFor plain "app-token").spec.dataFrom).rewrite;
    expected = null;
  };

  testTheGeneratorIsReadThroughDataFrom = {
    expr = (builtins.head (esFor plain "app-token").spec.dataFrom).sourceRef.generatorRef;
    expected = {
      apiVersion = "generators.external-secrets.io/v1alpha1";
      kind = "Password";
      name = "app-token";
    };
  };

  testAnotherKeyIsRenamedByRewrite = {
    expr = (builtins.head (esFor renamed "harbor-admin").spec.dataFrom).rewrite;
    expected = [
      {
        regexp = {
          source = "^password$";
          target = "HARBOR_ADMIN_PASSWORD";
        };
        transform = null;
      }
    ];
  };

  # base64 has to transform the value, not just rename the key, so it goes
  # through the target template instead. Exactly one of the two mechanisms
  # appears.
  testBase64GoesThroughTheTemplate = {
    expr = [
      (esFor encoded "enc-key").spec.target.template.engineVersion
      (esFor encoded "enc-key").spec.target.template.data.key
      (builtins.head (esFor encoded "enc-key").spec.dataFrom).rewrite
    ];
    expected = [
      "v2"
      "{{ .password | b64enc }}"
      null
    ];
  };

  testPlainCarriesNoTemplate = {
    expr = (esFor renamed "harbor-admin").spec.target.template;
    expected = null;
  };

  testTargetOwnsTheSecretItCreates = {
    expr = [
      (esFor renamed "harbor-admin").spec.target.name
      (esFor renamed "harbor-admin").spec.target.creationPolicy
    ];
    expected = [
      "harbor-admin"
      "Owner"
    ];
  };

  # The token a projection provides, so a consumer of the Secret orders
  # against it without anyone writing the edge.
  testTheBundleProvidesTheSecretToken = {
    expr = {
      provides = (bundleOf renamed "secret-generator-harbor-admin").provides;
      requires = (bundleOf renamed "secret-generator-harbor-admin").requires;
    };
    expected = {
      provides = [ "secret:harbor/harbor-admin" ];
      requires = [ "external-secrets/webhook/ready" ];
    };
  };

  testTheProbeWaitsForTheKeyNotJustTheSecret = {
    expr = (bundleOf renamed "secret-generator-harbor-admin").readyProbe;
    expected = {
      kind = "jsonpath";
      resource = "secret/harbor-admin";
      namespace = "harbor";
      jsonpath = "{.data.HARBOR_ADMIN_PASSWORD}";
      timeout = "5m";
    };
  };

  testGeneratingWithoutExternalSecretsIsRefused = {
    expr = saysAny (failures withoutEso) "`floes.external-secrets.enable` is false";
    expected = true;
  };

  testTheRefusalNamesWhatWasGenerated = {
    expr = saysAny (failures withoutEso) "(app-token)";
    expected = true;
  };

  testGeneratingWithExternalSecretsIsClean = {
    expr = failures plain;
    expected = [ ];
  };

  # The point of joining the projection token namespace: a bundle referencing
  # the Secret waits for it, and nobody wrote that edge.
  testAConsumerWaitsForTheGeneratedSecret = {
    expr =
      let
        gen = waveIndexOf consumer "secret-generator-app-token";
        use = waveIndexOf consumer "consumer";
      in
      gen != null && use != null && gen < use;
    expected = true;
  };

  # Nothing declares a generated secret by default, so this must not add a
  # bundle to every lab in the repo.
  testNothingIsRenderedByDefault = {
    expr = lib.filter (lib.hasPrefix "secret-generator-") (
      lib.attrNames (evalLab { }).lab.clusters.c.bundles
    );
    expected = [ ];
  };

  testHarborGeneratesBothOfItsSecrets = {
    expr = lib.mapAttrs (_: g: {
      inherit (g) key length namespace;
    }) harbor.lab.clusters.c.secrets.generate;
    expected = {
      harbor-admin = {
        key = "HARBOR_ADMIN_PASSWORD";
        length = 24;
        namespace = "harbor";
      };
      harbor-secret-key = {
        key = "secretKey";
        length = 16;
        namespace = "harbor";
      };
    };
  };

  # Harbor decrypts its own stored credentials with this as an AES key and
  # rejects any length but 16, which is why it is a case and not a comment.
  testHarborsSecretKeyIsExactlySixteenCharacters = {
    expr = harbor.lab.clusters.c.secrets.generate.harbor-secret-key.length;
    expected = 16;
  };

  testHarborWaitsForBothSecrets = {
    expr = lib.filter (lib.hasPrefix "secret:") (bundleOf harbor "harbor").requires;
    expected = [
      "secret:harbor/harbor-admin"
      "secret:harbor/harbor-secret-key"
    ];
  };
}
