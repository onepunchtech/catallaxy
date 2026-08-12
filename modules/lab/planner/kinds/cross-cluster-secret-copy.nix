{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = true;
  dryRunSafe = false;
  params.options = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Label for this copy, shown in plan output.";
    };
    sourceCluster = lib.mkOption {
      type = lib.types.str;
      description = "Cluster the Secret is read from.";
    };
    sourceNamespace = lib.mkOption {
      type = lib.types.str;
      description = "Namespace the Secret is read from.";
    };
    sourceSecret = lib.mkOption {
      type = lib.types.str;
      description = "Name of the Secret to read.";
    };
    targetCluster = lib.mkOption {
      type = lib.types.str;
      description = "Cluster the Secret is written to.";
    };
    targetNamespace = lib.mkOption {
      type = lib.types.str;
      description = "Namespace the Secret is written to.";
    };
    targetSecret = lib.mkOption {
      type = lib.types.str;
      description = "Name to write the Secret under.";
    };
    secretType = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kubernetes Secret type to write, when it differs from the source.";
    };
    sourceContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context for the read. Defaults to the source cluster's runtime context.";
    };
    targetContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context for the write. Defaults to the target cluster's runtime context.";
    };
  };
}
