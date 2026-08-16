{ lib, pkgs }:

let
  imageUtil = import ../../lib/render/images.nix { inherit lib pkgs; };

  lock.images = {
    "nginx:1.27-alpine" = "sha256:aaa";
    "busybox:1.36" = "sha256:bbb";
  };

  # A bare Pod, because the scrape used to miss those while the lint flagged
  # them; a ConfigMap holding an `image` key that is not an image; and a
  # reference that already carries a digest.
  fixture = pkgs.writeText "fixture.yaml" ''
    apiVersion: v1
    kind: Pod
    metadata:
      name: bare
    spec:
      containers:
        - name: c
          image: nginx:1.27-alpine
    ---
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: cm
    data:
      image: not-an-image
    ---
    apiVersion: batch/v1
    kind: CronJob
    metadata:
      name: cj
    spec:
      jobTemplate:
        spec:
          template:
            spec:
              initContainers:
                - name: i
                  image: busybox:1.36
              containers:
                - name: done
                  image: redis:7@sha256:deadbeef
  '';
  # Every shape the host rewrite has to tell apart: an implicit registry, an
  # explicit one, a host with a port, a digest, an operator CR carrying its
  # own image with no container around it, and a ConfigMap whose `image` key
  # is somebody's config.
  retargetFixture = pkgs.writeText "retarget-fixture.yaml" ''
    apiVersion: v1
    kind: Pod
    metadata:
      name: bare
    spec:
      containers:
        - name: a
          image: nginx:1.27-alpine
        - name: b
          image: grafana/grafana:11.4.0
        - name: c
          image: quay.io/openbao/openbao:2.3.1
        - name: d
          image: localhost:5050/team/app:1.2
        - name: e
          image: redis:7@sha256:deadbeef
    ---
    apiVersion: monitoring.coreos.com/v1
    kind: Prometheus
    metadata:
      name: p
    spec:
      image: quay.io/prometheus/prometheus:v3.4.0
    ---
    apiVersion: example.io/v1
    kind: Widget
    metadata:
      name: w
    spec:
      image: ""
    ---
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: cm
    data:
      image: not-an-image
      nested:
        image: some/thing:1.0
  '';
in
{
  image-rewrite-pins-what-the-lock-names =
    pkgs.runCommand "image-rewrite-pins-what-the-lock-names"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p work && cp ${fixture} work/fixture.yaml && chmod +w work/fixture.yaml
        ${imageUtil.applyToDir { inherit lock; } "work"}

        fail() { echo "$1" >&2; echo "--- rendered:" >&2; cat work/fixture.yaml >&2; exit 1; }
        has() { grep -qF "$1" work/fixture.yaml || fail "expected: $1"; }
        hasnt() { grep -qF "$1" work/fixture.yaml && fail "did not expect: $1"; true; }

        # A bare Pod's container, which the scrape used to miss entirely.
        has 'nginx:1.27-alpine@sha256:aaa'

        # A CronJob's init container, nested two levels deeper than a
        # Deployment's.
        has 'busybox:1.36@sha256:bbb'

        # Already pinned, and not in the lock, so it must survive untouched
        # rather than growing a second digest.
        has 'redis:7@sha256:deadbeef'
        hasnt 'redis:7@sha256:deadbeef@'

        # The lock is the filter: a string under an `image` key that is not a
        # reference the lock names is left alone.
        has 'not-an-image'

        # Assigning through an explicit path list would have created these on
        # every document that lacks them, which is how a ConfigMap ends up
        # with an empty spec.containers.
        yq -e 'select(.kind == "ConfigMap") | has("spec") | not' work/fixture.yaml >/dev/null \
          || fail "the rewrite invented a spec on a ConfigMap"

        touch $out
      '';

  # Retargeting has to reach images no floe declared, because until every
  # chart image is declared most of what a lab renders is undeclared, and a
  # mirror that holds most of the images is a mirror that does not work.
  image-retarget-moves-every-image-to-one-registry =
    pkgs.runCommand "image-retarget-moves-every-image-to-one-registry"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p work && cp ${retargetFixture} work/fixture.yaml && chmod +w work/fixture.yaml
        ${imageUtil.applyToDir {
          lock = { };
          registry = "registry.internal";
        } "work"}

        fail() { echo "$1" >&2; echo "--- rendered:" >&2; cat work/fixture.yaml >&2; exit 1; }
        has() { grep -qF "$1" work/fixture.yaml || fail "expected: $1"; }

        # An implicit registry gains a host rather than having one replaced.
        has 'registry.internal/nginx:1.27-alpine'
        has 'registry.internal/grafana/grafana:11.4.0'

        # An explicit one is replaced, and the repository path is kept, which
        # is what makes a pull-through cache a drop-in.
        has 'registry.internal/openbao/openbao:2.3.1'

        # A port in the host is not mistaken for a tag.
        has 'registry.internal/team/app:1.2'

        # A digest survives the move: a mirror serves the same manifest, so
        # rewriting the host must not unpin anything.
        has 'registry.internal/redis:7@sha256:deadbeef'

        # An operator CR's own image, with no container around it. This is
        # what a path list could never reach, and it is why the rewrite
        # descends rather than reading a list of container paths.
        has 'registry.internal/prometheus/prometheus:v3.4.0'

        # Retargeting is the one rewrite with no lock to filter by, so what it
        # leaves alone is as much of the contract as what it moves.

        # A ConfigMap is where a chart puts arbitrary text, and a value there
        # that reads exactly like a reference is still somebody's config.
        yq -e 'select(.kind == "ConfigMap") | .data.nested.image == "some/thing:1.0"' work/fixture.yaml >/dev/null \
          || fail "retargeting rewrote a ConfigMap value that reads like an image"

        # And a value nobody could pull, in a document that is otherwise fair
        # game. Without this the empty string becomes a bare registry host.
        yq -e 'select(.kind == "Widget") | .spec.image == ""' work/fixture.yaml >/dev/null \
          || fail "retargeting gave a registry to something that is not a reference"

        touch $out
      '';

  image-retarget-is-a-no-op-without-a-registry =
    pkgs.runCommand "image-retarget-is-a-no-op-without-a-registry" { }
      ''
        mkdir -p work && cp ${retargetFixture} work/fixture.yaml && chmod +w work/fixture.yaml
        ${imageUtil.applyToDir {
          lock = { };
          registry = null;
        } "work"}
        cmp -s work/fixture.yaml ${retargetFixture} || {
          echo "an unset registry changed the manifest" >&2
          diff ${retargetFixture} work/fixture.yaml >&2 || true
          exit 1
        }
        touch $out
      '';

  image-rewrite-is-a-no-op-without-a-lock =
    pkgs.runCommand "image-rewrite-is-a-no-op-without-a-lock" { }
      ''
        mkdir -p work && cp ${fixture} work/fixture.yaml && chmod +w work/fixture.yaml
        ${imageUtil.applyToDir { lock = { }; } "work"}

        # A lab has to build before a lockfile exists, or there is no way to
        # generate one. Byte-identical, not merely unpinned.
        cmp -s work/fixture.yaml ${fixture} || {
          echo "an empty lock changed the manifest" >&2
          diff ${fixture} work/fixture.yaml >&2 || true
          exit 1
        }
        touch $out
      '';
}
