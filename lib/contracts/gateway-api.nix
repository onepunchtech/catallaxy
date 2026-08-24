{ lib }:

let
  # Attaching to a parent is what a route is for, so the thing that admits one
  # is a programmed Gateway and not merely an installed CRD. Whoever provides
  # the public Gateway names these as well, which is what puts a consumer
  # behind it without the consumer saying so.
  routeKinds = [
    "kind:gateway.networking.k8s.io/HTTPRoute"
    "kind:gateway.networking.k8s.io/GRPCRoute"
    "kind:gateway.networking.k8s.io/TCPRoute"
    "kind:gateway.networking.k8s.io/TLSRoute"
    "kind:gateway.networking.k8s.io/UDPRoute"
    "kind:gateway.networking.k8s.io/BackendTLSPolicy"
    "kind:gateway.networking.k8s.io/BackendLBPolicy"
  ];

  # A Gateway needs its class and its controller, not another Gateway, so
  # these stop at the CRD.
  infraKinds = [
    "kind:gateway.networking.k8s.io/GatewayClass"
    "kind:gateway.networking.k8s.io/Gateway"
    "kind:gateway.networking.k8s.io/ReferenceGrant"
  ];
in
{
  inherit routeKinds infraKinds;

  crdKinds = infraKinds ++ routeKinds;
}
