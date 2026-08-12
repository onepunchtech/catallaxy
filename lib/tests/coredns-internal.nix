{ lib }:

let
  coredns = import ../../modules/lab/cluster/coredns-internal.nix;

  mkGateway =
    {
      domain ? "internal.mesh.test",
      clusterIP ? null,
      hostnames ? [ ],
    }:
    {
      floes.gateway.exports = {
        internalDomain = domain;
        internalGatewayClusterIP = clusterIP;
        internalHostnames = hostnames;
      };
    };

  mgmt = mkGateway {
    clusterIP = "10.96.100.100";
    hostnames = [
      "idm.mesh.test"
      "nb-dashboard.mesh.test"
    ];
  };

  apps = mkGateway {
    clusterIP = "10.112.0.250";
    hostnames = [ "hello.internal.mesh.test" ];
  };

  unwrap = c: if c ? _type && c._type == "if" then c.content else c;

  eval =
    self:
    (unwrap
      (coredns {
        config = self;
        inherit lib;
        lab = {
          clusters = { inherit mgmt apps; };
          dns = {
            enable = true;
            zone = "mesh.test";
            server = "172.21.0.1";
            port = 5354;
            coredns = {
              enable = true;
              extraServers = { };
            };
          };
        };
      }).config
    ).bundles.coredns-lab-dns.resources.coredns-custom.data;

  fromMgmt = eval mgmt;
  fromApps = eval apps;

  hasLine =
    data: file: line:
    lib.hasInfix line (data.${file} or "");
in
lib.runTests {

  testInternalZoneGetsItsOwnServerBlock = {
    expr = lib.hasInfix "internal.mesh.test:53" (fromMgmt."lab-internal.server" or "");
    expected = true;
  };

  testPublicZoneDoesNotClaimInternalNames = {
    expr = lib.hasInfix "hello.internal.mesh.test" (fromMgmt."lab.server" or "");
    expected = false;
  };

  testEveryClusterAnswersForTheWholeInternalZone = {
    expr = hasLine fromMgmt "lab-internal.server" "10.112.0.250 hello.internal.mesh.test";
    expected = true;
  };

  testInternalNamesKeepTheirOwningClusterAddress = {
    expr = hasLine fromApps "lab-internal.server" "10.112.0.250 hello.internal.mesh.test";
    expected = true;
  };

  testPublicNamesStayOnTheLocalInternalGateway = {
    expr = hasLine fromMgmt "lab.server" "10.96.100.100 idm.mesh.test";
    expected = true;
  };

  testAppsHasNoPublicHostsBlockOfItsOwn = {
    expr = lib.hasInfix "hosts {" (fromApps."lab.server" or "");
    expected = false;
  };

  testBothZonesForwardToTheLabResolver = {
    expr =
      hasLine fromMgmt "lab.server" "forward . 172.21.0.1:5354"
      && hasLine fromMgmt "lab-internal.server" "forward . 172.21.0.1:5354";
    expected = true;
  };
}
