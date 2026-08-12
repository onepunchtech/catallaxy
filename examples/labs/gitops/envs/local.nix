{ ... }:
{
  lab.name = "gitops.local";
  lab.environment = "development";

  lab.network.dockerSubnet = "172.24.0.0/16";

  lab.dns.enable = true;
  lab.dns.configureHost = true;
  lab.registry.enable = true;
  lab.proxy.enable = true;

  lab.secrets.stores.app.backend = "env";
  lab.secrets.envFile = ./ci.env;
  lab.secrets.managed.session-key = {
    store = "app";
    keys.secret = {
      generator = "base64";
      length = 32;
    };
  };

  lab.cd.strategy = "argocd";
  lab.cd.argocd = {
    repoUrl = "ssh://git@forgejo-ssh.forgejo.svc.cluster.local:2222/infrastructure/manifests.git";
    targetBranch = "main";
  };
  lab.cd.git = {
    repo = "https://git.gitops.test/infrastructure/manifests.git";
    branch = "main";
    provider = "forgejo";
    credentialFromKubeSecret = {
      context = "k3d-gitops-local-core";
      namespace = "forgejo";
      name = "platform-bot-token";
      key = "token";
      username = "platform-bot";
    };
  };

  lab.clusters.core =
    { lab, ... }:
    {
      imports = [ ../provisioners/k3d.nix ];
      provisioner.k3d.network = lab.name;

      floes.forgejo.bootstrap = {
        enable = true;
        orgs = [ "infrastructure" ];
        repos.manifests = {
          org = "infrastructure";
          description = "Catallaxy-rendered manifests for gitops.local";
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
    };
}
