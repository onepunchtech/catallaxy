{ lib }:

let
  netpol = import ../util/netpol.nix { inherit lib; };

  cidrs = {
    apiServerCidrs = [ "172.19.0.0/16" ];
    clusterCidrs = [
      "10.244.0.0/16"
      "10.96.0.0/12"
    ];
  };

  tcp = port: [
    {
      inherit port;
      protocol = "TCP";
    }
  ];

  plain =
    rules:
    (netpol.mkPlain (
      cidrs
      // rules
      // {
        name = "p";
        namespace = "ns";
      }
    )).spec;
  cilium =
    rules:
    (netpol.mkCilium (
      rules
      // {
        name = "p";
        namespace = "ns";
      }
    )).spec;
in
lib.runTests {

  testAnywhereRendersNoPeerRatherThanAnEmptyOne = {
    expr =
      (plain {
        egress = [
          {
            to = "anywhere";
            ports = tcp 53;
          }
        ];
      }).egress;
    expected = [ { ports = tcp 53; } ];
  };

  testAnywhereHasNoEmptyToKey = {
    expr = builtins.head (plain { egress = [ { to = "anywhere"; } ]; }).egress ? to;
    expected = false;
  };

  testANamespacePeerUsesTheBuiltInLabel = {
    expr =
      (plain {
        egress = [
          {
            to.namespaces = [ "openbao" ];
            ports = tcp 8200;
          }
        ];
      }).egress;
    expected = [
      {
        to = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "openbao"; } ];
        ports = tcp 8200;
      }
    ];
  };

  testTheApiServerBecomesAnAddressRange = {
    expr =
      (plain {
        egress = [
          {
            to = "apiServer";
            ports = tcp 6443;
          }
        ];
      }).egress;
    expected = [
      {
        to = [ { ipBlock.cidr = "172.19.0.0/16"; } ];
        ports = tcp 6443;
      }
    ];
  };

  testCiliumNamesTheApiServerOutright = {
    expr = (cilium { egress = [ { to = "apiServer"; } ]; }).egress;
    expected = [ { toEntities = [ "kube-apiserver" ]; } ];
  };

  testTheInternetExcludesTheClusterItself = {
    expr =
      (plain {
        egress = [
          {
            to = "world";
            ports = tcp 443;
          }
        ];
      }).egress;
    expected = [
      {
        to = [
          {
            ipBlock = {
              cidr = "0.0.0.0/0";
              except = [
                "10.244.0.0/16"
                "10.96.0.0/12"
              ];
            };
          }
        ];
        ports = tcp 443;
      }
    ];
  };

  testCiliumWritesPortsAsStrings = {
    expr =
      (cilium {
        egress = [
          {
            to.namespaces = [ "openbao" ];
            ports = tcp 8200;
          }
        ];
      }).egress;
    expected = [
      {
        toEndpoints = [ { matchLabels."k8s:io.kubernetes.pod.namespace" = "openbao"; } ];
        toPorts = [
          {
            ports = [
              {
                port = "8200";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
    ];
  };

  testANamedPortSurvives = {
    expr = [
      (builtins.head
        (plain {
          egress = [
            {
              to = "world";
              ports = tcp "metrics";
            }
          ];
        }).egress
      ).ports
      (builtins.head
        (cilium {
          egress = [
            {
              to = "world";
              ports = tcp "metrics";
            }
          ];
        }).egress
      ).toPorts
    ];
    expected = [
      [
        {
          port = "metrics";
          protocol = "TCP";
        }
      ]
      [
        {
          ports = [
            {
              port = "metrics";
              protocol = "TCP";
            }
          ];
        }
      ]
    ];
  };

  testCiliumIngressRenamesThePeerKey = {
    expr =
      (cilium {
        ingress = [
          {
            from.namespaces = [ "prometheus" ];
            ports = tcp 9090;
          }
        ];
      }).ingress;
    expected = [
      {
        fromEndpoints = [ { matchLabels."k8s:io.kubernetes.pod.namespace" = "prometheus"; } ];
        toPorts = [
          {
            ports = [
              {
                port = "9090";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
    ];
  };

  testPlainIngressUsesFrom = {
    expr = (plain { ingress = [ { from = "sameNamespace"; } ]; }).ingress;
    expected = [ { from = [ { podSelector = { }; } ]; } ];
  };

  testAnUnknownPeerThrows = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (plain {
          egress = [ { to = "nonsense"; } ];
        }) true
      )).success;
    expected = false;
  };

  testANamespacePeerNamingNothingThrows = {
    expr =
      map
        (
          render:
          (builtins.tryEval (
            builtins.deepSeq (render {
              egress = [
                {
                  to.namespaces = [ ];
                  ports = tcp 8200;
                }
              ];
            }) true
          )).success
        )
        [
          plain
          cilium
        ];
    expected = [
      false
      false
    ];
  };

  testAnApiServerWithNoAddressRangeThrows = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (netpol.mkPlain {
          name = "p";
          namespace = "ns";
          apiServerCidrs = [ ];
          egress = [
            {
              to = "apiServer";
              ports = tcp 6443;
            }
          ];
        }) true
      )).success;
    expected = false;
  };

  testAPolicyWithOnlyEgressStillDeniesIngress = {
    expr = [
      (plain { egress = [ { to = "anywhere"; } ]; }).policyTypes
      (cilium { egress = [ { to = "anywhere"; } ]; }).enableDefaultDeny
    ];
    expected = [
      [
        "Ingress"
        "Egress"
      ]
      {
        ingress = true;
        egress = true;
      }
    ];
  };

  testAPolicyWithNoRulesAtAllStillDenies = {
    expr = (cilium { }).enableDefaultDeny;
    expected = {
      ingress = true;
      egress = true;
    };
  };
}
