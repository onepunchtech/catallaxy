{ lib, ... }:

let
  inherit ((import ../../../../modules/lab/cluster/floe-options.nix { inherit lib; }))
    floeOptions
    ;
  infra = import ../../../../lib/infra/ref.nix { inherit lib; };

  # A floe that needs something provisioned, and offers what it will be
  # called. `marker` does not exist at eval and cannot: the point is that a
  # consumer depends on it anyway.
  seed =
    { config, lib, ... }:
    {
      imports = [ (floeOptions { name = "seed"; }) ];

      options.floes.seed.exports.markerId = lib.mkOption {
        type = infra.refType;
        description = "The marker file's id, once the stack that writes it has applied.";
      };

      config = lib.mkIf config.floes.seed.enable {
        floes.seed.exports.markerId = infra.ref "marker" "id";

        # Needed before a cluster exists, so it is its own stack and its own
        # apply. Nothing names a stack: the phase is the stack.
        floes.seed.infra.resources.marker = {
          phase = "before-clusters";
          provider = "local";
          type = "local_file";
          inputs = {
            filename = "\${path.cwd}/marker.txt";
            content = "catallaxy provisioned this";
          };
          outputs = [ "id" ];

          publish.id = {
            store = "runtime";
            key = "MARKER_ID";
          };
        };

        # After the cluster, and it reads the first stack's export. That pair
        # is the multi-pass case: the value does not exist until the first
        # apply has run, the cluster is created in between, and the second
        # stack reads the value out of the first one's state.
        floes.seed.infra.resources.witness = {
          phase = "after-clusters";
          provider = "null";
          type = "null_resource";
          inputs.triggers.marker = config.floes.seed.exports.markerId;
        };
      };
    };
in
{
  lab.dns.zone = lib.mkDefault "infra.test";

  # An `external` store is a command. That is what makes the set of stores
  # open: this one appends to a file so the e2e can read it back, and a real
  # lab points the same field at whatever it actually keeps secrets in.
  lab.secrets.stores.runtime = {
    backend = "external";
    writer.command = [
      "sh"
      "-c"
      ''printf '%s=%s\n' "$CATA_SECRET_KEY" "$(cat)" >> "$HOME/.local/share/catallaxy/infra/infra.local/published.env"''
    ];
  };

  lab.clusters.app =
    { ... }:
    {
      imports = [ seed ];

      cluster.name = "app";
      cluster.kubernetes = {
        distribution = "k3s";
        controlPlanes = 1;
        workers = 0;
      };

      floes.seed.enable = true;
    };
}
