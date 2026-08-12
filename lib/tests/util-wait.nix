{ lib }:

let
  wait = import ../util/wait.nix { inherit lib; };
  inherit (wait) mkWaitInitContainer mkWaitJob renderProbe;

  hasSubstr = substr: str: lib.hasInfix substr str;
  anyContains = substr: argv: lib.any (a: builtins.isString a && lib.hasInfix substr a) argv;
in
lib.runTests {

  testConditionCommand = {
    expr =
      (mkWaitInitContainer {
        probe = {
          kind = "condition";
          resource = "deployment/harbor-core";
          namespace = "harbor";
          condition = "Available";
        };
      }).command;
    expected = [
      "kubectl"
      "wait"
      "--for=condition=Available=True"
      "deployment/harbor-core"
      "-n"
      "harbor"
      "--timeout=5m"
    ];
  };

  testConditionCustomTimeout = {
    expr =
      let
        c = mkWaitInitContainer {
          probe = {
            kind = "condition";
            resource = "deployment/foo";
            namespace = "ns";
            condition = "Ready";
            timeout = "15m";
          };
        };
      in
      builtins.elem "--timeout=15m" c.command;
    expected = true;
  };

  testJsonpathScriptWaitsForCreateThenJsonpath = {
    expr =
      let
        c = mkWaitInitContainer {
          probe = {
            kind = "jsonpath";
            resource = "secret/harbor-kanidm-oauth2-credentials";
            namespace = "kanidm";
            jsonpath = "{.data.CLIENT_SECRET}";
          };
        };
        script = builtins.head c.args;
      in
      hasSubstr "--for=create" script
      && hasSubstr "--for=jsonpath='{.data.CLIENT_SECRET}'" script
      && hasSubstr "harbor-kanidm-oauth2-credentials" script;
    expected = true;
  };

  testJsonpathValueExactMatch = {
    expr =
      let
        c = mkWaitInitContainer {
          probe = {
            kind = "jsonpath";
            resource = "statefulset/kanidm-default";
            namespace = "kanidm";
            jsonpath = "{.status.readyReplicas}";
            value = 1;
          };
        };
        script = builtins.head c.args;
      in
      hasSubstr "--for=jsonpath='{.status.readyReplicas}'=1" script;
    expected = true;
  };

  testExistsCommand = {
    expr =
      (mkWaitInitContainer {
        probe = {
          kind = "exists";
          resource = "secret/kanidm-admin-passwords";
          namespace = "kanidm";
        };
      }).command;
    expected = [
      "kubectl"
      "wait"
      "--for=create"
      "secret/kanidm-admin-passwords"
      "-n"
      "kanidm"
      "--timeout=5m"
    ];
  };

  testHttpScriptContainsCurlAndUrl = {
    expr =
      let
        c = mkWaitInitContainer {
          probe = {
            kind = "http";
            url = "https://idm.example.com/.well-known/openid-configuration";
            timeout = "2m";
            interval = "30s";
          };
        };
        script = builtins.head c.args;
      in
      hasSubstr "curl" script
      && hasSubstr "idm.example.com/.well-known/openid-configuration" script

      && hasSubstr "seq 1 4" script;
    expected = true;
  };

  testHttpDefaultImage = {
    expr =
      (mkWaitInitContainer {
        probe = {
          kind = "http";
          url = "http://example.com";
        };
      }).image;
    expected = "curlimages/curl:8.10.1";
  };

  testHttpCustomStatus = {
    expr =
      let
        c = mkWaitInitContainer {
          probe = {
            kind = "http";
            url = "http://example.com";
            expectedStatus = 401;
          };
        };
        script = builtins.head c.args;
      in
      hasSubstr "= \"401\"" script;
    expected = true;
  };

  testHttpCaBundleMounts = {
    expr =
      let
        c = mkWaitInitContainer {
          probe = {
            kind = "http";
            url = "https://x";
            caBundleMount = {
              configMap = "lab-ca-bundle";
              key = "ca.crt";
              mountPath = "/etc/ssl/lab";
            };
          };
        };
      in
      c ? volumeMounts && (builtins.head c.volumeMounts).mountPath == "/etc/ssl/lab";
    expected = true;
  };

  testTcpScriptUsesNc = {
    expr =
      let
        script =
          builtins.head
            (mkWaitInitContainer {
              probe = {
                kind = "tcp";
                host = "kanidm.kanidm.svc.cluster.local";
                port = 8443;
              };
            }).args;
      in
      hasSubstr "nc -z" script && hasSubstr "8443" script;
    expected = true;
  };

  testDnsScriptUsesNslookup = {
    expr =
      let
        script =
          builtins.head
            (mkWaitInitContainer {
              probe = {
                kind = "dns";
                hostname = "idm.example.com";
              };
            }).args;
      in
      hasSubstr "nslookup 'idm.example.com'" script;
    expected = true;
  };

  testScriptEmbedsVerbatim = {
    expr =
      let
        c = mkWaitInitContainer {
          probe = {
            kind = "script";
            script = "echo hello && kubectl get pods";
          };
        };
      in
      builtins.head c.args;
    expected = "echo hello && kubectl get pods";
  };

  testScriptDefaultImage = {
    expr =
      (mkWaitInitContainer {
        probe = {
          kind = "script";
          script = ":";
        };
      }).image;
    expected = "alpine/k8s:1.32.4";
  };

  testUnknownKindThrows = {
    expr =
      (builtins.tryEval (renderProbe {
        kind = "bogus";
      })).success;
    expected = false;
  };

  testMissingKindThrows = {
    expr = (builtins.tryEval (renderProbe { })).success;
    expected = false;
  };

  testDefaultContainerName = {
    expr =
      (mkWaitInitContainer {
        probe = {
          kind = "exists";
          resource = "secret/x";
          namespace = "ns";
        };
      }).name;
    expected = "wait";
  };

  testCustomContainerName = {
    expr =
      (mkWaitInitContainer {
        probe = {
          kind = "exists";
          resource = "secret/x";
          namespace = "ns";
        };
        name = "wait-for-oauth2-secret";
      }).name;
    expected = "wait-for-oauth2-secret";
  };

  testWaitJobShape = {
    expr =
      let
        job =
          (mkWaitJob {
            probe = {
              kind = "exists";
              resource = "secret/x";
              namespace = "kanidm";
            };
            namespace = "harbor";
            name = "wait-for-kanidm-oauth2";
            serviceAccountName = "harbor-bootstrap";
          }).wait-for-kanidm-oauth2;
      in
      {
        inherit (job) apiVersion kind;
        sa = job.spec.template.spec.serviceAccountName;
        cName = (builtins.head job.spec.template.spec.containers).name;
      };
    expected = {
      apiVersion = "batch/v1";
      kind = "Job";
      sa = "harbor-bootstrap";
      cName = "wait";
    };
  };
}
