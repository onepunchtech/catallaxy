{ lib }:

let
  graph = import ../eval/plan-graph.nix { inherit lib; };
  inherit (graph) topoSort;

  s =
    attrs:
    {
      kind = "test";
      after = [ ];
      before = [ ];
      requires = [ ];
      provides = [ ];
      cluster = null;
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
    steps:
    map (x: x.name) (topoSort {
      inherit steps;
    });

  force = expr: builtins.deepSeq expr expr;

in
lib.concatLists [

  (assertEq "linear via after"
    (orderOf {
      c = s {
        after = [ "provides:b-done" ];
      };
      b = s {
        after = [ "provides:a-done" ];
        provides = [ "b-done" ];
      };
      a = s {
        provides = [ "a-done" ];
      };
    })
    [
      "a"
      "b"
      "c"
    ]
  )

  (assertEq "linear via before"
    (orderOf {
      a = s { before = [ "provides:b-here" ]; };
      b = s {
        before = [ "provides:c-here" ];
        provides = [ "b-here" ];
      };
      c = s {
        provides = [ "c-here" ];
      };
    })
    [
      "a"
      "b"
      "c"
    ]
  )

  (assertEq "deterministic tie-break by name"
    (orderOf {
      zebra = s { };
      alpha = s { };
      mango = s { };
    })
    [
      "alpha"
      "mango"
      "zebra"
    ]
  )

  (assertEq "kind:X anchor matches any step of that kind"
    (orderOf {
      user = s {
        kind = "consumer";
        after = [ "kind:producer" ];
      };
      p1 = s { kind = "producer"; };
      p2 = s { kind = "producer"; };
    })
    [
      "p1"
      "p2"
      "user"
    ]
  )

  (assertEq "kind:X:cluster narrows by the step's cluster"
    (orderOf {
      user = s {
        kind = "consumer";
        after = [ "kind:producer:apps" ];
      };
      mgmt-p = s {
        kind = "producer";
        cluster = "mgmt";
      };
      apps-p = s {
        kind = "producer";
        cluster = "apps";
      };
    })

    [
      "apps-p"
      "mgmt-p"
      "user"
    ]
  )

  (assertEq "provides:token anchor matches any provider"
    (orderOf {
      user = s { after = [ "provides:tok" ]; };
      p = s { provides = [ "tok" ]; };
    })
    [
      "p"
      "user"
    ]
  )

  (assertEq "requires forces order across all providers"
    (orderOf {
      user = s { requires = [ "ready" ]; };
      p1 = s { provides = [ "ready" ]; };
      p2 = s { provides = [ "ready" ]; };
    })
    [
      "p1"
      "p2"
      "user"
    ]
  )

  (assertEq "optional: prefix silences a missing kind anchor" (orderOf {
    user = s { after = [ "optional:kind:nonexistent" ]; };
  }) [ "user" ])

  (assertEq "optional: prefix silences a missing provides anchor" (orderOf {
    user = s { after = [ "optional:provides:nobody-publishes-this" ]; };
  }) [ "user" ])

  (assertThrows "a bare step name is not an anchor" (
    force (orderOf {
      user = s { after = [ "some-other-step" ]; };
      some-other-step = s { };
    })
  ))

  (assertThrows "an optional bare step name is not an anchor either" (
    force (orderOf {
      user = s { after = [ "optional:some-other-step" ]; };
      some-other-step = s { };
    })
  ))

  (assertThrows "hard kind: anchor miss fails eval" (
    force (orderOf {
      user = s { after = [ "kind:no-such-kind" ]; };
    })
  ))

  (assertThrows "hard provides: anchor miss fails eval" (
    force (orderOf {
      user = s { after = [ "provides:unprovided" ]; };
    })
  ))

  (assertThrows "unsatisfied requires fails eval" (
    force (orderOf {
      user = s { requires = [ "never-provided" ]; };
    })
  ))

  (assertThrows "cycle via after fails eval" (
    force (orderOf {
      a = s { after = [ "b" ]; };
      b = s { after = [ "a" ]; };
    })
  ))

  (assertThrows "cycle via requires+provides fails eval" (
    force (orderOf {
      a = s {
        requires = [ "tok-b" ];
        provides = [ "tok-a" ];
      };
      b = s {
        requires = [ "tok-a" ];
        provides = [ "tok-b" ];
      };
    })
  ))

  (assertEq "topoSort preserves step attrs and injects name"
    (topoSort {
      steps = {
        only = s {
          kind = "custom-kind";
          provides = [ "here" ];
        };
      };
    })
    [
      {
        after = [ ];
        before = [ ];
        kind = "custom-kind";
        name = "only";
        provides = [ "here" ];
        requires = [ ];
        cluster = null;
      }
    ]
  )

  (assertEq "a soft capability orders against its provider when one exists"
    (orderOf {
      consumer = s { after = [ "optional:provides:host/lab-reachable" ]; };
      provider = s { provides = [ "host/lab-reachable" ]; };
    })
    [
      "provider"
      "consumer"
    ]
  )

  (assertEq "a soft capability nobody provides adds no edge"
    (orderOf {
      consumer = s { after = [ "optional:provides:host/lab-reachable" ]; };
      unrelated = s { };
    })
    [
      "consumer"
      "unrelated"
    ]
  )

  (assertEq "step that provides+requires the same token is not a cycle" (orderOf {
    x = s {
      provides = [ "tok" ];
      requires = [ "tok" ];
    };
  }) [ "x" ])
]
