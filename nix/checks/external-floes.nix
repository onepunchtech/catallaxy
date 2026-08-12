{
  lib,
  pkgs,
  nixpkgs,
  pureLib,
  mkLab,
}:

let
  helloOutputs = (import ../../examples/floes/hello-floe/flake.nix).outputs {
    self = {
      floes = helloOutputs.flake.floes or { };
    };
    catallaxy = {
      lib.floe = pureLib.floe;
    };
    inherit nixpkgs;
    flake-parts.lib.mkFlake = _: cfg: cfg;
  };

  helloFloe = helloOutputs.flake.floes.hello;

  expectedUrl = "http://hello.hello.svc.cluster.local:80";
in
{
  floe-hello =
    let
      result = pureLib.floe.evalFloe {
        floe = helloFloe;
        cluster = {
          floes.hello.enable = true;
        };
      };
      resourceCount = builtins.length (lib.attrNames (result.manifests.hello.resources or { }));
    in
    pkgs.runCommand "floe-hello" { } ''
      cat <<EOF > $out
      hello-floe emitted ${toString resourceCount} resource(s)
      url = ${result.exports.url}
      EOF
      if [ ${toString resourceCount} -ne 2 ]; then
        echo "expected 2 resources, got ${toString resourceCount}" >&2
        exit 1
      fi
      if [ "${result.exports.url}" != "${expectedUrl}" ]; then
        echo "unexpected exports.url" >&2
        exit 1
      fi
    '';

  floe-consumer =
    let
      result = pureLib.evalModule {
        modules = [
          helloFloe
          (
            { ... }:
            {
              floes.hello = {
                enable = true;
                replicas = 3;
                overrides.extraLabels."app.kubernetes.io/instance" = "consumer-test";
              };
            }
          )
          (
            { lib, ... }:
            {
              options.bundles = lib.mkOption {
                type = lib.types.attrsOf lib.types.attrs;
                default = { };
              };
            }
          )
        ];
      };
      deployment = result.config.bundles.hello.resources.hello-deployment;
      replicas = deployment.spec.replicas;
      labelInstance = deployment.metadata.labels."app.kubernetes.io/instance" or "MISSING";
      exportsUrl = result.config.floes.hello.exports.url;
    in
    pkgs.runCommand "floe-consumer" { } ''
      cat <<EOF > $out
      consumer set replicas=${toString replicas}
      consumer override label app.kubernetes.io/instance=${labelInstance}
      exports.url=${exportsUrl}
      EOF
      if [ "${toString replicas}" != "3" ]; then
        echo "consumer's replicas override did not propagate" >&2
        exit 1
      fi
      if [ "${labelInstance}" != "consumer-test" ]; then
        echo "consumer's overrides.extraLabels did not propagate" >&2
        exit 1
      fi
      if [ "${exportsUrl}" != "${expectedUrl}" ]; then
        echo "exports.url did not resolve" >&2
        exit 1
      fi
    '';

  template-consumer =
    let
      myFloes = import ../../templates/consumer/floes {
        inherit lib;
        inherit (pureLib.floe) mkFloe;
      };
      lab = mkLab {
        modules = [ (import ../../templates/consumer/lab.nix { inherit myFloes; }) ];
      };
      forced = builtins.toJSON lab.config.lab.out.manifests;
    in
    pkgs.runCommand "template-consumer" { } ''
      cat > /dev/null <<'JSON'
      ${forced}
      JSON
      echo "templates/consumer evaluated" > $out
    '';
}
