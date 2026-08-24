{ lib, k8sTypes }:

let
  inherit (lib) mkOption types;
  inherit (k8sTypes) mkTypedSubmodule mkResource;
in
{
  Bundle = mkResource {
    apiVersion = "trust.cert-manager.io/v1alpha1";
    kind = "Bundle";
    specType = (
      mkTypedSubmodule {
        options = {
          sources = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  configMap = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          includeAllKeys = mkOption {
                            type = (types.nullOr types.bool);
                            default = null;
                            description = ''
                              includeAllKeys is a flag to include all keys in the object's `data` field to be used. False by default.
                              This field must not be true when `key` is set.
                            '';
                          };
                          key = mkOption {
                            type = (types.nullOr types.str);
                            default = null;
                            description = "key of the entry in the object's `data` field to be used.";
                          };
                          name = mkOption {
                            type = (types.nullOr types.str);
                            default = null;
                            description = ''
                              name is the name of the source object in the trust namespace.
                              This field must be left empty when `selector` is set
                            '';
                          };
                          selector = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  matchExpressions = mkOption {
                                    type = (
                                      types.nullOr (
                                        types.listOf (mkTypedSubmodule {
                                          options = {
                                            key = mkOption {
                                              type = types.str;
                                              description = "key is the label key that the selector applies to.";
                                            };
                                            operator = mkOption {
                                              type = types.str;
                                              description = ''
                                                operator represents a key's relationship to a set of values.
                                                Valid operators are In, NotIn, Exists and DoesNotExist.
                                              '';
                                            };
                                            values = mkOption {
                                              type = (types.nullOr (types.listOf types.str));
                                              default = null;
                                              description = ''
                                                values is an array of string values. If the operator is In or NotIn,
                                                the values array must be non-empty. If the operator is Exists or DoesNotExist,
                                                the values array must be empty. This array is replaced during a strategic
                                                merge patch.
                                              '';
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      )
                                    );
                                    default = null;
                                    description = "matchExpressions is a list of label selector requirements. The requirements are ANDed.";
                                  };
                                  matchLabels = mkOption {
                                    type = (types.nullOr (types.attrsOf types.str));
                                    default = null;
                                    description = ''
                                      matchLabels is a map of {key,value} pairs. A single {key,value} in the matchLabels
                                      map is equivalent to an element of matchExpressions, whose key field is "key", the
                                      operator is "In", and the values array contains only "value". The requirements are ANDed.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              selector is the label selector to use to fetch a list of objects. Must not be set
                              when `name` is set.
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      configMap is a reference (by name) to a ConfigMap's `data` key(s), or to a
                      list of ConfigMap's `data` key(s) using label selector, in the trust namespace.
                    '';
                  };
                  inLine = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = "inLine is a simple string to append as the source data.";
                  };
                  secret = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          includeAllKeys = mkOption {
                            type = (types.nullOr types.bool);
                            default = null;
                            description = ''
                              includeAllKeys is a flag to include all keys in the object's `data` field to be used. False by default.
                              This field must not be true when `key` is set.
                            '';
                          };
                          key = mkOption {
                            type = (types.nullOr types.str);
                            default = null;
                            description = "key of the entry in the object's `data` field to be used.";
                          };
                          name = mkOption {
                            type = (types.nullOr types.str);
                            default = null;
                            description = ''
                              name is the name of the source object in the trust namespace.
                              This field must be left empty when `selector` is set
                            '';
                          };
                          selector = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  matchExpressions = mkOption {
                                    type = (
                                      types.nullOr (
                                        types.listOf (mkTypedSubmodule {
                                          options = {
                                            key = mkOption {
                                              type = types.str;
                                              description = "key is the label key that the selector applies to.";
                                            };
                                            operator = mkOption {
                                              type = types.str;
                                              description = ''
                                                operator represents a key's relationship to a set of values.
                                                Valid operators are In, NotIn, Exists and DoesNotExist.
                                              '';
                                            };
                                            values = mkOption {
                                              type = (types.nullOr (types.listOf types.str));
                                              default = null;
                                              description = ''
                                                values is an array of string values. If the operator is In or NotIn,
                                                the values array must be non-empty. If the operator is Exists or DoesNotExist,
                                                the values array must be empty. This array is replaced during a strategic
                                                merge patch.
                                              '';
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      )
                                    );
                                    default = null;
                                    description = "matchExpressions is a list of label selector requirements. The requirements are ANDed.";
                                  };
                                  matchLabels = mkOption {
                                    type = (types.nullOr (types.attrsOf types.str));
                                    default = null;
                                    description = ''
                                      matchLabels is a map of {key,value} pairs. A single {key,value} in the matchLabels
                                      map is equivalent to an element of matchExpressions, whose key field is "key", the
                                      operator is "In", and the values array contains only "value". The requirements are ANDed.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              selector is the label selector to use to fetch a list of objects. Must not be set
                              when `name` is set.
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      secret is a reference (by name) to a Secret's `data` key(s), or to a
                      list of Secret's `data` key(s) using label selector, in the trust namespace.
                    '';
                  };
                  useDefaultCAs = mkOption {
                    type = (types.nullOr types.bool);
                    default = null;
                    description = ''
                      useDefaultCAs indicates whether the default CA bundle should be used as a source.
                      The default CA bundle is available only if trust-manager was installed with
                      default CA support enabled, either via the Helm chart or by starting the
                      trust-manager controller with the "--default-package-location" flag.
                      If default CA support was not enabled at startup, setting this field to true
                      will result in reconciliation failure.
                      The version of the default CA package used for this Bundle is reported in
                      status.defaultCAVersion.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = "sources is a set of references to data whose data will sync to the target.";
          };
          target = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  additionalFormats = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          jks = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  key = mkOption {
                                    type = types.str;
                                    description = "key is the key of the entry in the object's `data` field to be used.";
                                  };
                                  password = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "password for JKS trust store";
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              jks requests a JKS-formatted binary trust bundle to be written to the target.
                              The bundle has "changeit" as the default password.
                              For more information refer to this link https://cert-manager.io/docs/faq/#keystore-passwords
                              Format is deprecated: Writing JKS is subject for removal. Please migrate to PKCS12.
                              PKCS#12 trust stores created by trust-manager are compatible with Java.
                            '';
                          };
                          pkcs12 = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  key = mkOption {
                                    type = types.str;
                                    description = "key is the key of the entry in the object's `data` field to be used.";
                                  };
                                  password = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "password for PKCS12 trust store";
                                  };
                                  profile = mkOption {
                                    type = (
                                      types.nullOr (
                                        types.enum [
                                          "LegacyRC2"
                                          "LegacyDES"
                                          "Modern2023"
                                        ]
                                      )
                                    );
                                    default = null;
                                    description = ''
                                      profile specifies the certificate encryption algorithms and the HMAC algorithm
                                      used to create the PKCS12 trust store.

                                      If provided, allowed values are:
                                      `LegacyRC2`: Deprecated. Not supported by default in OpenSSL 3 or Java 20.
                                      `LegacyDES`: Less secure algorithm. Use this option for maximal compatibility.
                                      `Modern2023`: Secure algorithm. Use this option in case you have to always use secure algorithms (e.g. because of company policy).

                                      Default value is `LegacyRC2` for backward compatibility.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              pkcs12 requests a PKCS12-formatted binary trust bundle to be written to the target.

                              The bundle is by default created without a password.
                              For more information refer to this link https://cert-manager.io/docs/faq/#keystore-passwords
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = "additionalFormats specifies any additional formats to write to the target";
                  };
                  configMap = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          key = mkOption {
                            type = types.str;
                            description = "key is the key of the entry in the object's `data` field to be used.";
                          };
                          metadata = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  annotations = mkOption {
                                    type = (types.nullOr (types.attrsOf types.str));
                                    default = null;
                                    description = "annotations is a key value map to be copied to the target.";
                                  };
                                  labels = mkOption {
                                    type = (types.nullOr (types.attrsOf types.str));
                                    default = null;
                                    description = "labels is a key value map to be copied to the target.";
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "metadata is an optional set of labels and annotations to be copied to the target.";
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      configMap is the target ConfigMap in Namespaces that all Bundle source
                      data will be synced to.
                    '';
                  };
                  namespaceSelector = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          matchExpressions = mkOption {
                            type = (
                              types.nullOr (
                                types.listOf (mkTypedSubmodule {
                                  options = {
                                    key = mkOption {
                                      type = types.str;
                                      description = "key is the label key that the selector applies to.";
                                    };
                                    operator = mkOption {
                                      type = types.str;
                                      description = ''
                                        operator represents a key's relationship to a set of values.
                                        Valid operators are In, NotIn, Exists and DoesNotExist.
                                      '';
                                    };
                                    values = mkOption {
                                      type = (types.nullOr (types.listOf types.str));
                                      default = null;
                                      description = ''
                                        values is an array of string values. If the operator is In or NotIn,
                                        the values array must be non-empty. If the operator is Exists or DoesNotExist,
                                        the values array must be empty. This array is replaced during a strategic
                                        merge patch.
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              )
                            );
                            default = null;
                            description = "matchExpressions is a list of label selector requirements. The requirements are ANDed.";
                          };
                          matchLabels = mkOption {
                            type = (types.nullOr (types.attrsOf types.str));
                            default = null;
                            description = ''
                              matchLabels is a map of {key,value} pairs. A single {key,value} in the matchLabels
                              map is equivalent to an element of matchExpressions, whose key field is "key", the
                              operator is "In", and the values array contains only "value". The requirements are ANDed.
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      namespaceSelector will, if set, only sync the target resource in
                      Namespaces which match the selector.
                    '';
                  };
                  secret = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          key = mkOption {
                            type = types.str;
                            description = "key is the key of the entry in the object's `data` field to be used.";
                          };
                          metadata = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  annotations = mkOption {
                                    type = (types.nullOr (types.attrsOf types.str));
                                    default = null;
                                    description = "annotations is a key value map to be copied to the target.";
                                  };
                                  labels = mkOption {
                                    type = (types.nullOr (types.attrsOf types.str));
                                    default = null;
                                    description = "labels is a key value map to be copied to the target.";
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "metadata is an optional set of labels and annotations to be copied to the target.";
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      secret is the target Secret that all Bundle source data will be synced to.
                      Using Secrets as targets is only supported if enabled at trust-manager startup.
                      By default, trust-manager has no permissions for writing to secrets and can only read secrets in the trust namespace.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = "target is the target location in all namespaces to sync source data to.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

}
