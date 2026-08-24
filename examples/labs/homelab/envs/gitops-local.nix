{ config, ... }:
let
  manifestsHost = "git.homelab.test";
  manifestsRepo = "https://${manifestsHost}/infrastructure/manifests.git";
in
{
  lab.name = "homelab.gitops-local";

  # Its own host ports, so this lab can be up beside another. Everything
  # else is already named after the lab; the ports are the one thing that
  # has to be given on purpose. `lab-host-ports` checks they stay distinct.
  lab.proxy.httpPort = 8083;
  lab.proxy.httpsPort = 9445;
  lab.registry.port = 5054;
  lab.egress.port = 3132;
  lab.dns.hostPort = 5359;
  lab.environment = "development";

  lab.secrets.envFile = "examples/labs/homelab/envs/ci.env";

  lab.network.dockerSubnet = "172.23.0.0/16";

  lab.dns.enable = true;
  lab.registry.enable = true;
  lab.proxy.enable = true;

  lab.cd.strategy = "argocd";
  lab.cd.argocd = {

    repoUrl = "ssh://git@forgejo-ssh.forgejo.svc.cluster.local:2222/infrastructure/manifests.git";
    targetBranch = "main";
  };
  lab.cd.git = {

    repo = "https://git.homelab.test/infrastructure/manifests.git";
    branch = "main";
    provider = "forgejo";
    credentialFromKubeSecret = {
      context = "k3d-homelab-gitops-local-core";
      namespace = "forgejo";
      name = "platform-bot-token";
      key = "token";
      username = "platform-bot";
    };
  };

  lab.clusters.core =
    { config, lab, ... }:
    {
      imports = [
        ../clusters/core.nix
        ../provisioners/k3d.nix
      ];
      provisioner.k3d.network = lab.name;

      floes.forgejo.bootstrap = {
        enable = true;
        orgs = [ "infrastructure" ];

        repos.manifests = {
          org = "infrastructure";
          description = "Catallaxy-rendered manifests for homelab.gitops-local";
        };
        deployKeys.manifests = {
          org = "infrastructure";
          repo = "manifests";
          targetSecret = {
            namespace = "argocd";
            name = "manifests-repo";
          };
        };
      };

      # The token the bootstrap mints for the repository, so a cluster that
      # is not this one can read it. obs subscribes below.
      secrets.publish.platform-bot-token = {
        namespace = config.floes.forgejo.namespace;
      };
    };

  # obs reconciles itself from the same repository core publishes to. The
  # address differs because the git server runs on core: core reaches it by
  # its in-cluster service, and obs reaches it by the lab hostname through
  # the ingress, which is the only address both clusters agree on.
  lab.clusters.obs =
    { config, lab, ... }:
    {
      imports = [ ../provisioners/k3d.nix ];
      provisioner.k3d.network = lab.name;

      cluster.cd.repoUrl = manifestsRepo;

      floes.argocd = {
        enable = true;
        domain = "argocd-obs.${lab.dns.zone}";
        tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;

        # The registration itself arrives as a Secret from the subscription
        # below, credentials and all. This only says whose certificate the
        # lab CA signed, so argocd can verify the host that registration
        # points at.
        tls.labCAHosts = [ manifestsHost ];
      };

      # The repository registration argocd here reads, built from the token
      # core minted for it. The bootstrap that creates that token runs on
      # core and can only write a Secret into core, so it travels the way
      # every other runtime credential in this lab travels: core pushes it to
      # the lab's store, obs reads it back.
      #
      secrets.subscribe.platform-bot-token = {
        from = "core";
        namespace = "argocd";
        secret = "manifests-repo";

        labels."argocd.argoproj.io/secret-type" = "repository";

        fields = {
          type = "git";
          url = manifestsRepo;
          username = "platform-bot";
          password = "{{ .token }}";
        };
      };
    };
}
