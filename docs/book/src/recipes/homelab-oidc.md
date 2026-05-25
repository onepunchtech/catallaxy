# Homelab OIDC Setup

This recipe walks through standing up the example homelab with full OIDC authentication. By the end, you will have a local Kubernetes lab where ArgoCD, Grafana, and Forgejo all authenticate through Kanidm as the identity provider.

## Prerequisites

- Nix with flakes enabled
- Docker (for k3d)
- Enter the dev shell: `nix develop`

## Step 1: Start the lab

```bash
cata --flake ./examples/labs#homelab lab up
```

This provisions all clusters defined in the lab (by default, a `core` cluster and an `obs` cluster via k3d), evaluates the Nix modules, renders manifests, and applies them phase by phase. The process takes several minutes on first run as Helm charts are templated and resources are deployed in dependency order.

## Step 2: Trust the lab CA

```bash
cata --flake ./examples/labs#homelab lab trust --setup
```

The lab generates its own certificate authority. This command installs the lab CA into your system trust store so that browsers and CLI tools accept TLS certificates issued for `*.homelab.test` domains without warnings.

To remove the CA later:

```bash
cata --flake ./examples/labs#homelab lab trust --teardown
```

## Step 3: Configure local DNS

```bash
cata --flake ./examples/labs#homelab lab dns --setup
```

This configures your local resolver so that `*.homelab.test` domains resolve to `127.0.0.1` (where k3d exposes its ingress). The exact mechanism depends on your OS (systemd-resolved, dnsmasq, etc.).

To remove the DNS configuration later:

```bash
cata --flake ./examples/labs#homelab lab dns --teardown
```

## Step 4: Initialize a user account

```bash
cata --flake ./examples/labs#homelab lab ops init-user lab-admin
```

This resets (or creates) the `lab-admin` account in Kanidm and prints a temporary password. The `init-user` command is a lab ops command -- it understands the lab topology. It knows which cluster runs Kanidm, which namespace the pod lives in, and how to exec into it. You do not need to figure out contexts or namespaces yourself.

Lab ops commands are defined in the lab's Nix configuration and have full access to component refs:

```nix
lab.ops.commands.init-user = {
  description = "Reset a kanidm account password";
  package = pkgs.writeShellApplication {
    name = "init-user";
    runtimeInputs = [ pkgs.kubectl ];
    text = ''
      kubectl --context k3d-core exec -n ${kanidmRef.namespace} kanidm-default-0 -- \
        kanidmd recover-account "$1"
    '';
  };
};
```

## Step 5: Log in to Kanidm

Open [https://kanidm.homelab.test](https://kanidm.homelab.test) in your browser. Log in with the `lab-admin` username and the temporary password from the previous step. You will be prompted to set a new password and configure WebAuthn or TOTP.

## Step 6: Access services via OIDC

With your Kanidm account set up, all OIDC-enabled services authenticate through it:

| Service | URL | Notes |
|---------|-----|-------|
| ArgoCD | [https://argocd.homelab.test](https://argocd.homelab.test) | Click "Log in via Kanidm" |
| Grafana | [https://grafana.homelab.test](https://grafana.homelab.test) | Click "Sign in with Kanidm" |
| Forgejo | [https://forgejo.homelab.test](https://forgejo.homelab.test) | Click the Kanidm OAuth2 option |

Each service has its OAuth2 client registered in Kanidm automatically via the kaniop operator. Group memberships in Kanidm map to roles in each service -- for example, members of the `grafana-editors` group get the Editor role in Grafana.

## How it works

The OIDC integration is wired through cross-component references:

1. **cert-manager** issues TLS certificates for all services using the lab CA.
2. **kanidm** runs as the identity provider with its own TLS certificate.
3. **kaniop** manages OAuth2 client registrations in Kanidm declaratively, creating client secrets as Kubernetes Secrets.
4. **Each service** (ArgoCD, Grafana, Forgejo) references the Kanidm OIDC endpoint and its client secret via component `ref` attributes.

Because everything is evaluated at Nix build time, the URLs, namespaces, and secret names are consistent and type-checked. There is no manual coordination between services.

## Troubleshooting

**Browser shows certificate warnings:** Run `cata lab trust --setup` and restart your browser.

**DNS does not resolve:** Run `cata lab dns --setup`. On systemd-resolved systems, you may need to restart the resolver.

**OIDC login fails:** Check that Kanidm is running and the OAuth2 clients are registered:

```bash
kubectl --context k3d-core get oauth2clients -n kanidm
```

**Temporary password expired:** Re-run `cata lab ops init-user lab-admin` to get a fresh one.
