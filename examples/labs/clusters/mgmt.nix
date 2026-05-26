# Management cluster — CAPI + Crossplane controllers
{ ... }:
{
  cluster = {
    name = "mgmt";
    provisioner = "k3d";
    kubernetes = {
      distribution = "k3s";
      controlPlanes = 1;
      workers = 0;
    };
  };

  components.cert-manager = {
    enable = true;
    selfSignedCA.enable = true;
  };

  components.cluster-api = {
    enable = true;
    isManagementCluster = true;
    bootstrapProviders = [ "kubeadm" ];
    controlPlaneProviders = [ "kubeadm" ];
  };

  components.crossplane.enable = true;

  components.pki-auth.enable = false;
  components.oidc.enable = false;
}
