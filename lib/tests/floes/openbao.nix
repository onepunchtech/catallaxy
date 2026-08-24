{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  openbao = import ../../../modules/lab/cluster/floes/openbao;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.openbao.chart = pkgs.emptyDirectory;
      k8sHelpers = import ../../floe/stub-k8s-helpers.nix { inherit lib; };
    };
  };

  stubUpstream =
    { lib, ... }:
    {
      config._module.freeformType = lib.types.attrs;
      options.floes.gateway.exports = lib.mkOption {
        type = lib.types.attrs;
        default = {
          gatewayName = "stub-gateway";
          namespace = "kube-system";
          defaultTier = "public";
        };
      };
      options.floes.cert-manager.exports = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
    };

  eval =
    settings:
    evalFloe (
      baseArgs
      // {
        floe = openbao;
        cluster = {
          imports = [ stubUpstream ];
          floes.openbao = {
            enable = true;
          }
          // settings;
        };
      }
    );

  failures = r: map (a: a.message) (builtins.filter (a: !a.assertion) r.config.assertions);

  says = msgs: fragment: builtins.any (m: lib.hasInfix fragment m) msgs;

  # A floe evaluated on its own has no module system to merge its config, so a
  # `mkIf` arrives whole. Reading through it is the difference between "no
  # probe" and "a probe behind a false condition".
  probeOf =
    r:
    let
      p = r.config.bundles.openbao.readyProbe or null;
    in
    if !(builtins.isAttrs p) then
      p
    else if (p._type or null) == "if" then
      (if p.condition then p.content else null)
    else
      p;

  dev = eval { };

  # The documented escape hatch for unsealing by hand.
  handUnsealed = eval {
    mode = "standalone";
    seal = { };
  };

  quietUi = eval {
    mode = "standalone";
    ui = false;
    seal.awskms.region = "us-east-1";
  };

  ha = eval {
    mode = "ha";
    seal.awskms.region = "us-east-1";
  };

  noRecovery = eval {
    mode = "ha";
    seal.awskms.region = "us-east-1";
    recoveryKeysRef = null;
  };

  # Same reason as `probeOf`: a floe evaluated alone hands back the mkIf
  # rather than the value, so "is there an init bundle" is a question about
  # the condition, not about whether the attribute exists.
  initBundleOf =
    r:
    let
      b = r.config.bundles.openbao-init or null;
    in
    if !(builtins.isAttrs b) then
      b
    else if (b._type or null) == "if" then
      (if b.condition then b.content else null)
    else
      b;

  # The Job's own name carries a content hash, so it is found by kind.
  initEnvNames =
    r:
    let
      job = builtins.head (
        builtins.filter (v: v.kind or "" == "Job") (builtins.attrValues (initBundleOf r).resources)
      );
    in
    map (e: e.name) (builtins.head job.spec.template.spec.containers).env;

  typedSeal = eval {
    mode = "standalone";
    seal.transit = {
      address = "https://bao.other:8200";
      key_name = "unseal";
      tls_skip_verify = false;
      max_retries = 5;
    };
  };

  sealed = eval { mode = "standalone"; };
  autoUnseal = eval {
    mode = "standalone";
    seal.awskms = {
      region = "us-east-1";
      kms_key_id = "alias/unseal";
    };
  };
in
lib.runTests {

  testDevModeIsClean = {
    expr = failures dev;
    expected = [ ];
  };

  # The whole point of the floe: a lab's runtime store needs an address that
  # external-secrets can dial from inside the cluster.
  testExportsAnInClusterAddress = {
    expr = dev.config.floes.openbao.exports.address;
    expected = "http://openbao.openbao.svc.cluster.local:8200";
  };

  testDevModeStartsUnsealed = {
    expr = dev.config.floes.openbao.exports.sealed;
    expected = false;
  };

  # Standalone with no seal would sit sealed forever after every restart, so
  # it fails the build rather than the deploy.
  testStandaloneWithoutSealIsRefused = {
    expr = says (failures sealed) "start sealed";
    expected = true;
  };

  testAutoUnsealIsAccepted = {
    expr = failures autoUnseal;
    expected = [ ];
  };

  testAutoUnsealCountsAsUnsealed = {
    expr = autoUnseal.config.floes.openbao.exports.sealed;
    expected = false;
  };

  # The seal block is rendered into OpenBao's HCL rather than asking the
  # author to write HCL by hand.
  testSealRendersIntoTheConfig = {
    expr =
      let
        conf = autoUnseal.config.bundles.openbao.helmCharts.openbao.values.server.standalone.config;
      in
      [
        (lib.hasInfix ''seal "awskms"'' conf)
        (lib.hasInfix ''kms_key_id = "alias/unseal"'' conf)
      ];
    expected = [
      true
      true
    ];
  };

  # The root token is a value you author, so it arrives as an ordinary Secret
  # rather than being baked into the manifests.
  testDevRootTokenComesFromASecret = {
    expr = map (e: [
      e.envName
      e.secretName
    ]) dev.config.bundles.openbao.helmCharts.openbao.values.server.extraSecretEnvironmentVars;
    expected = [
      [
        "BAO_DEV_ROOT_TOKEN_ID"
        "openbao-root-token"
      ]
    ];
  };

  testStandaloneClaimsAVolume = {
    expr = autoUnseal.config.bundles.openbao.helmCharts.openbao.values.server.dataStorage.enabled;
    expected = true;
  };

  testDevModeClaimsNoVolume = {
    expr = dev.config.bundles.openbao.helmCharts.openbao.values.server.dataStorage;
    expected = { };
  };

  # `seal = { }` says "I will unseal this myself". Nothing will unseal it, so
  # the floe must not claim it is unsealed nor wait for it to be ready.
  testHandUnsealingIsNotAutoUnsealing = {
    expr = {
      sealed = handUnsealed.config.floes.openbao.exports.sealed;
      probe = probeOf handUnsealed;
    };
    expected = {
      sealed = true;
      probe = null;
    };
  };

  testHandUnsealingIsStillAccepted = {
    expr = failures handUnsealed;
    expected = [ ];
  };

  # `ui` used to reach only the chart's UI Service, so a vault told not to
  # serve a UI served one anyway on its own port.
  testTurningTheUiOffReachesTheServerConfig = {
    expr = lib.hasInfix "ui = false" (
      quietUi.config.bundles.openbao.helmCharts.openbao.values.server.standalone.config
    );
    expected = true;
  };

  # Every seal value used to go through toString inside quotes, so a bool
  # arrived as "1" or "" and an int as a string.
  testSealValuesKeepTheirTypes = {
    expr =
      let
        conf = typedSeal.config.bundles.openbao.helmCharts.openbao.values.server.standalone.config;
      in
      [
        (lib.hasInfix "tls_skip_verify = false" conf)
        (lib.hasInfix "max_retries = 5" conf)
        (lib.hasInfix ''key_name = "unseal"'' conf)
      ];
    expected = [
      true
      true
      true
    ];
  };

  # A StatefulSet has no Available condition. The probe asked for one and
  # worked only because the CLI rewrote it.
  testTheProbeAsksForSomethingAStatefulSetHas = {
    expr = probeOf dev;
    expected = {
      kind = "jsonpath";
      resource = "statefulset/openbao";
      namespace = "openbao";
      jsonpath = "{.status.readyReplicas}";
      value = "1";
      timeout = "5m";
    };
  };

  testHaRendersRaftAndNotStandalone = {
    expr =
      let
        server = ha.config.bundles.openbao.helmCharts.openbao.values.server;
      in
      {
        standalone = server.standalone;
        haEnabled = server.ha.enabled;
        replicas = server.ha.replicas;
        raft = server.ha.raft.enabled;
        nodeId = server.ha.raft.setNodeId;
      };
    expected = {
      standalone = { };
      haEnabled = true;
      replicas = 3;
      raft = true;
      nodeId = true;
    };
  };

  # Without service_registration the active and standby Services select on
  # labels nothing sets, so a leader is elected that nothing can address.
  testRaftRegistersItselfWithKubernetes = {
    expr =
      let
        conf = ha.config.bundles.openbao.helmCharts.openbao.values.server.ha.raft.config;
      in
      [
        (lib.hasInfix ''storage "raft"'' conf)
        (lib.hasInfix ''service_registration "kubernetes" {}'' conf)
        (lib.hasInfix ''seal "awskms"'' conf)
      ];
    expected = [
      true
      true
      true
    ];
  };

  # The chart hardcodes an https clusterAddr even with tls_disable set.
  testTheClusterAddressMatchesTheListener = {
    expr = ha.config.bundles.openbao.helmCharts.openbao.values.server.ha.clusterAddr;
    expected = "http://$(HOSTNAME).openbao-internal:8201";
  };

  # dataStorage used to be gated on standalone alone; raft needs a volume per
  # server just as much.
  testEveryPersistentModeClaimsAVolume = {
    expr =
      map (r: r.config.bundles.openbao.helmCharts.openbao.values.server.dataStorage.enabled or false)
        [
          ha
          autoUnseal
        ];
    expected = [
      true
      true
    ];
  };

  # Nothing initialises a vault this floe did not put in dev mode, and an
  # uninitialised one is never Ready, so the init Job is the piece that makes
  # every other mode reachable at all.
  testDevModeNeedsNoInitJob = {
    expr = initBundleOf dev;
    expected = null;
  };

  testEveryOtherModeInitialisesItself = {
    expr = map (r: initBundleOf r != null) [
      autoUnseal
      ha
    ];
    expected = [
      true
      true
    ];
  };

  # external-secrets authenticates with this, so `secret-stores` has to wait
  # for it. It is the same token a projection would provide.
  testTheInitJobProvidesTheTokenSecret = {
    expr = {
      provides = (initBundleOf ha).provides;
      requires = (initBundleOf ha).requires;
      probe = (initBundleOf ha).readyProbe.jsonpath;
    };
    expected = {
      provides = [ "secret:external-secrets/vault-token" ];
      requires = [ "openbao/store/ready" ];
      probe = "{.data.token}";
    };
  };

  # The Job writes into two namespaces, so it needs a Role in each.
  testTheInitJobCanWriteWhereBothSecretsGo = {
    expr = map (n: (initBundleOf ha).resources.${n}.metadata.namespace) [
      "openbao-init-role"
      "openbao-init-token-role"
    ];
    expected = [
      "openbao"
      "external-secrets"
    ];
  };

  # Waiting for a Ready pod would deadlock: readiness cannot come before init,
  # and init cannot run before the API answers.
  testANonDevVaultIsWaitedOnByItsApiNotItsReadiness = {
    expr = (probeOf autoUnseal).kind;
    expected = "http";
  };

  testDevModeStillWaitsForAReadyPod = {
    expr = (probeOf dev).kind;
    expected = "jsonpath";
  };

  # Turning off recovery-key storage must stop the Job being told where to
  # put them, not just change what the option says.
  testRecoveryKeysCanBeKeptOutOfTheCluster = {
    expr = map (r: builtins.filter (lib.hasPrefix "RECOVERY_") (initEnvNames r)) [
      ha
      noRecovery
    ];
    expected = [
      [
        "RECOVERY_SECRET"
        "RECOVERY_KEY"
      ]
      [ ]
    ];
  };

  # A Shamir vault is sealed the instant it is initialised, and every step
  # after the init call needs it open. Running the Job anyway would burn the
  # one root token nobody kept.
  testAHandUnsealedVaultInitialisesItself = {
    expr = initBundleOf handUnsealed;
    expected = null;
  };

  # A hand-unsealed vault gets no init Job on purpose, so these are the only
  # way to initialise or reopen one.
  testHandUnsealingPublishesTheCommandsItNeeds = {
    expr = lib.attrNames handUnsealed.config.ops.openbao;
    expected = [
      "initialise"
      "seal-status"
      "unseal"
    ];
  };

  # An auto-unsealed vault has the Job for the one and the KMS for the other.
  testAutoUnsealingPublishesOnlyStatus = {
    expr = lib.attrNames autoUnseal.config.ops.openbao;
    expected = [ "seal-status" ];
  };

  # The category key itself must not appear, or the generated tool grows an
  # empty `openbao)` branch offering nothing.
  testDevModePublishesNothing = {
    expr = lib.attrNames dev.config.ops;
    expected = [ ];
  };

  # `<lab>-ops <category> <name>` execs `${package}/bin/<name>`, so a package
  # whose binary is named anything else produces a command that cannot run.
  testEachCommandsBinaryIsNamedAfterIt = {
    expr = lib.mapAttrs (_: c: c.package.name) handUnsealed.config.ops.openbao;
    expected = {
      initialise = "initialise";
      seal-status = "seal-status";
      unseal = "unseal";
    };
  };

  # The category is the key rather than a field, so this is the assertion
  # that the commands are reachable as `<lab>-ops openbao <name>`.
  testEveryCommandIsUnderTheOpenbaoCategory = {
    expr = lib.attrNames handUnsealed.config.ops;
    expected = [ "openbao" ];
  };

  # In HA one unsealed node is not a working vault, so the check counts them.
  testTheUnsealedCheckCountsEveryReplica = {
    expr = map (r: r.config.floes.openbao.verify.unsealed.expect.status.readyReplicas) [
      autoUnseal
      ha
    ];
    expected = [
      1
      3
    ];
  };

  testDevModeNeedsNoUnsealedCheck = {
    expr = lib.attrNames dev.config.floes.openbao.verify;
    expected = [ ];
  };
}
