{ lib }:

let
  graph = import ../eval/manifest-graph.nix { inherit lib; };
  inherit (graph) topoSort computeWaves;

  b =
    attrs:
    {
      kinds = [ ];
      floe = null;
      after = [ ];
      requires = [ ];
      provides = [ ];
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

  (assertEq "kind:X anchor matches any bundle of that kind"
    (orderOf {
      workload = b {
        kinds = [ "Deployment" ];
        after = [ "kind:Namespace" ];
      };
      ns-app = b { kinds = [ "Namespace" ]; };
      ns-lib = b { kinds = [ "Namespace" ]; };
    })

    [
      "ns-app"
      "ns-lib"
      "workload"
    ]
  )

  # A bundle holds resources of many kinds, which is why this is a list and
  # not the scalar it started as: the scalar could only ever describe a bundle
  # holding one thing.
  (assertEq "kind:X matches a bundle that holds that kind among others"
    (orderOf {
      mixed = b {
        kinds = [
          "ConfigMap"
          "CustomResourceDefinition"
          "Deployment"
        ];
      };
      user = b { after = [ "optional:kind:CustomResourceDefinition" ]; };
    })

    [
      "mixed"
      "user"
    ]
  )

  (assertEq "a bundle declaring no kinds answers no kind: anchor"
    (orderOf {
      chartOnly = b { kinds = [ ]; };
      user = b { after = [ "optional:kind:Deployment" ]; };
    })

    [
      "chartOnly"
      "user"
    ]
  )

  (assertEq "floe:X anchor matches any bundle from that floe"
    (orderOf {
      user = b {
        floe = "consumer";
        after = [ "floe:cert-manager" ];
      };
      issuer = b { floe = "cert-manager"; };
      webhook = b { floe = "cert-manager"; };
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
      user = b { after = [ "kind:no-such-kind" ]; };
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
          floe = "myfloe";
          provides = [ "here" ];
        };
      };
    })
    [
      [
        {
          after = [ ];
          floe = "myfloe";
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

  (assertEq "unknown root is silently skipped" (graph.closurePredecessors {
    bundles = {
      real = b { };
    };
    roots = [ "typo-no-such-bundle" ];
  }) [ ])
]
