{ ... }:
{
  lab.name = "gitops.local";

  # Its own host ports, so this lab can be up beside another. Everything
  # else is already named after the lab; the ports are the one thing that
  # has to be given on purpose. `lab-host-ports` checks they stay distinct.
  lab.proxy.httpPort = 8084;
  lab.proxy.httpsPort = 9446;
  lab.registry.port = 5055;
  lab.egress.port = 3133;
  lab.dns.hostPort = 5360;
  lab.environment = "development";

  lab.network.dockerSubnet = "172.24.0.0/16";

  lab.dns.enable = true;
  lab.registry.enable = true;
  lab.proxy.enable = true;

  lab.secrets.stores.app.backend = "env";
  lab.secrets.envFile = "examples/labs/gitops/envs/ci.env";
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
