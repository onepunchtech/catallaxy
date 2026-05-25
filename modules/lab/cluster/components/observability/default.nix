{ ... }:

{
  imports = [
    ./grafana.nix
    ./loki.nix
    ./prometheus.nix
    ./tempo.nix
    ./otel-collector.nix
  ];

}
