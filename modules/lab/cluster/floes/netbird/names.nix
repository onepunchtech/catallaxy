{ }:
{
  clusterRouterKeyName = "cluster-router";

  operatorKeyName = "operator";

  setupKeySecretName = name: "setup-key-${name}";

  setupKeySecretKey = "setup-key";

  jwtGroupUuidsSecretName = "netbird-jwt-group-uuids";

  managedBy = {
    "app.kubernetes.io/managed-by" = "catallaxy";
  };

  owner = {
    bootstrap = "install-target";
    steady = "argocd";
  };
}
