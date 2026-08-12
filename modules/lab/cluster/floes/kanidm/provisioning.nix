{
  lib,
  cfg,
}:

let
  inherit (lib)
    mapAttrs
    mapAttrsToList
    optionalAttrs
    ;
in
rec {

  groupResources = mapAttrs (name: group: {
    apiVersion = "kaniop.rs/v1beta1";
    kind = "KanidmGroup";
    metadata = {
      inherit name;
      namespace = cfg.namespace;
      labels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
      };
    };
    spec = {
      kanidmRef.name = cfg.instanceName;
      members = group.members;
    }
    // optionalAttrs (group.mail != [ ]) {
      mail = group.mail;
    }
    // optionalAttrs (group.entryManagedBy != null) {
      entryManagedBy = group.entryManagedBy;
    }
    // optionalAttrs (group.posixAttributes != null) {
      posixAttributes =
        { }
        // optionalAttrs (group.posixAttributes.gidnumber != null) {
          gidnumber = group.posixAttributes.gidnumber;
        };
    }
    // optionalAttrs (group.accountPolicy != null) {
      accountPolicy = {
        credentialTypeMinimum = group.accountPolicy.credentialTypeMinimum;
        passwordMinimumLength = group.accountPolicy.passwordMinimumLength;
        authSessionExpiry = group.accountPolicy.authSessionExpiry;
        privilegeExpiry = group.accountPolicy.privilegeExpiry;
      };
    };
  }) cfg.groups;

  personResources = mapAttrs (name: user: {
    apiVersion = "kaniop.rs/v1beta1";
    kind = "KanidmPersonAccount";
    metadata = {
      inherit name;
      namespace = cfg.namespace;
      labels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
      };
    };
    spec = {
      kanidmRef.name = cfg.instanceName;
      personAttributes = {
        displayname = user.displayName;
        mail = [ user.email ];
      }
      // optionalAttrs (user.legalName != null) {
        legalname = user.legalName;
      }
      // optionalAttrs (user.accountValidFrom != null) {
        accountValidFrom = user.accountValidFrom;
      }
      // optionalAttrs (user.accountExpire != null) {
        accountExpire = user.accountExpire;
      };
      credentialsTokenTtl = user.credentialsTokenTtl;
    }
    // optionalAttrs (user.posixAttributes != null) {
      posixAttributes =
        { }
        // optionalAttrs (user.posixAttributes.gidnumber != null) {
          gidnumber = user.posixAttributes.gidnumber;
        }
        // optionalAttrs (user.posixAttributes.loginshell != "/bin/bash") {
          loginshell = user.posixAttributes.loginshell;
        };
    };
  }) cfg.users;

  oauth2Namespaces = lib.unique (mapAttrsToList (_: r: r.metadata.namespace) oauth2Resources);

  hasCrossNamespaceClient = oauth2Namespaces != [ ] && oauth2Namespaces != [ cfg.namespace ];

  effectiveOauth2NamespaceSelector =
    if cfg.oauth2ClientNamespaceSelector != null then
      cfg.oauth2ClientNamespaceSelector
    else if hasCrossNamespaceClient then
      { }
    else
      null;

  oauth2Resources = mapAttrs (name: client: {
    apiVersion = "kaniop.rs/v1beta1";
    kind = "KanidmOAuth2Client";
    metadata = {
      inherit name;
      namespace = if client.namespace != null then client.namespace else cfg.namespace;
      labels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
      };
    };
    spec = {
      kanidmRef = {
        name = cfg.instanceName;
      }
      // optionalAttrs (client.namespace != null) {
        namespace = cfg.namespace;
      };
      displayname = if client.displayName != "" then client.displayName else name;
      origin = client.origin;
      redirectUrl =
        if client.redirectUrls != [ ] then client.redirectUrls else [ "${client.origin}/oauth2/callback" ];
    }
    // optionalAttrs client.public { public = true; }
    // optionalAttrs (client.secretTemplate != null) {
      secretTemplate.labels = client.secretTemplate;
    }
    // optionalAttrs (client.scopeMap != [ ]) {
      scopeMap = map (sm: {
        group = sm.group;
        scopes = sm.scopes;
      }) client.scopeMap;
    }
    // optionalAttrs (client.supScopeMap != [ ]) {
      supScopeMap = map (sm: {
        group = sm.group;
        scopes = sm.scopes;
      }) client.supScopeMap;
    }
    // optionalAttrs (client.claimMap != [ ]) {
      claimMap = map (cm: {
        name = cm.name;
        joinStrategy = cm.joinStrategy;
        valuesMap = map (vm: {
          group = vm.group;
          values = vm.values;
        }) cm.valuesMap;
      }) client.claimMap;
    }
    // optionalAttrs client.preferShortUsername { preferShortUsername = true; }
    // optionalAttrs client.allowLocalhostRedirect { allowLocalhostRedirect = true; }
    // optionalAttrs client.disableConsentPrompt { disableConsentPrompt = true; }
    // optionalAttrs client.allowInsecureClientDisablePkce { allowInsecureClientDisablePkce = true; }
    // optionalAttrs (!client.strictRedirectUrl) { strictRedirectUrl = false; };
  }) cfg.oauth2Clients;

  serviceAccountResources = mapAttrs (name: sa: {
    apiVersion = "kaniop.rs/v1beta1";
    kind = "KanidmServiceAccount";
    metadata = {
      inherit name;
      namespace = cfg.namespace;
      labels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
      };
    };
    spec = {
      kanidmRef.name = cfg.instanceName;
      serviceAccountAttributes = {
        displayname = sa.displayName;
        entryManagedBy = sa.entryManagedBy;
      }
      // optionalAttrs (sa.mail != [ ]) {
        mail = sa.mail;
      }
      // optionalAttrs (sa.accountValidFrom != null) {
        accountValidFrom = sa.accountValidFrom;
      }
      // optionalAttrs (sa.accountExpire != null) {
        accountExpire = sa.accountExpire;
      };
    }
    // optionalAttrs (sa.apiTokens != [ ]) {
      apiTokens = map (
        tok:
        {
          label = tok.label;
          purpose = tok.purpose;
          secretName = tok.secretName;
        }
        // optionalAttrs (tok.expiry != null) {
          expiry = tok.expiry;
        }
      ) sa.apiTokens;
    }
    // optionalAttrs sa.generateCredentials {
      generateCredentials = true;
    };
  }) cfg.serviceAccounts;

  hasProvisioning =
    cfg.users != { } || cfg.groups != { } || cfg.oauth2Clients != { } || cfg.serviceAccounts != { };
}
