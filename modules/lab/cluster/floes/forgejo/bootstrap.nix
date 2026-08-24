{
  config,
  lib,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;
  catalLib = import ../../../../../lib/util/idempotent-job.nix { inherit lib; };
  planTokens = import ../../../../../lib/plan-tokens.nix { inherit lib; };
  waitLib = import ../../../../../lib/util/wait.nix { inherit lib; };
  forgejoCfg = config.floes.forgejo;
  cfg = forgejoCfg.bootstrap;

  forgejoInternalUrl = "http://forgejo-http.${forgejoCfg.namespace}.svc.cluster.local:${toString forgejoCfg.server.httpPort}";

  argocdNamespaces = lib.unique (map (dk: dk.targetSecret.namespace) (lib.attrValues cfg.deployKeys));

  script = ''
    set -eu
    log() { echo "[forgejo-bootstrap] $*"; }
    trap 'log "ERROR at line $LINENO"' ERR

    if ! command -v ssh-keygen >/dev/null 2>&1; then
      log "installing openssh-keygen"
      apk add --no-cache openssh-keygen >/dev/null
    fi

    log "checking whether user '$BOT_USERNAME' exists…"
    if ! kubectl -n "$FORGEJO_NS" exec "deploy/$FORGEJO_DEPLOY" -- \
        forgejo admin user list 2>/dev/null | awk '{print $2}' | grep -qx "$BOT_USERNAME"; then
      log "creating '$BOT_USERNAME' (must-change-password=false, admin)"
      kubectl -n "$FORGEJO_NS" exec "deploy/$FORGEJO_DEPLOY" -- \
        forgejo admin user create \
          --username "$BOT_USERNAME" \
          --email "$BOT_USERNAME@bootstrap.local" \
          --random-password \
          --admin \
          --must-change-password=false >/dev/null
    else
      log "'$BOT_USERNAME' already exists"
    fi

    PAT=""
    if kubectl -n "$FORGEJO_NS" get secret "$BOT_TOKEN_SECRET" >/dev/null 2>&1; then
      PAT=$(kubectl -n "$FORGEJO_NS" get secret "$BOT_TOKEN_SECRET" \
        -o jsonpath="{.data.$BOT_TOKEN_KEY}" 2>/dev/null | base64 -d 2>/dev/null || true)
    fi

    if [ -n "$PAT" ]; then
      CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: token $PAT" \
        "$FORGEJO_URL/api/v1/user" || echo 000)
      if [ "$CODE" != "200" ]; then
        log "existing PAT returned HTTP $CODE from /api/v1/user; regenerating"
        PAT=""
      fi
    fi

    if [ -z "$PAT" ]; then
      log "minting new admin PAT for '$BOT_USERNAME'"
      TOKEN_NAME="platform-bootstrap-$(date +%s)"
      RAW=$(kubectl -n "$FORGEJO_NS" exec "deploy/$FORGEJO_DEPLOY" -- \
        forgejo admin user generate-access-token \
          --username "$BOT_USERNAME" \
          --token-name "$TOKEN_NAME" \
          --scopes 'write:admin,write:organization,write:repository,write:user')
      PAT=$(echo "$RAW" | sed -n 's/.*created: //p' | tr -d '\r\n[:space:]')
      if [ -z "$PAT" ]; then
        log "failed to parse token from: $RAW" >&2
        exit 1
      fi
      kubectl -n "$FORGEJO_NS" create secret generic "$BOT_TOKEN_SECRET" \
        --from-literal="$BOT_TOKEN_KEY=$PAT" \
        --dry-run=client -o yaml | kubectl apply -f -
      log "wrote $FORGEJO_NS/$BOT_TOKEN_SECRET"
    else
      log "existing PAT validated"
    fi
    AUTH=(-H "Authorization: token $PAT" -H 'Content-Type: application/json')

    echo "$ORGS_JSON" | jq -r '.[]' | while IFS= read -r ORG; do
      [ -z "$ORG" ] && continue
      CODE=$(curl -s -o /dev/null -w '%{http_code}' "''${AUTH[@]}" \
        "$FORGEJO_URL/api/v1/orgs/$ORG")
      if [ "$CODE" = "200" ]; then
        log "org '$ORG' already exists"
      elif [ "$CODE" = "404" ]; then
        log "creating org '$ORG'"
        curl -sf -X POST "''${AUTH[@]}" \
          -d "$(jq -n --arg u "$ORG" --arg v "$ORG_VISIBILITY" \
                '{ username: $u, visibility: $v }')" \
          "$FORGEJO_URL/api/v1/orgs" >/dev/null
      else
        log "unexpected HTTP $CODE probing org '$ORG'" >&2
        exit 1
      fi
    done

    echo "$REPOS_JSON" | jq -c '.[]' | while IFS= read -r R; do
      ORG=$(echo "$R" | jq -r '.org')
      REPO=$(echo "$R" | jq -r '.repo')
      DESC=$(echo "$R" | jq -r '.description // ""')
      PRIVATE=$(echo "$R" | jq -r '.private')
      CODE=$(curl -s -o /dev/null -w '%{http_code}' "''${AUTH[@]}" \
        "$FORGEJO_URL/api/v1/repos/$ORG/$REPO")
      if [ "$CODE" = "200" ]; then
        log "repo '$ORG/$REPO' already exists"
      elif [ "$CODE" = "404" ]; then
        log "creating repo '$ORG/$REPO' (private=$PRIVATE, auto_init=true)"
        curl -sf -X POST "''${AUTH[@]}" \
          -d "$(jq -n \
              --arg name "$REPO" \
              --arg desc "$DESC" \
              --argjson priv "$PRIVATE" \
              '{ name: $name, description: $desc, private: $priv, auto_init: true, default_branch: "main" }')" \
          "$FORGEJO_URL/api/v1/orgs/$ORG/repos" >/dev/null
      else
        log "unexpected HTTP $CODE probing repo '$ORG/$REPO'" >&2
        exit 1
      fi
    done

    echo "$DEPLOY_KEYS_JSON" | jq -c '.[]' | while IFS= read -r K; do
      ORG=$(echo "$K" | jq -r '.org')
      REPO=$(echo "$K" | jq -r '.repo')
      SNS=$(echo "$K" | jq -r '.secretNs')
      SN=$(echo "$K" | jq -r '.secretName')
      RO=$(echo "$K" | jq -r '.readOnly')
      SSH_HOST=$(echo "$K" | jq -r '.sshHostForUrl')
      SSH_PORT=$(echo "$K" | jq -r '.sshPortForUrl')

      EXISTING_KEY=""
      if kubectl -n "$SNS" get secret "$SN" >/dev/null 2>&1; then
        EXISTING_KEY=$(kubectl -n "$SNS" get secret "$SN" \
          -o jsonpath='{.data.sshPrivateKey}' 2>/dev/null | base64 -d 2>/dev/null || true)
      fi

      KEY_TITLE="argocd-$SNS-$SN"
      NEED_MINT="true"
      if [ -n "$EXISTING_KEY" ]; then
        WORKDIR=$(mktemp -d)
        printf '%s' "$EXISTING_KEY" > "$WORKDIR/id"
        chmod 600 "$WORKDIR/id"
        EXISTING_PUB=$(ssh-keygen -y -f "$WORKDIR/id" 2>/dev/null || true)
        rm -rf "$WORKDIR"
        if [ -n "$EXISTING_PUB" ]; then
          REMOTE_KEYS=$(curl -sf "''${AUTH[@]}" \
            "$FORGEJO_URL/api/v1/repos/$ORG/$REPO/keys" 2>/dev/null || echo '[]')
          if echo "$REMOTE_KEYS" | jq -e --arg k "$(echo "$EXISTING_PUB" | awk '{print $1" "$2}')" \
              '.[] | select(.key | startswith($k))' >/dev/null 2>&1; then
            log "deploy key for '$ORG/$REPO' already registered; no-op"
            NEED_MINT="false"
          else
            log "existing key not registered on '$ORG/$REPO': will re-register"
          fi
        fi
      fi

      if [ "$NEED_MINT" = "true" ]; then
        WORKDIR=$(mktemp -d)
        ssh-keygen -q -t ed25519 -N "" -C "$KEY_TITLE" -f "$WORKDIR/id"
        PUB=$(cat "$WORKDIR/id.pub")
        PRIV=$(cat "$WORKDIR/id")

        curl -sf "''${AUTH[@]}" "$FORGEJO_URL/api/v1/repos/$ORG/$REPO/keys" \
          | jq -r --arg t "$KEY_TITLE" '.[] | select(.title==$t) | .id' \
          | while read -r KID; do
              [ -z "$KID" ] && continue
              curl -sf -X DELETE "''${AUTH[@]}" \
                "$FORGEJO_URL/api/v1/repos/$ORG/$REPO/keys/$KID" >/dev/null
            done

        log "uploading new deploy key '$KEY_TITLE' to '$ORG/$REPO' (read_only=$RO)"
        curl -sf -X POST "''${AUTH[@]}" \
          -d "$(jq -n \
              --arg t "$KEY_TITLE" \
              --arg k "$PUB" \
              --argjson ro "$RO" \
              '{ title: $t, key: $k, read_only: $ro }')" \
          "$FORGEJO_URL/api/v1/repos/$ORG/$REPO/keys" >/dev/null

        URL="ssh://git@$SSH_HOST:$SSH_PORT/$ORG/$REPO.git"
        cat <<EOF | kubectl apply -f -
    apiVersion: v1
    kind: Secret
    metadata:
      name: $SN
      namespace: $SNS
      labels:
        argocd.argoproj.io/secret-type: repository
        app.kubernetes.io/managed-by: catallaxy
    type: Opaque
    stringData:
      type: git
      url: $URL
      insecureIgnoreHostKey: "true"
      sshPrivateKey: |
    $(echo "$PRIV" | sed 's/^/    /')
    EOF
        log "wrote $SNS/$SN"
        rm -rf "$WORKDIR"
      fi
    done

    log "bootstrap complete"
  '';

  rbac =
    let
      saLabels."app.kubernetes.io/managed-by" = "catallaxy";
    in
    {
      forgejo-bootstrap-sa = {
        apiVersion = "v1";
        kind = "ServiceAccount";
        metadata = {
          name = "forgejo-bootstrap";
          namespace = forgejoCfg.namespace;
          labels = saLabels;
        };
      };
      forgejo-bootstrap-role = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        metadata = {
          name = "forgejo-bootstrap";
          namespace = forgejoCfg.namespace;
          labels = saLabels;
        };
        rules = [
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [
              "get"
              "list"
              "create"
              "update"
              "patch"
            ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "pods" ];
            verbs = [
              "get"
              "list"
            ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "pods/exec" ];
            verbs = [ "create" ];
          }
          {
            apiGroups = [ "apps" ];
            resources = [ "deployments" ];

            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
        ];
      };
      forgejo-bootstrap-rb = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        metadata = {
          name = "forgejo-bootstrap";
          namespace = forgejoCfg.namespace;
          labels = saLabels;
        };
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = "forgejo-bootstrap";
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = "forgejo-bootstrap";
            namespace = forgejoCfg.namespace;
          }
        ];
      };
    }
    // lib.listToAttrs (
      lib.concatMap (ns: [
        {
          name = "forgejo-bootstrap-role-${ns}";
          value = {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "Role";
            metadata = {
              name = "forgejo-bootstrap";
              namespace = ns;
              labels = saLabels;
            };
            rules = [
              {
                apiGroups = [ "" ];
                resources = [ "secrets" ];
                verbs = [
                  "get"
                  "create"
                  "update"
                  "patch"
                ];
              }
            ];
          };
        }
        {
          name = "forgejo-bootstrap-rb-${ns}";
          value = {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "RoleBinding";
            metadata = {
              name = "forgejo-bootstrap";
              namespace = ns;
              labels = saLabels;
            };
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "Role";
              name = "forgejo-bootstrap";
            };
            subjects = [
              {
                kind = "ServiceAccount";
                name = "forgejo-bootstrap";
                namespace = forgejoCfg.namespace;
              }
            ];
          };
        }
      ]) argocdNamespaces
    );

  orgsJson = builtins.toJSON cfg.orgs;

  reposJson = builtins.toJSON (
    lib.mapAttrsToList (_: r: {
      inherit (r)
        org
        repo
        description
        private
        ;
    }) cfg.repos
  );

  deployKeysJson = builtins.toJSON (
    lib.mapAttrsToList (_: k: {
      inherit (k) org repo readOnly;
      secretNs = k.targetSecret.namespace;
      secretName = k.targetSecret.name;

      sshHostForUrl = "forgejo-ssh.${forgejoCfg.namespace}.svc.cluster.local";

      sshPortForUrl = "2222";
    }) cfg.deployKeys
  );

  podSpec = {
    serviceAccountName = "forgejo-bootstrap";
    restartPolicy = "OnFailure";

    initContainers = [
      (waitLib.mkWaitInitContainer {
        name = "wait-for-forgejo";
        probe = {
          kind = "condition";
          resource = "deployment/${cfg.forgejoDeploymentName}";
          namespace = forgejoCfg.namespace;
          condition = "Available";
          timeout = "10m";
        };
      })
    ];
    containers = [
      {
        name = "bootstrap";
        image = forgejoCfg.images.bootstrap.ref;
        env = [
          {
            name = "FORGEJO_NS";
            value = forgejoCfg.namespace;
          }
          {
            name = "FORGEJO_URL";
            value = forgejoInternalUrl;
          }
          {
            name = "FORGEJO_DEPLOY";
            value = cfg.forgejoDeploymentName;
          }
          {
            name = "ADMIN_USERNAME";
            value = cfg.adminUsername;
          }
          {
            name = "BOT_USERNAME";
            value = cfg.botUsername;
          }
          {
            name = "BOT_TOKEN_SECRET";
            value = cfg.botTokenSecretName;
          }
          {
            name = "BOT_TOKEN_KEY";
            value = "token";
          }
          {
            name = "ORGS_JSON";
            value = orgsJson;
          }
          {
            name = "ORG_VISIBILITY";
            value = cfg.orgVisibility;
          }
          {
            name = "REPOS_JSON";
            value = reposJson;
          }
          {
            name = "DEPLOY_KEYS_JSON";
            value = deployKeysJson;
          }
        ];
        command = [
          "/bin/bash"
          "-c"
          script
        ];
      }
    ];
  };

  bootstrapJob = catalLib.mkIdempotentJob {
    name = "forgejo-bootstrap";
    namespace = forgejoCfg.namespace;
    contentInputs = {
      inherit script;
      inherit (cfg)
        adminUsername
        botUsername
        botTokenSecretName
        forgejoDeploymentName
        ;
      image = forgejoCfg.images.bootstrap.ref;
      inherit orgsJson reposJson deployKeysJson;
    };
    inherit podSpec;
    argoCDSyncWave = "20";
  };

  jobResources = bootstrapJob.resources;
in
{
  options.floes.forgejo.bootstrap = {
    enable = mkEnableOption "forgejo org/repo/deploy-key bootstrap Job";

    forgejoDeploymentName = mkOption {
      type = types.str;
      default = "forgejo";
      description = "Deployment name to `kubectl exec` the admin CLI against.";
    };

    adminUsername = mkOption {
      type = types.str;
      default = "gitea_admin";
      description = "Built-in forgejo admin user (created by the chart).";
    };

    botUsername = mkOption {
      type = types.str;
      default = "platform-bot";
      description = ''
        Machine user the bootstrap Job creates on first run and mints
        its PAT under. Kept separate from `adminUsername` so a human
        operator can revoke either credential independently.
      '';
    };

    botTokenSecretName = mkOption {
      type = types.str;
      default = "platform-bot-token";
      description = ''
        K8s Secret (in the forgejo namespace) that stores the bot PAT
        under key `token`. Consumed by re-runs of this Job and by
        `cata lab publish` if it needs HTTPS auth for API calls.
      '';
    };

    orgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Orgs to ensure exist. Idempotent, created only if missing.
        `orgVisibility` decides what they are created as.
      '';
    };

    orgVisibility = mkOption {
      type = types.enum [
        "private"
        "public"
        "limited"
      ];
      default = "private";
      description = ''
        Visibility every org in `orgs` is created with.

        A repository inside a private org is not readable without a token
        however the repository itself is marked, so a lab whose second
        cluster reads the manifests repo anonymously needs the org public
        as well as the repo.

        Applies at creation only, like everything else here: an org that
        already exists is left as it is.
      '';
    };

    repos = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              org = mkOption {
                type = types.str;
                description = "Org (`orgs` entry) that owns the repo.";
              };
              repo = mkOption {
                type = types.str;
                default = name;
                description = "Repo name. Defaults to the attribute name.";
              };
              description = mkOption {
                type = types.str;
                default = "";
                description = "Description set on the repository.";
              };
              private = mkOption {
                type = types.bool;
                default = true;
                description = "Create the repository private. Public repositories are readable without a token.";
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Repos to ensure exist under the declared orgs. `auto_init=true`
        is forced so a fresh repo has an initial commit: `git clone`
        on an empty repo fails, and `cata lab publish` relies on
        clone-into-tempdir.
      '';
    };

    deployKeys = mkOption {
      type = types.attrsOf (
        types.submodule (_: {
          options = {
            org = mkOption {
              type = types.str;
              description = "Organisation that owns the repository.";
            };
            repo = mkOption {
              type = types.str;
              description = "Repository name.";
            };
            readOnly = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether the deploy key is read-only. Argocd's manifests
                repo needs read-only (pull). Set false only for keys
                that need to push (which shouldn't come from this Job).
              '';
            };
            targetSecret = mkOption {
              type = types.submodule {
                options = {
                  namespace = mkOption {
                    type = types.str;
                    description = "Namespace the deploy-key Secret is written to.";
                  };
                  name = mkOption {
                    type = types.str;
                    description = "Name of that Secret.";
                  };
                };
              };
              description = ''
                Where to write the privkey. Argocd auto-discovers
                Secrets labeled `argocd.argoproj.io/secret-type=repository`;
                the Job writes that label + `type=git`, `url`, and
                `sshPrivateKey` in `stringData`.
              '';
            };
          };
        })
      );
      default = { };
      description = ''
        SSH deploy keys to mint. Each entry mints an ed25519 keypair,
        uploads the pubkey to the repo's `keys` collection, and writes
        an argocd-namespace Secret shaped for argocd's repo credential
        discovery.
      '';
    };
  };

  config = mkIf (forgejoCfg.enable && cfg.enable) {
    floes.forgejo.steps.bootstrap-forgejo = {
      kind = "bootstrap-forgejo-repos";
      after = [ (planTokens.needs (planTokens.cluster config.cluster.name).argocdInstalled) ];
      provides = [
        (planTokens.cluster config.cluster.name).forgejoBootstrapped
        (planTokens.cluster config.cluster.name).gitReady
        planTokens.lab.gitReady
      ];
      params = {
        target = config.cluster.name;
        namespace = forgejoCfg.namespace;
        jobLabelSelector = bootstrapJob.selector;
      };
      description = "Wait for forgejo-bootstrap Job on '${config.cluster.name}'";
    };

    floes.forgejo.images.bootstrap = {
      repository = "alpine/k8s";
      tag = "1.32.4";
    };

    floes.forgejo.verify.bootstrap-completed = {
      description = "The forgejo bootstrap Job created the orgs, repos and deploy keys";
      expect = {
        apiVersion = "batch/v1";
        kind = "Job";
        metadata.namespace = forgejoCfg.namespace;
        metadata.labels."app.kubernetes.io/component" = "forgejo-bootstrap";
        status.succeeded = 1;
      };
    };

    floes.forgejo.bundles.forgejo-bootstrap = {
      resources = rbac // jobResources;

      owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };

      requires = [ "forgejo/git/ready" ];
    };
  };
}
