{ config, lib, ... }:

let
  inherit ((import ../../../modules/lab/cluster/floe-options.nix { inherit lib; }))
    floeOptions
    ;
  infra = import ../../../lib/infra/ref.nix { inherit lib; };

  # The producer: a floe that needs something provisioned and offers what it
  # will be called. `bucketArn` does not exist at eval and cannot: it is a
  # reference, and the whole point is that a consumer can depend on it anyway.
  storage =
    { config, lib, ... }:
    {
      imports = [ (floeOptions { name = "storage"; }) ];

      options.floes.storage.exports.bucketId = lib.mkOption {
        type = infra.refType;
        description = "The backup bucket's id, once the stack that creates it has applied.";
      };

      config = lib.mkIf config.floes.storage.enable {
        floes.storage.exports.bucketId = infra.ref "backups" "id";

        floes.storage.infra.resources.backups = {
          provider = "local";
          type = "local_file";
          inputs = {
            filename = "backups.txt";
            content = "a bucket stands in for a bucket";
          };
          outputs = [
            "id"
            "content_md5"
          ];
          publish.id = {
            store = "runtime";
            key = "BACKUP_BUCKET_ID";
          };
        };
      };
    };

  # The consumer: reads the producer's export and hands it to another
  # resource. Neither floe repeats what a bucket is, and the reference is
  # resolved through the producing resource's own type at render.
  backups =
    { config, lib, ... }:
    {
      imports = [ (floeOptions { name = "backups"; }) ];

      config = lib.mkIf config.floes.backups.enable {
        floes.backups.infra.resources.policy = {
          provider = "local";
          type = "local_file";
          inputs = {
            filename = "policy.txt";
            content = config.floes.storage.exports.bucketId;
          };
        };
      };
    };

  cluster = config.lab.clusters.app;
  stackJson =
    name:
    builtins.fromJSON (builtins.readFile "${config.lab.out.infra.${name}}/infra/${name}/main.tf.json");

  stack = stackJson "after-clusters";
in
{
  lab.name = "infra";
  lab.environment = "development";
  lab.dns.zone = "infra.test";

  lab.secrets.stores.runtime = {
    backend = "vault";
    vault.server = "https://vault.infra.test";
  };

  lab.clusters.app =
    { ... }:
    {
      imports = [
        storage
        backups
      ];

      cluster.name = "app";
      cluster.provisioner = "k3d";

      floes.storage.enable = true;
      floes.backups.enable = true;
    };

  lab.assertions = [
    {
      assertion = cluster.infra.resources ? backups && cluster.infra.resources ? policy;
      message = "a floe's infra resources were not lifted into the cluster";
    }
    {
      assertion = config.lab.infra.resources ? app-backups;
      message = ''
        a cluster's infra resources reached the lab without the cluster's
        name: got ${builtins.toJSON (builtins.attrNames config.lab.infra.resources)}.

        A stack's state is one namespace, so two clusters asking for the
        same thing have to arrive under different names.
      '';
    }
    {
      assertion = infra.isRef cluster.floes.storage.exports.bucketId;
      message = "a floe could not export a value that does not exist yet";
    }

    # The claim this fixture exists for: what terraform reads carries the
    # interpolation, so the consumer really did depend on a value neither
    # floe knew.
    {
      assertion = stack.resource.local_file.app-policy.content == "\${local_file.app-backups.id}";
      message = ''
        the rendered stack did not resolve a reference: got
        ${builtins.toJSON (stack.resource.local_file.app-policy.content or null)}.

        A reference resolves through the *target's* type, so the consumer
        never has to repeat what the producer is.
      '';
    }
    {
      assertion = stack.output ? app-backups_id;
      message = "a declared output was not emitted, so nothing outside the stack could read it";
    }
    {
      assertion = stack.terraform.backend.local.path == "after-clusters.tfstate";
      message = ''
        the backend was not derived per stack: got
        ${builtins.toJSON (stack.terraform.backend.local.path or null)}.

        One backend declaration covers every stack, and each gets its own key
        from it. Two sharing one is the worst thing this can do.
      '';
    }
  ];
}
