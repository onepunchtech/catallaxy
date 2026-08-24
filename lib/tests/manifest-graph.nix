{ lib }:

let
  graph = import ../eval/manifest-graph.nix { inherit lib; };
  inherit (graph) topoSort computeWaves;

  b =
    attrs:
    {
      kinds = [ ];
      declaredBy = "cluster";
      after = [ ];
      requires = [ ];
      provides = [ ];
      conflicts = [ ];
    }
    // attrs;

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
      r = builtins.tryEval expr;
    in
    if r.success then
      [
        {
          inherit name;
          message = "expected a thrown error, got successful value: ${builtins.toJSON r.value}";
        }
      ]
    else
      [ ];

  orderOf =
    bundles:
    map (x: x.name) (topoSort {
      inherit bundles;
    });

  wavesOf =
    bundles:
    map (wave: map (x: x.name) wave) (computeWaves {
      inherit bundles;
    });

  force = expr: builtins.deepSeq expr expr;

in
lib.concatLists [

  (assertEq "linear via after"
    (orderOf {
      c = b { after = [ "b" ]; };
      b = b { after = [ "a" ]; };
      a = b { };
    })
    [
      "a"
      "b"
      "c"
    ]
  )

  (assertEq "linear via requires + provides"
    (orderOf {
      consumer = b { requires = [ "ready" ]; };
      producer = b { provides = [ "ready" ]; };
    })
    [
      "producer"
      "consumer"
    ]
  )

  (assertEq "deterministic tie-break by name"
    (orderOf {
      zebra = b { };
      alpha = b { };
      mango = b { };
    })
    [
      "alpha"
      "mango"
      "zebra"
    ]
  )

  (assertEq "independent bundles land in the same wave"
    (wavesOf {
      alpha = b { };
      beta = b { };
      gamma = b { };
    })
    [
      [
        "alpha"
        "beta"
        "gamma"
      ]
    ]
  )

  (assertEq "parallel chains group by depth"
    (wavesOf {
      a1 = b { };
      a2 = b { after = [ "a1" ]; };
      b1 = b { };
      b2 = b { after = [ "b1" ]; };
    })
    [
      [
        "a1"
        "b1"
      ]
      [
        "a2"
        "b2"
      ]
    ]
  )

  (assertEq "diamond DAG produces 3 waves"
    (wavesOf {
      root = b { };
      left = b { after = [ "root" ]; };
      right = b { after = [ "root" ]; };
      leaf = b {
        after = [
          "left"
          "right"
        ];
      };
    })
    [
      [ "root" ]
      [
        "left"
        "right"
      ]
      [ "leaf" ]
    ]
  )

  # `kind:` names admissibility, not containment. It used to mean "any bundle
  # holding a resource of this kind", which answers the opposite question:
  # every emitter of a Certificate rather than the one thing that admits one.
  (assertEq "kind:X matches whoever provides that kind, not who emits it"
    (orderOf {
      consumer = b { requires = [ "kind:cert-manager.io/Certificate" ]; };
      installer = b { provides = [ "kind:cert-manager.io/Certificate" ]; };
    })
    [
      "installer"
      "consumer"
    ]
  )

  (assertThrows "a kind nobody installs is refused" (
    force (orderOf {
      consumer = b { requires = [ "kind:cert-manager.io/Certificate" ]; };
    })
  ))

  (assertEq "the group qualifies the kind, so two Clusters are two names"
    (wavesOf {
      cnpg = b { provides = [ "kind:postgresql.cnpg.io/Cluster" ]; };
      capi = b { provides = [ "kind:cluster.x-k8s.io/Cluster" ]; };
      db = b { requires = [ "kind:postgresql.cnpg.io/Cluster" ]; };
    })
    [
      [
        "capi"
        "cnpg"
      ]
      [ "db" ]
    ]
  )

  (assertEq "floe:X anchor matches any bundle from that floe"
    (orderOf {
      user = b {
        declaredBy = "consumer";
        after = [ "floe:cert-manager" ];
      };
      issuer = b { declaredBy = "cert-manager"; };
      webhook = b { declaredBy = "cert-manager"; };
    })
    [
      "issuer"
      "webhook"
      "user"
    ]
  )

  (assertEq "provides:token anchor matches any provider"
    (orderOf {
      user = b { after = [ "provides:tok" ]; };
      p1 = b { provides = [ "tok" ]; };
      p2 = b { provides = [ "tok" ]; };
    })
    [
      "p1"
      "p2"
      "user"
    ]
  )

  (assertEq "bundle:<name> is equivalent to bare <name>"
    (orderOf {
      user = b { after = [ "bundle:target" ]; };
      target = b { };
    })
    [
      "target"
      "user"
    ]
  )

  (assertEq "requires forces order across all providers"
    (wavesOf {
      user = b { requires = [ "ready" ]; };
      p1 = b { provides = [ "ready" ]; };
      p2 = b { provides = [ "ready" ]; };
    })
    [
      [
        "p1"
        "p2"
      ]
      [ "user" ]
    ]
  )

  (assertEq "optional: prefix silences a missing kind anchor" (orderOf {
    user = b { after = [ "optional:kind:nonexistent" ]; };
  }) [ "user" ])

  (assertEq "optional: prefix silences a missing floe anchor" (orderOf {
    user = b { after = [ "optional:floe:nonexistent" ]; };
  }) [ "user" ])

  (assertEq "optional: prefix silences a missing bare-name anchor" (orderOf {
    user = b { after = [ "optional:typo-nobody-here" ]; };
  }) [ "user" ])

  (assertThrows "hard bare-name anchor miss fails eval" (
    force (orderOf {
      user = b { after = [ "typo-not-a-bundle" ]; };
    })
  ))

  (assertThrows "hard bundle: anchor miss fails eval" (
    force (orderOf {
      user = b { after = [ "bundle:missing" ]; };
    })
  ))

  (assertThrows "hard kind: anchor miss fails eval" (
    force (orderOf {
      user = b { after = [ "kind:example.com/NoSuchKind" ]; };
    })
  ))

  (assertThrows "hard floe: anchor miss fails eval" (
    force (orderOf {
      user = b { after = [ "floe:no-such-floe" ]; };
    })
  ))

  (assertThrows "hard provides: anchor miss fails eval" (
    force (orderOf {
      user = b { after = [ "provides:unprovided" ]; };
    })
  ))

  (assertThrows "unsatisfied requires fails eval" (
    force (orderOf {
      user = b { requires = [ "never-provided" ]; };
    })
  ))

  (assertThrows "cycle via after fails eval" (
    force (orderOf {
      a = b { after = [ "b" ]; };
      b = b { after = [ "a" ]; };
    })
  ))

  (assertThrows "cycle via requires+provides fails eval" (
    force (orderOf {
      a = b {
        requires = [ "tok-b" ];
        provides = [ "tok-a" ];
      };
      b = b {
        requires = [ "tok-a" ];
        provides = [ "tok-b" ];
      };
    })
  ))

  (assertEq "computeWaves preserves bundle attrs and injects name"
    (computeWaves {
      bundles = {
        only = b {
          kinds = [ "custom-kind" ];
          declaredBy = "myfloe";
          provides = [ "here" ];
        };
      };
    })
    [
      [
        {
          after = [ ];
          conflicts = [ ];
          declaredBy = "myfloe";
          kinds = [ "custom-kind" ];
          name = "only";
          provides = [ "here" ];
          requires = [ ];
        }
      ]
    ]
  )

  (assertEq "bundle that provides+requires the same token is not a cycle" (orderOf {
    x = b {
      provides = [ "tok" ];
      requires = [ "tok" ];
    };
  }) [ "x" ])

  (assertEq "closure includes the root itself" (lib.sort (a: b: a < b) (
    graph.closurePredecessors {
      bundles = {
        root = b { };
      };
      roots = [ "root" ];
    }
  )) [ "root" ])

  (assertEq "closure walks after-edges transitively"
    (lib.sort (a: b: a < b) (
      graph.closurePredecessors {
        bundles = {
          a = b { };
          b = b { after = [ "a" ]; };
          c = b { after = [ "b" ]; };
          unrelated = b { };
        };
        roots = [ "c" ];
      }
    ))
    [
      "a"
      "b"
      "c"
    ]
  )

  (assertEq "closure walks requires+provides transitively"
    (lib.sort (a: b: a < b) (
      graph.closurePredecessors {
        bundles = {
          crds = b { provides = [ "cert-manager/crds/established" ]; };
          op = b {
            requires = [ "cert-manager/crds/established" ];
            provides = [ "cert-manager/webhook/ready" ];
          };
          issuer = b { requires = [ "cert-manager/webhook/ready" ]; };
        };
        roots = [ "issuer" ];
      }
    ))
    [
      "crds"
      "issuer"
      "op"
    ]
  )

  (assertEq "closure over multiple roots unions the sets"
    (lib.sort (a: b: a < b) (
      graph.closurePredecessors {
        bundles = {
          a = b { };
          b1 = b { after = [ "a" ]; };
          b2 = b { after = [ "a" ]; };
          c = b { };
        };
        roots = [
          "b1"
          "b2"
        ];
      }
    ))
    [
      "a"
      "b1"
      "b2"
    ]
  )

  (assertEq "closure excludes bundles that no root depends on"
    (lib.sort (a: b: a < b) (
      graph.closurePredecessors {
        bundles = {
          root = b { after = [ "dep" ]; };
          dep = b { };
          orphan = b { };
        };
        roots = [ "root" ];
      }
    ))
    [
      "dep"
      "root"
    ]
  )

  (assertThrows "unknown root fails eval" (
    graph.closurePredecessors {
      bundles = {
        real = b { };
      };
      roots = [ "typo-no-such-bundle" ];
    }
  ))

  (assertEq "a known root still resolves alongside the check" (graph.closurePredecessors {
    bundles = {
      real = b { };
    };
    roots = [ "real" ];
  }) [ "real" ])

  (assertEq "requires reaches a bundle by name, the way after does"
    (orderOf {
      consumer = b { requires = [ "producer" ]; };
      producer = b { };
    })
    [
      "producer"
      "consumer"
    ]
  )

  (assertEq "after reaches a token, the way requires does"
    (orderOf {
      consumer = b { after = [ "cert-manager/webhook/ready" ]; };
      producer = b { provides = [ "cert-manager/webhook/ready" ]; };
    })
    [
      "producer"
      "consumer"
    ]
  )

  (assertEq "a bundle of that name wins over a token of that name"
    (orderOf {
      consumer = b { requires = [ "shared" ]; };
      shared = b { };
      impostor = b { provides = [ "shared" ]; };
    })
    [
      "impostor"
      "shared"
      "consumer"
    ]
  )

  (assertThrows "a name nothing provides is refused in requires" (
    force (orderOf {
      consumer = b { requires = [ "nobody/provides/this" ]; };
    })
  ))

  (assertThrows "a name nothing provides is refused in after" (
    force (orderOf {
      consumer = b { after = [ "nobody/provides/this" ]; };
    })
  ))

  (assertEq "optional: silences an unmatched name in requires too" (orderOf {
    consumer = b { requires = [ "optional:nobody/provides/this" ]; };
  }) [ "consumer" ])

  (assertEq "one provider of a name it conflicts with is not a conflict" (orderOf {
    gateway = b {
      provides = [ "api-gateway" ];
      conflicts = [ "api-gateway" ];
    };
  }) [ "gateway" ])

  (assertThrows "two providers of a conflicted name is refused" (
    force (orderOf {
      gateway = b {
        provides = [ "api-gateway" ];
        conflicts = [ "api-gateway" ];
      };
      cilium = b {
        provides = [ "api-gateway" ];
        conflicts = [ "api-gateway" ];
      };
    })
  ))

  (assertEq "two providers that do not conflict are additive"
    (lib.sort (a: b: a < b) (orderOf {
      zot = b { provides = [ "oci-registry" ]; };
      harbor = b { provides = [ "oci-registry" ]; };
    }))
    [
      "harbor"
      "zot"
    ]
  )

  (assertThrows "a one-sided conflict is refused whichever way the names sort" (
    force (orderOf {
      aaa = b { provides = [ "storage" ]; };
      zzz = b { conflicts = [ "storage" ]; };
    })
  ))

  (assertThrows "and refused when the conflicting side sorts first" (
    force (orderOf {
      aaa = b { conflicts = [ "storage" ]; };
      zzz = b { provides = [ "storage" ]; };
    })
  ))

  (assertThrows "conflicting with a name another bundle provides is refused" (
    force (orderOf {
      openebs = b { conflicts = [ "default-storage-class" ]; };
      k3s = b { provides = [ "default-storage-class" ]; };
    })
  ))

  (assertEq "a step: name is not refused for having no bundle behind it" (orderOf {
    consumer = b { requires = [ "step:lab/secrets" ]; };
  }) [ "consumer" ])

  (assertEq "and adds no edge, because the step is not on this cluster"
    (orderOf {
      aaa = b { after = [ "step:lab/secrets" ]; };
      zzz = b { };
    })
    [
      "aaa"
      "zzz"
    ]
  )

  (assertEq "a step: name is collected with the bundle and verb that named it"
    (graph.stepAnchors {
      consumer = b {
        requires = [ "step:lab/secrets" ];
        after = [ "optional:step:lab/registry-config" ];
      };
      unrelated = b { };
    })
    [
      {
        bundle = "consumer";
        field = "after";
        hard = false;
        token = "lab/registry-config";
      }
      {
        bundle = "consumer";
        field = "requires";
        hard = true;
        token = "lab/secrets";
      }
    ]
  )

  (assertEq "a bundle naming no step collects nothing" (graph.stepAnchors {
    plain = b { requires = [ "tok" ]; };
    p = b { provides = [ "tok" ]; };
  }) [ ])
]
