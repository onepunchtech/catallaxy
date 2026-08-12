{
  cluster.provisioner = "k3d";

  provisioner.k3d = {
    image = "rancher/k3s:v1.31.4-k3s1";
    noTraefik = true;
    noServiceLB = false;
    noFlannel = false;
  };
}
