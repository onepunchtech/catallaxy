# Local k3d provisioner — shared across dev/staging environments
{
  cluster.provider = "docker";

  provisioner.k3d = {
    enable = true;
    image = "rancher/k3s:v1.31.4-k3s1";
    noTraefik = true;
    noServiceLB = false;
    noFlannel = false;
  };
}
