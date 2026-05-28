{
  lib,
  pkgs,
  kubelib,
}:

let
  inherit (kubelib) downloadHelmChart;

  # Extract CRDs from a helm chart's crds/ directory
  extractChartCrds =
    name: chart:
    pkgs.runCommand "${name}-crds.yaml" { } ''
      if [ -d "${chart}/crds" ] && ls "${chart}"/crds/*.yaml 1>/dev/null 2>&1; then
        for f in "${chart}"/crds/*.yaml; do
          printf '\n---\n' >> $out
          cat "$f" >> $out
        done
      else
        touch $out
      fi
    '';

  # Fetch source from GitHub and concatenate CRDs from a directory
  extractGitHubCrds =
    name: def:
    let
      src = pkgs.fetchFromGitHub {
        inherit (def)
          owner
          repo
          rev
          hash
          ;
      };
    in
    pkgs.runCommand "${name}-crds.yaml" { } ''
      find "${src}/${def.crdPath}" -name '*.yaml' -type f | sort | while read -r f; do
        printf '\n---\n' >> $out
        cat "$f" >> $out
      done
    '';

  # Extract CRDs from a components.yaml manifest (CAPI providers, etc.)
  # Downloads the full manifest and filters for kind: CustomResourceDefinition
  extractComponentsCrds =
    name: def:
    let
      src = pkgs.fetchurl {
        inherit (def) url hash;
        name = "${name}-components.yaml";
      };
    in
    pkgs.runCommand "${name}-crds.yaml" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      yq 'select(.kind == "CustomResourceDefinition")' ${src} > $out
      # Ensure file isn't empty
      if [ ! -s "$out" ]; then
        touch $out
      fi
    '';

  # Build a CRD derivation from a crdDef
  buildCrds =
    name: chartDrv: crdDef:
    if crdDef == null then
      null
    else if crdDef.type == "url" then
      pkgs.fetchurl {
        inherit (crdDef) url hash;
        name = "${name}-crds.yaml";
      }
    else if crdDef.type == "chart" then
      extractChartCrds name chartDrv
    else if crdDef.type == "github" then
      extractGitHubCrds name crdDef
    else if crdDef.type == "components" then
      extractComponentsCrds name crdDef
    else
      throw "Unknown CRD type: ${crdDef.type}";

  # Chart definitions — all managed with explicit versions
  # Each entry has: repo, chart, version, chartHash, and optional crd
  chartDefs = {
    cilium = {
      repo = "https://helm.cilium.io";
      chart = "cilium";
      version = "1.17.2";
      chartHash = "sha256-l+9fEAb2wb9xAx/HCW/pXW5+MfzbgnSpWk7UOTkpK24=";
      crd = {
        type = "github";
        owner = "cilium";
        repo = "cilium";
        rev = "v1.17.2";
        hash = "sha256-VVdKGJKCM8Kq4fLeONyv+mbNbl6FRUAfCtmmUg6Wc00=";
        crdPath = "pkg/k8s/apis/cilium.io/client/crds";
      };
    };

    trust-manager = {
      repo = "https://charts.jetstack.io";
      chart = "trust-manager";
      version = "0.22.1";
      chartHash = "sha256-No3nepftJ5d9+5eXkgDCR4iAKun46a3rbI+uz4FxGSw=";
    };

    cert-manager = {
      repo = "https://charts.jetstack.io";
      chart = "cert-manager";
      version = "1.17.2";
      chartHash = "sha256-8d/BPet3MNGd8n0r5F1HEW4Rgb/UfdtwqSFuUZTyKl4=";
      crd = {
        type = "url";
        url = "https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.crds.yaml";
        hash = "sha256-uV5UEebfhwdm3May91pRmPwFS+YUM5L6KDzfi0BMfzU=";
      };
    };

    argocd = {
      repo = "https://argoproj.github.io/argo-helm";
      chart = "argo-cd";
      version = "8.0.2";
      chartHash = "sha256-fpBQ8guYb9mY/r5WEzXeSFyCkDcac6PX74+M+MdNu98=";
      crd = {
        type = "github";
        owner = "argoproj";
        repo = "argo-cd";
        rev = "v3.0.1";
        hash = "sha256-NjCmtI4cehlK4rCMTxhtIcf7fBDzQwj11h3XamU+Muo=";
        crdPath = "manifests/crds";
      };
    };

    prometheus = {
      repo = "https://prometheus-community.github.io/helm-charts";
      chart = "kube-prometheus-stack";
      version = "72.5.0";
      chartHash = "sha256-o/Yzswcv3ydTq6rrP+Ot9SeylGD6N0Bi9WB6GcOVTx4=";
      crd = {
        type = "url";
        url = "https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.82.2/stripped-down-crds.yaml";
        hash = "sha256-3mkDUyIqXqtAkpHOlfCs7DNw90/x1+B9SSH/hsn56CE=";
      };
    };

    grafana = {
      repo = "https://grafana.github.io/helm-charts";
      chart = "grafana";
      version = "10.5.15";
      chartHash = "sha256-Mu0AEXTV5xU9zMrmFkHWJRQyOrmDSZeMwKMXEpS7Gy8=";
    };

    loki = {
      repo = "https://grafana.github.io/helm-charts";
      chart = "loki";
      version = "6.30.1";
      chartHash = "sha256-591a/wtRZmhpeuOAbTfxaT0jZn+mgEU2STBhQI6GbfE=";
    };

    tempo = {
      repo = "https://grafana.github.io/helm-charts";
      chart = "tempo";
      version = "1.21.0";
      chartHash = "sha256-qAqIV12yS0am46ekdrOCT/LYryZh8aHg1Fzc0aBaEbs=";
    };

    otel-collector = {
      repo = "https://open-telemetry.github.io/opentelemetry-helm-charts";
      chart = "opentelemetry-collector";
      version = "0.156.0";
      chartHash = "sha256-rltQ1AOliiNVwhBkU24G0c4uRZj46TUepGG9Oh38GQg=";
    };

    external-dns = {
      repo = "https://kubernetes-sigs.github.io/external-dns";
      chart = "external-dns";
      version = "1.16.1";
      chartHash = "sha256-0Hda7wKttTw9o2h21xFg0DB9DxEceh+XUEJ5mzBuM78=";
      crd = {
        type = "chart";
      };
    };

    external-secrets = {
      repo = "https://charts.external-secrets.io";
      chart = "external-secrets";
      version = "0.15.0";
      chartHash = "sha256-i5r9ZqdEeTKA1o7kAfviQpxzJwCm+c8JOPE+BH2t/po=";
      crd = {
        type = "url";
        url = "https://raw.githubusercontent.com/external-secrets/external-secrets/v0.15.0/deploy/crds/bundle.yaml";
        hash = "sha256-fRPzilKE4AQ0cR06JT6uX0dGAsJ/t3V+kQLOV3lbo0c=";
      };
    };

    velero = {
      repo = "https://vmware-tanzu.github.io/helm-charts";
      chart = "velero";
      version = "9.0.1";
      chartHash = "sha256-NVP7yEKFy4ySfXRNJpWJpIyvnmnoxBAqe6TpLtwkBoU=";
      crd = {
        type = "chart";
      };
    };

    crossplane = {
      repo = "https://charts.crossplane.io/stable";
      chart = "crossplane";
      version = "1.18.2";
      chartHash = "sha256-udEOCSnF4fdiCYJ1utlJPLaiLzG8enRY2Z4OYjopESA=";
      crd = {
        type = "github";
        owner = "crossplane";
        repo = "crossplane";
        rev = "v1.18.2";
        hash = "sha256-G4Kve77BoQ/RphvggLHIVV+hhkjmTS3q1nQWnDhAjHA=";
        crdPath = "cluster/crds";
      };
    };

    cnpg = {
      repo = "https://cloudnative-pg.github.io/charts";
      chart = "cloudnative-pg";
      version = "0.23.0";
      chartHash = "sha256-KCbQLH62HiY45GI56GqlTKFBBpBXKrAlh558wnRvLYk=";
      crd = {
        type = "github";
        owner = "cloudnative-pg";
        repo = "cloudnative-pg";
        rev = "v1.25.0";
        hash = "sha256-pU8OgGmRzZEfcMOhMHXhwK+oA/6zyj7F7QZ0ZNJIjsQ=";
        crdPath = "config/crd/bases";
      };
    };

    redis-operator = {
      repo = "https://ot-container-kit.github.io/helm-charts";
      chart = "redis-operator";
      version = "0.18.2";
      chartHash = "sha256-n6mICvnMxLXLcRN93oND0EzF6qn/EjXiJnOunXJQLw4=";
      crd = {
        type = "chart";
      };
    };

    local-path-provisioner = {
      repo = "https://charts.containeroo.ch";
      chart = "local-path-provisioner";
      version = "0.0.30";
      chartHash = "sha256-oJrU/MWNYKA3/OhBjX7Py/hDKio4Zs7Ta1qfa+Eo7r4=";
    };

    seaweedfs = {
      repo = "https://seaweedfs.github.io/seaweedfs/helm";
      chart = "seaweedfs";
      version = "4.0.0";
      chartHash = "sha256-8iW/unqfCVGeYFy8XPh7E9chH6bzyX3u+x3lgxSa6e0=";
    };

    traefik = {
      repo = "https://traefik.github.io/charts";
      chart = "traefik";
      version = "35.2.0";
      chartHash = "sha256-E6CY8pKAhLhRuJL1ZtgUXSHlcLVyb0+Nhbe6kFvryD0=";
    };

    netbird = {
      repo = "https://charts.jaconi.io";
      chart = "netbird";
      version = "0.15.0";
      chartHash = "sha256-pdlGztaE1G5W4CDlSRdy55/PBdFKjY3+GGGUUO6mpkU=";
    };

    kanidm = {
      repo = "https://datosh.github.io/kanidm";
      chart = "kanidm";
      version = "0.2.1";
      chartHash = "sha256-toHedI3JT/A3ff2E7O2BYtoA2twEr0XlYig7DmEacFY=";
    };

    forgejo = {
      repo = "oci://codeberg.org/forgejo-contrib";
      chart = "forgejo";
      version = "5.1.0";
      chartHash = "sha256-NVImZhZY6u1CN4C/6jCXl/SVz35NTtewK+bgGBj3oPE=";
    };

    zot = {
      repo = "https://zotregistry.dev/helm-charts";
      chart = "zot";
      version = "0.1.113";
      chartHash = "sha256-BGBIoJwU0wMAxD5vFb6WE6n/vhTyEvYwwgrmOMAQlrI=";
    };

    kaniop = {
      repo = "oci://ghcr.io/pando85/helm-charts";
      chart = "kaniop";
      version = "0.6.1";
      chartHash = "sha256-jZdmj7bxUEOg1fAsBuLlUhN1bmoymOKSfCk0G0Fz3MQ=";
      crd = {
        type = "chart";
      };
    };

    capi-operator = {
      repo = "https://kubernetes-sigs.github.io/cluster-api-operator";
      chart = "cluster-api-operator";
      version = "0.14.0";
      chartHash = "sha256-X/YFe4IUpcTVnfO/pFkBGxOd0EkWn9OWGEr/hB8amQs=";
      crd = {
        type = "github";
        owner = "kubernetes-sigs";
        repo = "cluster-api-operator";
        rev = "v0.14.0";
        hash = "sha256-sc0oX9UqMg7e4pe7EfeT+r9430cgnCCfAgnJcPDkjOY=";
        crdPath = "config/crd/bases";
      };
    };

    # Uses local-path-provisioner chart, no separate chart
    openebs = {
      repo = "https://charts.containeroo.ch";
      chart = "local-path-provisioner";
      version = "0.0.30";
      chartHash = "sha256-oJrU/MWNYKA3/OhBjX7Py/hDKio4Zs7Ta1qfa+Eo7r4=";
    };
  };

  # Build final chart entries: { chart, crds, version } per name
  charts = lib.mapAttrs (
    name: def:
    let
      chartDrv = downloadHelmChart {
        inherit (def)
          repo
          chart
          version
          chartHash
          ;
      };
      crdDef = def.crd or null;
    in
    {
      chart = chartDrv;
      crds = buildCrds name chartDrv crdDef;
      inherit (def) version;
    }
  ) chartDefs;

  # CAPI provider CRDs — extracted from GitHub release components.yaml files
  capiProviderCrdDefs = {
    capi-core = {
      type = "components";
      url = "https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.9.0/core-components.yaml";
      hash = "sha256-ISIBsj7f9kxrf7LmH7CF+cKWEA2ha9iUWYwYYh3ABHA=";
    };
    capi-kubeadm-bootstrap = {
      type = "components";
      url = "https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.9.0/bootstrap-components.yaml";
      hash = "sha256-zmTCw82f2JWSV47Xonoo5fF+PnBECBCKirVqbnrjo/0=";
    };
    capi-kubeadm-control-plane = {
      type = "components";
      url = "https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.9.0/control-plane-components.yaml";
      hash = "sha256-qQr127IkZ+tVUq3Xga+gV/N1q6mltPzTAep/T+ttroM=";
    };
    capi-digitalocean = {
      type = "components";
      url = "https://github.com/kubernetes-sigs/cluster-api-provider-digitalocean/releases/download/v1.6.0/infrastructure-components.yaml";
      hash = "sha256-4LrSpO/m3GsvtHM4uSldjHXzeyqYNiBwsAngpI4MLRk=";
    };
  };

  capiProviderCrds = lib.mapAttrs (
    name: def: buildCrds name null def
  ) capiProviderCrdDefs;

  # Crossplane provider CRDs — extracted from GitHub sources at build time
  crossplaneProviderCrdDefs = {
    provider-upjet-digitalocean = {
      type = "github";
      owner = "crossplane-contrib";
      repo = "provider-upjet-digitalocean";
      rev = "v0.3.2";
      hash = "sha256-cjXzxe/agUa7kN0uhxCg3MGAfmAO7E1B9Q79MCj6fIc=";
      crdPath = "package/crds";
    };
    provider-upjet-cloudflare = {
      type = "github";
      owner = "wildbitca";
      repo = "provider-upjet-cloudflare";
      rev = "v0.2.5";
      hash = "sha256-UXaCmII2GuLjMeErqGG5yVoFYFPpSW0gdvb80P9cAHY=";
      crdPath = "package/crds";
    };
  };

  crossplaneProviderCrds = lib.mapAttrs (
    name: def: buildCrds name null def
  ) crossplaneProviderCrdDefs;

in
charts // { inherit capiProviderCrds crossplaneProviderCrds; }
