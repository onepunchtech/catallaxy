{ lib, k8sTypes }:

let
  inherit (lib) mkOption types;
  inherit (k8sTypes) mkTypedSubmodule mkResource;
in
{
  ClusterProxy = mkResource {
    apiVersion = "netbird.io/v1alpha1";
    kind = "ClusterProxy";
    specType = (
      mkTypedSubmodule {
        options = {
          apiServer = mkOption {
            type = types.str;
            description = "APIServer is the URL of the Kubernetes API server to proxy requests to.";
          };
          clusterName = mkOption {
            type = types.str;
            description = "ClusterName is the name of the Kubernetes cluster.";
          };
          groups = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    id = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "ID is the id of the group.";
                    };
                    localRef = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            name = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Name of the referent.
                                This field is effectively required, but due to backwards compatibility is
                                allowed to be empty. Instances of this type with an empty value here are
                                almost certainly wrong.
                                More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "LocalReference is a reference to a group in the same namespace.";
                    };
                    name = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "Name is the name of the group.";
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = "Groups are references to groups that the peer will be a part of.";
          };
          serviceAccountName = mkOption {
            type = types.str;
            description = "ServiceAccountName is a reference to the service account used for impersonation.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  Group = mkResource {
    apiVersion = "netbird.io/v1alpha1";
    kind = "Group";
    specType = (
      mkTypedSubmodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Name of the group.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  NBGroup = mkResource {
    apiVersion = "netbird.io/v1";
    kind = "NBGroup";
    specType = (
      mkTypedSubmodule {
        options = {
          name = mkOption {
            type = types.str;
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  NBPolicy = mkResource {
    apiVersion = "netbird.io/v1";
    kind = "NBPolicy";
    specType = (
      mkTypedSubmodule {
        options = {
          bidirectional = mkOption {
            type = (types.nullOr types.bool);
            default = null;
          };
          description = mkOption {
            type = (types.nullOr types.str);
            default = null;
          };
          destinationGroups = mkOption {
            type = (types.nullOr (types.listOf types.str));
            default = null;
          };
          name = mkOption {
            type = types.str;
            description = "Name Policy name";
          };
          ports = mkOption {
            type = (types.nullOr (types.listOf types.int));
            default = null;
          };
          protocols = mkOption {
            type = (
              types.nullOr (
                types.listOf (
                  types.enum [
                    "tcp"
                    "udp"
                  ]
                )
              )
            );
            default = null;
          };
          sourceGroups = mkOption {
            type = (types.nullOr (types.listOf types.str));
            default = null;
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  NBResource = mkResource {
    apiVersion = "netbird.io/v1";
    kind = "NBResource";
    specType = (
      mkTypedSubmodule {
        options = {
          address = mkOption {
            type = types.str;
          };
          groups = mkOption {
            type = (types.listOf types.str);
          };
          name = mkOption {
            type = types.str;
          };
          networkID = mkOption {
            type = types.str;
          };
          policyFriendlyName = mkOption {
            type = (types.nullOr (types.attrsOf types.str));
            default = null;
          };
          policyName = mkOption {
            type = (types.nullOr types.str);
            default = null;
          };
          policySourceGroups = mkOption {
            type = (types.nullOr (types.listOf types.str));
            default = null;
          };
          tcpPorts = mkOption {
            type = (types.nullOr (types.listOf types.int));
            default = null;
          };
          udpPorts = mkOption {
            type = (types.nullOr (types.listOf types.int));
            default = null;
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  NBRoutingPeer = mkResource {
    apiVersion = "netbird.io/v1";
    kind = "NBRoutingPeer";
    specType = (
      mkTypedSubmodule {
        options = {
          annotations = mkOption {
            type = (types.nullOr (types.attrsOf types.str));
            default = null;
          };
          labels = mkOption {
            type = (types.nullOr (types.attrsOf types.str));
            default = null;
          };
          nodeSelector = mkOption {
            type = (types.nullOr (types.attrsOf types.str));
            default = null;
          };
          privileged = mkOption {
            type = (types.nullOr types.bool);
            default = null;
          };
          replicas = mkOption {
            type = (types.nullOr types.int);
            default = null;
          };
          resources = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  claims = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (mkTypedSubmodule {
                          options = {
                            name = mkOption {
                              type = types.str;
                              description = ''
                                Name must match the name of one entry in pod.spec.resourceClaims of
                                the Pod where this field is used. It makes that resource available
                                inside a container.
                              '';
                            };
                            request = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Request is the name chosen for a request in the referenced claim.
                                If empty, everything from the claim is made available, otherwise
                                only the result of this request.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = ''
                      Claims lists the names of resources, defined in spec.resourceClaims,
                      that are used by this container.

                      This field depends on the
                      DynamicResourceAllocation feature gate.

                      This field is immutable. It can only be set for containers.
                    '';
                  };
                  limits = mkOption {
                    type = (types.nullOr (types.attrsOf types.anything));
                    default = null;
                    description = ''
                      Limits describes the maximum amount of compute resources allowed.
                      More info: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
                    '';
                  };
                  requests = mkOption {
                    type = (types.nullOr (types.attrsOf types.anything));
                    default = null;
                    description = ''
                      Requests describes the minimum amount of compute resources required.
                      If Requests is omitted for a container, it defaults to Limits if that is explicitly specified,
                      otherwise to an implementation-defined value. Requests cannot exceed Limits.
                      More info: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = "ResourceRequirements describes the compute resource requirements.";
          };
          tolerations = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    effect = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Effect indicates the taint effect to match. Empty means match all taint effects.
                        When specified, allowed values are NoSchedule, PreferNoSchedule and NoExecute.
                      '';
                    };
                    key = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Key is the taint key that the toleration applies to. Empty means match all taint keys.
                        If the key is empty, operator must be Exists; this combination means to match all values and all keys.
                      '';
                    };
                    operator = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Operator represents a key's relationship to the value.
                        Valid operators are Exists, Equal, Lt, and Gt. Defaults to Equal.
                        Exists is equivalent to wildcard for value, so that a pod can
                        tolerate all taints of a particular category.
                        Lt and Gt perform numeric comparisons (requires feature gate TaintTolerationComparisonOperators).
                      '';
                    };
                    tolerationSeconds = mkOption {
                      type = (types.nullOr types.int);
                      default = null;
                      description = ''
                        TolerationSeconds represents the period of time the toleration (which must be
                        of effect NoExecute, otherwise this field is ignored) tolerates the taint. By default,
                        it is not set, which means tolerate the taint forever (do not evict). Zero and
                        negative values will be treated as 0 (evict immediately) by the system.
                      '';
                    };
                    value = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Value is the taint value the toleration matches to.
                        If the operator is Exists, the value should be empty, otherwise just a regular string.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
          };
          volumeMounts = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    mountPath = mkOption {
                      type = types.str;
                      description = ''
                        Path within the container at which the volume should be mounted.  Must
                        not contain ':'.
                      '';
                    };
                    mountPropagation = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        mountPropagation determines how mounts are propagated from the host
                        to container and the other way around.
                        When not set, MountPropagationNone is used.
                        This field is beta in 1.10.
                        When RecursiveReadOnly is set to IfPossible or to Enabled, MountPropagation must be None or unspecified
                        (which defaults to None).
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = "This must match the Name of a Volume.";
                    };
                    readOnly = mkOption {
                      type = (types.nullOr types.bool);
                      default = null;
                      description = ''
                        Mounted read-only if true, read-write otherwise (false or unspecified).
                        Defaults to false.
                      '';
                    };
                    recursiveReadOnly = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        RecursiveReadOnly specifies whether read-only mounts should be handled
                        recursively.

                        If ReadOnly is false, this field has no meaning and must be unspecified.

                        If ReadOnly is true, and this field is set to Disabled, the mount is not made
                        recursively read-only.  If this field is set to IfPossible, the mount is made
                        recursively read-only, if it is supported by the container runtime.  If this
                        field is set to Enabled, the mount is made recursively read-only if it is
                        supported by the container runtime, otherwise the pod will not be started and
                        an error will be generated to indicate the reason.

                        If this field is set to IfPossible or Enabled, MountPropagation must be set to
                        None (or be unspecified, which defaults to None).

                        If this field is not specified, it is treated as an equivalent of Disabled.
                      '';
                    };
                    subPath = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Path within the volume from which the container's volume should be mounted.
                        Defaults to "" (volume's root).
                      '';
                    };
                    subPathExpr = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Expanded path within the volume from which the container's volume should be mounted.
                        Behaves similarly to SubPath but environment variable references $(VAR_NAME) are expanded using the container's environment.
                        Defaults to "" (volume's root).
                        SubPathExpr and SubPath are mutually exclusive.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
          };
          volumes = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    awsElasticBlockStore = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type of the volume that you want to mount.
                                Tip: Ensure that the filesystem type is supported by the host operating system.
                                Examples: "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#awselasticblockstore
                              '';
                            };
                            partition = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                partition is the partition in the volume that you want to mount.
                                If omitted, the default is to mount by volume name.
                                Examples: For volume /dev/sda1, you specify the partition as "1".
                                Similarly, the volume partition for /dev/sda is "0" (or you can leave the property empty).
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly value true will force the readOnly setting in VolumeMounts.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#awselasticblockstore
                              '';
                            };
                            volumeID = mkOption {
                              type = types.str;
                              description = ''
                                volumeID is unique ID of the persistent disk resource in AWS (Amazon EBS volume).
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#awselasticblockstore
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        awsElasticBlockStore represents an AWS Disk resource that is attached to a
                        kubelet's host machine and then exposed to the pod.
                        Deprecated: AWSElasticBlockStore is deprecated. All operations for the in-tree
                        awsElasticBlockStore type are redirected to the ebs.csi.aws.com CSI driver.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#awselasticblockstore
                      '';
                    };
                    azureDisk = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            cachingMode = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "cachingMode is the Host Caching mode: None, Read Only, Read Write.";
                            };
                            diskName = mkOption {
                              type = types.str;
                              description = "diskName is the Name of the data disk in the blob storage";
                            };
                            diskURI = mkOption {
                              type = types.str;
                              description = "diskURI is the URI of data disk in the blob storage";
                            };
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is Filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            kind = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "kind expected values are Shared: multiple blob disks per storage account  Dedicated: single blob disk per storage account  Managed: azure managed data disk (only in managed availability set). defaults to shared";
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly Defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        azureDisk represents an Azure Data Disk mount on the host and bind mount to the pod.
                        Deprecated: AzureDisk is deprecated. All operations for the in-tree azureDisk type
                        are redirected to the disk.csi.azure.com CSI driver.
                      '';
                    };
                    azureFile = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            secretName = mkOption {
                              type = types.str;
                              description = "secretName is the  name of secret that contains Azure Storage Account Name and Key";
                            };
                            shareName = mkOption {
                              type = types.str;
                              description = "shareName is the azure share Name";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        azureFile represents an Azure File Service mount on the host and bind mount to the pod.
                        Deprecated: AzureFile is deprecated. All operations for the in-tree azureFile type
                        are redirected to the file.csi.azure.com CSI driver.
                      '';
                    };
                    cephfs = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            monitors = mkOption {
                              type = (types.listOf types.str);
                              description = ''
                                monitors is Required: Monitors is a collection of Ceph monitors
                                More info: https://examples.k8s.io/volumes/cephfs/README.md#how-to-use-it
                              '';
                            };
                            path = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "path is Optional: Used as the mounted root, rather than the full Ceph tree, default is /";
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly is Optional: Defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                                More info: https://examples.k8s.io/volumes/cephfs/README.md#how-to-use-it
                              '';
                            };
                            secretFile = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                secretFile is Optional: SecretFile is the path to key ring for User, default is /etc/ceph/user.secret
                                More info: https://examples.k8s.io/volumes/cephfs/README.md#how-to-use-it
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                secretRef is Optional: SecretRef is reference to the authentication secret for User, default is empty.
                                More info: https://examples.k8s.io/volumes/cephfs/README.md#how-to-use-it
                              '';
                            };
                            user = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                user is optional: User is the rados user name, default is admin
                                More info: https://examples.k8s.io/volumes/cephfs/README.md#how-to-use-it
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        cephFS represents a Ceph FS mount on the host that shares a pod's lifetime.
                        Deprecated: CephFS is deprecated and the in-tree cephfs type is no longer supported.
                      '';
                    };
                    cinder = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Examples: "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                                More info: https://examples.k8s.io/mysql-cinder-pd/README.md
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                                More info: https://examples.k8s.io/mysql-cinder-pd/README.md
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                secretRef is optional: points to a secret object containing parameters used to connect
                                to OpenStack.
                              '';
                            };
                            volumeID = mkOption {
                              type = types.str;
                              description = ''
                                volumeID used to identify the volume in cinder.
                                More info: https://examples.k8s.io/mysql-cinder-pd/README.md
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        cinder represents a cinder volume attached and mounted on kubelets host machine.
                        Deprecated: Cinder is deprecated. All operations for the in-tree cinder type
                        are redirected to the cinder.csi.openstack.org CSI driver.
                        More info: https://examples.k8s.io/mysql-cinder-pd/README.md
                      '';
                    };
                    configMap = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            defaultMode = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                defaultMode is optional: mode bits used to set permissions on created files by default.
                                Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                Defaults to 0644.
                                Directories within the path are not affected by this setting.
                                This might be in conflict with other options that affect the file
                                mode, like fsGroup, and the result can be other mode bits set.
                              '';
                            };
                            items = mkOption {
                              type = (
                                types.nullOr (
                                  types.listOf (mkTypedSubmodule {
                                    options = {
                                      key = mkOption {
                                        type = types.str;
                                        description = "key is the key to project.";
                                      };
                                      mode = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          mode is Optional: mode bits used to set permissions on this file.
                                          Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                          YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                          If not specified, the volume defaultMode will be used.
                                          This might be in conflict with other options that affect the file
                                          mode, like fsGroup, and the result can be other mode bits set.
                                        '';
                                      };
                                      path = mkOption {
                                        type = types.str;
                                        description = ''
                                          path is the relative path of the file to map the key to.
                                          May not be an absolute path.
                                          May not contain the path element '..'.
                                          May not start with the string '..'.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                )
                              );
                              default = null;
                              description = ''
                                items if unspecified, each key-value pair in the Data field of the referenced
                                ConfigMap will be projected into the volume as a file whose name is the
                                key and content is the value. If specified, the listed keys will be
                                projected into the specified paths, and unlisted keys will not be
                                present. If a key is specified which is not present in the ConfigMap,
                                the volume setup will error unless it is marked optional. Paths must be
                                relative and may not contain the '..' path or start with '..'.
                              '';
                            };
                            name = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Name of the referent.
                                This field is effectively required, but due to backwards compatibility is
                                allowed to be empty. Instances of this type with an empty value here are
                                almost certainly wrong.
                                More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                              '';
                            };
                            optional = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = "optional specify whether the ConfigMap or its keys must be defined";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "configMap represents a configMap that should populate this volume";
                    };
                    csi = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            driver = mkOption {
                              type = types.str;
                              description = ''
                                driver is the name of the CSI driver that handles this volume.
                                Consult with your admin for the correct name as registered in the cluster.
                              '';
                            };
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType to mount. Ex. "ext4", "xfs", "ntfs".
                                If not provided, the empty value is passed to the associated CSI driver
                                which will determine the default filesystem to apply.
                              '';
                            };
                            nodePublishSecretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                nodePublishSecretRef is a reference to the secret object containing
                                sensitive information to pass to the CSI driver to complete the CSI
                                NodePublishVolume and NodeUnpublishVolume calls.
                                This field is optional, and  may be empty if no secret is required. If the
                                secret object contains more than one secret, all secret references are passed.
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly specifies a read-only configuration for the volume.
                                Defaults to false (read/write).
                              '';
                            };
                            volumeAttributes = mkOption {
                              type = (types.nullOr (types.attrsOf types.str));
                              default = null;
                              description = ''
                                volumeAttributes stores driver-specific properties that are passed to the CSI
                                driver. Consult your driver's documentation for supported values.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "csi (Container Storage Interface) represents ephemeral storage that is handled by certain external CSI drivers.";
                    };
                    downwardAPI = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            defaultMode = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                Optional: mode bits to use on created files by default. Must be a
                                Optional: mode bits used to set permissions on created files by default.
                                Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                Defaults to 0644.
                                Directories within the path are not affected by this setting.
                                This might be in conflict with other options that affect the file
                                mode, like fsGroup, and the result can be other mode bits set.
                              '';
                            };
                            items = mkOption {
                              type = (
                                types.nullOr (
                                  types.listOf (mkTypedSubmodule {
                                    options = {
                                      fieldRef = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              apiVersion = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = "Version of the schema the FieldPath is written in terms of, defaults to \"v1\".";
                                              };
                                              fieldPath = mkOption {
                                                type = types.str;
                                                description = "Path of the field to select in the specified API version.";
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = "Required: Selects a field of the pod: only annotations, labels, name, namespace and uid are supported.";
                                      };
                                      mode = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          Optional: mode bits used to set permissions on this file, must be an octal value
                                          between 0000 and 0777 or a decimal value between 0 and 511.
                                          YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                          If not specified, the volume defaultMode will be used.
                                          This might be in conflict with other options that affect the file
                                          mode, like fsGroup, and the result can be other mode bits set.
                                        '';
                                      };
                                      path = mkOption {
                                        type = types.str;
                                        description = "Required: Path is  the relative path name of the file to be created. Must not be absolute or contain the '..' path. Must be utf-8 encoded. The first item of the relative path must not start with '..'";
                                      };
                                      resourceFieldRef = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              containerName = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = "Container name: required for volumes, optional for env vars";
                                              };
                                              divisor = mkOption {
                                                type = (types.nullOr types.anything);
                                                default = null;
                                                description = "Specifies the output format of the exposed resources, defaults to \"1\"";
                                              };
                                              resource = mkOption {
                                                type = types.str;
                                                description = "Required: resource to select";
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = ''
                                          Selects a resource of the container: only resources limits and requests
                                          (limits.cpu, limits.memory, requests.cpu and requests.memory) are currently supported.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                )
                              );
                              default = null;
                              description = "Items is a list of downward API volume file";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "downwardAPI represents downward API about the pod that should populate this volume";
                    };
                    emptyDir = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            medium = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                medium represents what type of storage medium should back this directory.
                                The default is "" which means to use the node's default medium.
                                Must be an empty string (default) or Memory.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#emptydir
                              '';
                            };
                            sizeLimit = mkOption {
                              type = (types.nullOr types.anything);
                              default = null;
                              description = ''
                                sizeLimit is the total amount of local storage required for this EmptyDir volume.
                                The size limit is also applicable for memory medium.
                                The maximum usage on memory medium EmptyDir would be the minimum value between
                                the SizeLimit specified here and the sum of memory limits of all containers in a pod.
                                The default is nil which means that the limit is undefined.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#emptydir
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        emptyDir represents a temporary directory that shares a pod's lifetime.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#emptydir
                      '';
                    };
                    ephemeral = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            volumeClaimTemplate = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    metadata = mkOption {
                                      type = (types.nullOr types.attrs);
                                      default = null;
                                      description = ''
                                        May contain labels and annotations that will be copied into the PVC
                                        when creating it. No other fields are allowed and will be rejected during
                                        validation.
                                      '';
                                    };
                                    spec = mkOption {
                                      type = (
                                        mkTypedSubmodule {
                                          options = {
                                            accessModes = mkOption {
                                              type = (types.nullOr (types.listOf types.str));
                                              default = null;
                                              description = ''
                                                accessModes contains the desired access modes the volume should have.
                                                More info: https://kubernetes.io/docs/concepts/storage/persistent-volumes#access-modes-1
                                              '';
                                            };
                                            dataSource = mkOption {
                                              type = (
                                                types.nullOr (mkTypedSubmodule {
                                                  options = {
                                                    apiGroup = mkOption {
                                                      type = (types.nullOr types.str);
                                                      default = null;
                                                      description = ''
                                                        APIGroup is the group for the resource being referenced.
                                                        If APIGroup is not specified, the specified Kind must be in the core API group.
                                                        For any other third-party types, APIGroup is required.
                                                      '';
                                                    };
                                                    kind = mkOption {
                                                      type = types.str;
                                                      description = "Kind is the type of resource being referenced";
                                                    };
                                                    name = mkOption {
                                                      type = types.str;
                                                      description = "Name is the name of resource being referenced";
                                                    };
                                                  };
                                                  freeformType = types.attrs;
                                                })
                                              );
                                              default = null;
                                              description = ''
                                                dataSource field can be used to specify either:
                                                * An existing VolumeSnapshot object (snapshot.storage.k8s.io/VolumeSnapshot)
                                                * An existing PVC (PersistentVolumeClaim)
                                                If the provisioner or an external controller can support the specified data source,
                                                it will create a new volume based on the contents of the specified data source.
                                                When the AnyVolumeDataSource feature gate is enabled, dataSource contents will be copied to dataSourceRef,
                                                and dataSourceRef contents will be copied to dataSource when dataSourceRef.namespace is not specified.
                                                If the namespace is specified, then dataSourceRef will not be copied to dataSource.
                                              '';
                                            };
                                            dataSourceRef = mkOption {
                                              type = (
                                                types.nullOr (mkTypedSubmodule {
                                                  options = {
                                                    apiGroup = mkOption {
                                                      type = (types.nullOr types.str);
                                                      default = null;
                                                      description = ''
                                                        APIGroup is the group for the resource being referenced.
                                                        If APIGroup is not specified, the specified Kind must be in the core API group.
                                                        For any other third-party types, APIGroup is required.
                                                      '';
                                                    };
                                                    kind = mkOption {
                                                      type = types.str;
                                                      description = "Kind is the type of resource being referenced";
                                                    };
                                                    name = mkOption {
                                                      type = types.str;
                                                      description = "Name is the name of resource being referenced";
                                                    };
                                                    namespace = mkOption {
                                                      type = (types.nullOr types.str);
                                                      default = null;
                                                      description = ''
                                                        Namespace is the namespace of resource being referenced
                                                        Note that when a namespace is specified, a gateway.networking.k8s.io/ReferenceGrant object is required in the referent namespace to allow that namespace's owner to accept the reference. See the ReferenceGrant documentation for details.
                                                        (Alpha) This field requires the CrossNamespaceVolumeDataSource feature gate to be enabled.
                                                      '';
                                                    };
                                                  };
                                                  freeformType = types.attrs;
                                                })
                                              );
                                              default = null;
                                              description = ''
                                                dataSourceRef specifies the object from which to populate the volume with data, if a non-empty
                                                volume is desired. This may be any object from a non-empty API group (non
                                                core object) or a PersistentVolumeClaim object.
                                                When this field is specified, volume binding will only succeed if the type of
                                                the specified object matches some installed volume populator or dynamic
                                                provisioner.
                                                This field will replace the functionality of the dataSource field and as such
                                                if both fields are non-empty, they must have the same value. For backwards
                                                compatibility, when namespace isn't specified in dataSourceRef,
                                                both fields (dataSource and dataSourceRef) will be set to the same
                                                value automatically if one of them is empty and the other is non-empty.
                                                When namespace is specified in dataSourceRef,
                                                dataSource isn't set to the same value and must be empty.
                                                There are three important differences between dataSource and dataSourceRef:
                                                * While dataSource only allows two specific types of objects, dataSourceRef
                                                  allows any non-core object, as well as PersistentVolumeClaim objects.
                                                * While dataSource ignores disallowed values (dropping them), dataSourceRef
                                                  preserves all values, and generates an error if a disallowed value is
                                                  specified.
                                                * While dataSource only allows local objects, dataSourceRef allows objects
                                                  in any namespaces.
                                                (Beta) Using this field requires the AnyVolumeDataSource feature gate to be enabled.
                                                (Alpha) Using the namespace field of dataSourceRef requires the CrossNamespaceVolumeDataSource feature gate to be enabled.
                                              '';
                                            };
                                            resources = mkOption {
                                              type = (
                                                types.nullOr (mkTypedSubmodule {
                                                  options = {
                                                    limits = mkOption {
                                                      type = (types.nullOr (types.attrsOf types.anything));
                                                      default = null;
                                                      description = ''
                                                        Limits describes the maximum amount of compute resources allowed.
                                                        More info: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
                                                      '';
                                                    };
                                                    requests = mkOption {
                                                      type = (types.nullOr (types.attrsOf types.anything));
                                                      default = null;
                                                      description = ''
                                                        Requests describes the minimum amount of compute resources required.
                                                        If Requests is omitted for a container, it defaults to Limits if that is explicitly specified,
                                                        otherwise to an implementation-defined value. Requests cannot exceed Limits.
                                                        More info: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
                                                      '';
                                                    };
                                                  };
                                                  freeformType = types.attrs;
                                                })
                                              );
                                              default = null;
                                              description = ''
                                                resources represents the minimum resources the volume should have.
                                                Users are allowed to specify resource requirements
                                                that are lower than previous value but must still be higher than capacity recorded in the
                                                status field of the claim.
                                                More info: https://kubernetes.io/docs/concepts/storage/persistent-volumes#resources
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
                                              description = "selector is a label query over volumes to consider for binding.";
                                            };
                                            storageClassName = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = ''
                                                storageClassName is the name of the StorageClass required by the claim.
                                                More info: https://kubernetes.io/docs/concepts/storage/persistent-volumes#class-1
                                              '';
                                            };
                                            volumeAttributesClassName = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = ''
                                                volumeAttributesClassName may be used to set the VolumeAttributesClass used by this claim.
                                                If specified, the CSI driver will create or update the volume with the attributes defined
                                                in the corresponding VolumeAttributesClass. This has a different purpose than storageClassName,
                                                it can be changed after the claim is created. An empty string or nil value indicates that no
                                                VolumeAttributesClass will be applied to the claim. If the claim enters an Infeasible error state,
                                                this field can be reset to its previous value (including nil) to cancel the modification.
                                                If the resource referred to by volumeAttributesClass does not exist, this PersistentVolumeClaim will be
                                                set to a Pending state, as reflected by the modifyVolumeStatus field, until such as a resource
                                                exists.
                                                More info: https://kubernetes.io/docs/concepts/storage/volume-attributes-classes/
                                              '';
                                            };
                                            volumeMode = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = ''
                                                volumeMode defines what type of volume is required by the claim.
                                                Value of Filesystem is implied when not included in claim spec.
                                              '';
                                            };
                                            volumeName = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = "volumeName is the binding reference to the PersistentVolume backing this claim.";
                                            };
                                          };
                                          freeformType = types.attrs;
                                        }
                                      );
                                      description = ''
                                        The specification for the PersistentVolumeClaim. The entire content is
                                        copied unchanged into the PVC that gets created from this
                                        template. The same fields as in a PersistentVolumeClaim
                                        are also valid here.
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                Will be used to create a stand-alone PVC to provision the volume.
                                The pod in which this EphemeralVolumeSource is embedded will be the
                                owner of the PVC, i.e. the PVC will be deleted together with the
                                pod.  The name of the PVC will be `<pod name>-<volume name>` where
                                `<volume name>` is the name from the `PodSpec.Volumes` array
                                entry. Pod validation will reject the pod if the concatenated name
                                is not valid for a PVC (for example, too long).

                                An existing PVC with that name that is not owned by the pod
                                will *not* be used for the pod to avoid using an unrelated
                                volume by mistake. Starting the pod is then blocked until
                                the unrelated PVC is removed. If such a pre-created PVC is
                                meant to be used by the pod, the PVC has to updated with an
                                owner reference to the pod once the pod exists. Normally
                                this should not be necessary, but it may be useful when
                                manually reconstructing a broken cluster.

                                This field is read-only and no changes will be made by Kubernetes
                                to the PVC after it has been created.

                                Required, must not be nil.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        ephemeral represents a volume that is handled by a cluster storage driver.
                        The volume's lifecycle is tied to the pod that defines it - it will be created before the pod starts,
                        and deleted when the pod is removed.

                        Use this if:
                        a) the volume is only needed while the pod runs,
                        b) features of normal volumes like restoring from snapshot or capacity
                           tracking are needed,
                        c) the storage driver is specified through a storage class, and
                        d) the storage driver supports dynamic volume provisioning through
                           a PersistentVolumeClaim (see EphemeralVolumeSource for more
                           information on the connection between this volume type
                           and PersistentVolumeClaim).

                        Use PersistentVolumeClaim or one of the vendor-specific
                        APIs for volumes that persist for longer than the lifecycle
                        of an individual pod.

                        Use CSI for light-weight local ephemeral volumes if the CSI driver is meant to
                        be used that way - see the documentation of the driver for
                        more information.

                        A pod can use both types of ephemeral volumes and
                        persistent volumes at the same time.
                      '';
                    };
                    fc = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            lun = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = "lun is Optional: FC target lun number";
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly is Optional: Defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            targetWWNs = mkOption {
                              type = (types.nullOr (types.listOf types.str));
                              default = null;
                              description = "targetWWNs is Optional: FC target worldwide names (WWNs)";
                            };
                            wwids = mkOption {
                              type = (types.nullOr (types.listOf types.str));
                              default = null;
                              description = ''
                                wwids Optional: FC volume world wide identifiers (wwids)
                                Either wwids or combination of targetWWNs and lun must be set, but not both simultaneously.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "fc represents a Fibre Channel resource that is attached to a kubelet's host machine and then exposed to the pod.";
                    };
                    flexVolume = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            driver = mkOption {
                              type = types.str;
                              description = "driver is the name of the driver to use for this volume.";
                            };
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". The default filesystem depends on FlexVolume script.
                              '';
                            };
                            options = mkOption {
                              type = (types.nullOr (types.attrsOf types.str));
                              default = null;
                              description = "options is Optional: this field holds extra command options if any.";
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly is Optional: defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                secretRef is Optional: secretRef is reference to the secret object containing
                                sensitive information to pass to the plugin scripts. This may be
                                empty if no secret object is specified. If the secret object
                                contains more than one secret, all secrets are passed to the plugin
                                scripts.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        flexVolume represents a generic volume resource that is
                        provisioned/attached using an exec based plugin.
                        Deprecated: FlexVolume is deprecated. Consider using a CSIDriver instead.
                      '';
                    };
                    flocker = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            datasetName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                datasetName is Name of the dataset stored as metadata -> name on the dataset for Flocker
                                should be considered as deprecated
                              '';
                            };
                            datasetUUID = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "datasetUUID is the UUID of the dataset. This is unique identifier of a Flocker dataset";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        flocker represents a Flocker volume attached to a kubelet's host machine. This depends on the Flocker control service being running.
                        Deprecated: Flocker is deprecated and the in-tree flocker type is no longer supported.
                      '';
                    };
                    gcePersistentDisk = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is filesystem type of the volume that you want to mount.
                                Tip: Ensure that the filesystem type is supported by the host operating system.
                                Examples: "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#gcepersistentdisk
                              '';
                            };
                            partition = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                partition is the partition in the volume that you want to mount.
                                If omitted, the default is to mount by volume name.
                                Examples: For volume /dev/sda1, you specify the partition as "1".
                                Similarly, the volume partition for /dev/sda is "0" (or you can leave the property empty).
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#gcepersistentdisk
                              '';
                            };
                            pdName = mkOption {
                              type = types.str;
                              description = ''
                                pdName is unique name of the PD resource in GCE. Used to identify the disk in GCE.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#gcepersistentdisk
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the ReadOnly setting in VolumeMounts.
                                Defaults to false.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#gcepersistentdisk
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        gcePersistentDisk represents a GCE Disk resource that is attached to a
                        kubelet's host machine and then exposed to the pod.
                        Deprecated: GCEPersistentDisk is deprecated. All operations for the in-tree
                        gcePersistentDisk type are redirected to the pd.csi.storage.gke.io CSI driver.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#gcepersistentdisk
                      '';
                    };
                    gitRepo = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            directory = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                directory is the target directory name.
                                Must not contain or start with '..'.  If '.' is supplied, the volume directory will be the
                                git repository.  Otherwise, if specified, the volume will contain the git repository in
                                the subdirectory with the given name.
                              '';
                            };
                            repository = mkOption {
                              type = types.str;
                              description = "repository is the URL";
                            };
                            revision = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "revision is the commit hash for the specified revision.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        gitRepo represents a git repository at a particular revision.
                        Deprecated: GitRepo is deprecated. To provision a container with a git repo, mount an
                        EmptyDir into an InitContainer that clones the repo using git, then mount the EmptyDir
                        into the Pod's container.
                      '';
                    };
                    glusterfs = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            endpoints = mkOption {
                              type = types.str;
                              description = "endpoints is the endpoint name that details Glusterfs topology.";
                            };
                            path = mkOption {
                              type = types.str;
                              description = ''
                                path is the Glusterfs volume path.
                                More info: https://examples.k8s.io/volumes/glusterfs/README.md#create-a-pod
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the Glusterfs volume to be mounted with read-only permissions.
                                Defaults to false.
                                More info: https://examples.k8s.io/volumes/glusterfs/README.md#create-a-pod
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        glusterfs represents a Glusterfs mount on the host that shares a pod's lifetime.
                        Deprecated: Glusterfs is deprecated and the in-tree glusterfs type is no longer supported.
                      '';
                    };
                    hostPath = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            path = mkOption {
                              type = types.str;
                              description = ''
                                path of the directory on the host.
                                If the path is a symlink, it will follow the link to the real path.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#hostpath
                              '';
                            };
                            type = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                type for HostPath Volume
                                Defaults to ""
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#hostpath
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        hostPath represents a pre-existing file or directory on the host
                        machine that is directly exposed to the container. This is generally
                        used for system agents or other privileged things that are allowed
                        to see the host machine. Most containers will NOT need this.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#hostpath
                      '';
                    };
                    image = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            pullPolicy = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Policy for pulling OCI objects. Possible values are:
                                Always: the kubelet always attempts to pull the reference. Container creation will fail If the pull fails.
                                Never: the kubelet never pulls the reference and only uses a local image or artifact. Container creation will fail if the reference isn't present.
                                IfNotPresent: the kubelet pulls if the reference isn't already present on disk. Container creation will fail if the reference isn't present and the pull fails.
                                Defaults to Always if :latest tag is specified, or IfNotPresent otherwise.
                              '';
                            };
                            reference = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Required: Image or artifact reference to be used.
                                Behaves in the same way as pod.spec.containers[*].image.
                                Pull secrets will be assembled in the same way as for the container image by looking up node credentials, SA image pull secrets, and pod spec image pull secrets.
                                More info: https://kubernetes.io/docs/concepts/containers/images
                                This field is optional to allow higher level config management to default or override
                                container images in workload controllers like Deployments and StatefulSets.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        image represents an OCI object (a container image or artifact) pulled and mounted on the kubelet's host machine.
                        The volume is resolved at pod startup depending on which PullPolicy value is provided:

                        - Always: the kubelet always attempts to pull the reference. Container creation will fail If the pull fails.
                        - Never: the kubelet never pulls the reference and only uses a local image or artifact. Container creation will fail if the reference isn't present.
                        - IfNotPresent: the kubelet pulls if the reference isn't already present on disk. Container creation will fail if the reference isn't present and the pull fails.

                        The volume gets re-resolved if the pod gets deleted and recreated, which means that new remote content will become available on pod recreation.
                        A failure to resolve or pull the image during pod startup will block containers from starting and may add significant latency. Failures will be retried using normal volume backoff and will be reported on the pod reason and message.
                        The types of objects that may be mounted by this volume are defined by the container runtime implementation on a host machine and at minimum must include all valid types supported by the container image field.
                        The OCI object gets mounted in a single directory (spec.containers[*].volumeMounts.mountPath) by merging the manifest layers in the same way as for container images.
                        The volume will be mounted read-only (ro).
                        Sub path mounts for containers are not supported (spec.containers[*].volumeMounts.subpath) before 1.33.
                        The field spec.securityContext.fsGroupChangePolicy has no effect on this volume type.
                      '';
                    };
                    iscsi = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            chapAuthDiscovery = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = "chapAuthDiscovery defines whether support iSCSI Discovery CHAP authentication";
                            };
                            chapAuthSession = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = "chapAuthSession defines whether support iSCSI Session CHAP authentication";
                            };
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type of the volume that you want to mount.
                                Tip: Ensure that the filesystem type is supported by the host operating system.
                                Examples: "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#iscsi
                              '';
                            };
                            initiatorName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                initiatorName is the custom iSCSI Initiator Name.
                                If initiatorName is specified with iscsiInterface simultaneously, new iSCSI interface
                                <target portal>:<volume name> will be created for the connection.
                              '';
                            };
                            iqn = mkOption {
                              type = types.str;
                              description = "iqn is the target iSCSI Qualified Name.";
                            };
                            iscsiInterface = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                iscsiInterface is the interface Name that uses an iSCSI transport.
                                Defaults to 'default' (tcp).
                              '';
                            };
                            lun = mkOption {
                              type = types.int;
                              description = "lun represents iSCSI Target Lun number.";
                            };
                            portals = mkOption {
                              type = (types.nullOr (types.listOf types.str));
                              default = null;
                              description = ''
                                portals is the iSCSI Target Portal List. The portal is either an IP or ip_addr:port if the port
                                is other than default (typically TCP ports 860 and 3260).
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the ReadOnly setting in VolumeMounts.
                                Defaults to false.
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = "secretRef is the CHAP Secret for iSCSI target and initiator authentication";
                            };
                            targetPortal = mkOption {
                              type = types.str;
                              description = ''
                                targetPortal is iSCSI Target Portal. The Portal is either an IP or ip_addr:port if the port
                                is other than default (typically TCP ports 860 and 3260).
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        iscsi represents an ISCSI Disk resource that is attached to a
                        kubelet's host machine and then exposed to the pod.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes/#iscsi
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = ''
                        name of the volume.
                        Must be a DNS_LABEL and unique within the pod.
                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                      '';
                    };
                    nfs = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            path = mkOption {
                              type = types.str;
                              description = ''
                                path that is exported by the NFS server.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#nfs
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the NFS export to be mounted with read-only permissions.
                                Defaults to false.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#nfs
                              '';
                            };
                            server = mkOption {
                              type = types.str;
                              description = ''
                                server is the hostname or IP address of the NFS server.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#nfs
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        nfs represents an NFS mount on the host that shares a pod's lifetime
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#nfs
                      '';
                    };
                    persistentVolumeClaim = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            claimName = mkOption {
                              type = types.str;
                              description = ''
                                claimName is the name of a PersistentVolumeClaim in the same namespace as the pod using this volume.
                                More info: https://kubernetes.io/docs/concepts/storage/persistent-volumes#persistentvolumeclaims
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly Will force the ReadOnly setting in VolumeMounts.
                                Default false.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        persistentVolumeClaimVolumeSource represents a reference to a
                        PersistentVolumeClaim in the same namespace.
                        More info: https://kubernetes.io/docs/concepts/storage/persistent-volumes#persistentvolumeclaims
                      '';
                    };
                    photonPersistentDisk = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            pdID = mkOption {
                              type = types.str;
                              description = "pdID is the ID that identifies Photon Controller persistent disk";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        photonPersistentDisk represents a PhotonController persistent disk attached and mounted on kubelets host machine.
                        Deprecated: PhotonPersistentDisk is deprecated and the in-tree photonPersistentDisk type is no longer supported.
                      '';
                    };
                    portworxVolume = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fSType represents the filesystem type to mount
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            volumeID = mkOption {
                              type = types.str;
                              description = "volumeID uniquely identifies a Portworx volume";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        portworxVolume represents a portworx volume attached and mounted on kubelets host machine.
                        Deprecated: PortworxVolume is deprecated. All operations for the in-tree portworxVolume type
                        are redirected to the pxd.portworx.com CSI driver.
                      '';
                    };
                    projected = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            defaultMode = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                defaultMode are the mode bits used to set permissions on created files by default.
                                Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                Directories within the path are not affected by this setting.
                                This might be in conflict with other options that affect the file
                                mode, like fsGroup, and the result can be other mode bits set.
                              '';
                            };
                            sources = mkOption {
                              type = (
                                types.nullOr (
                                  types.listOf (mkTypedSubmodule {
                                    options = {
                                      clusterTrustBundle = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              labelSelector = mkOption {
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
                                                  Select all ClusterTrustBundles that match this label selector.  Only has
                                                  effect if signerName is set.  Mutually-exclusive with name.  If unset,
                                                  interpreted as "match nothing".  If set but empty, interpreted as "match
                                                  everything".
                                                '';
                                              };
                                              name = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Select a single ClusterTrustBundle by object name.  Mutually-exclusive
                                                  with signerName and labelSelector.
                                                '';
                                              };
                                              optional = mkOption {
                                                type = (types.nullOr types.bool);
                                                default = null;
                                                description = ''
                                                  If true, don't block pod startup if the referenced ClusterTrustBundle(s)
                                                  aren't available.  If using name, then the named ClusterTrustBundle is
                                                  allowed not to exist.  If using signerName, then the combination of
                                                  signerName and labelSelector is allowed to match zero
                                                  ClusterTrustBundles.
                                                '';
                                              };
                                              path = mkOption {
                                                type = types.str;
                                                description = "Relative path from the volume root to write the bundle.";
                                              };
                                              signerName = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Select all ClusterTrustBundles that match this signer name.
                                                  Mutually-exclusive with name.  The contents of all selected
                                                  ClusterTrustBundles will be unified and deduplicated.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = ''
                                          ClusterTrustBundle allows a pod to access the `.spec.trustBundle` field
                                          of ClusterTrustBundle objects in an auto-updating file.

                                          Alpha, gated by the ClusterTrustBundleProjection feature gate.

                                          ClusterTrustBundle objects can either be selected by name, or by the
                                          combination of signer name and a label selector.

                                          Kubelet performs aggressive normalization of the PEM contents written
                                          into the pod filesystem.  Esoteric PEM features such as inter-block
                                          comments and block headers are stripped.  Certificates are deduplicated.
                                          The ordering of certificates within the file is arbitrary, and Kubelet
                                          may change the order over time.
                                        '';
                                      };
                                      configMap = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              items = mkOption {
                                                type = (
                                                  types.nullOr (
                                                    types.listOf (mkTypedSubmodule {
                                                      options = {
                                                        key = mkOption {
                                                          type = types.str;
                                                          description = "key is the key to project.";
                                                        };
                                                        mode = mkOption {
                                                          type = (types.nullOr types.int);
                                                          default = null;
                                                          description = ''
                                                            mode is Optional: mode bits used to set permissions on this file.
                                                            Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                                            YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                                            If not specified, the volume defaultMode will be used.
                                                            This might be in conflict with other options that affect the file
                                                            mode, like fsGroup, and the result can be other mode bits set.
                                                          '';
                                                        };
                                                        path = mkOption {
                                                          type = types.str;
                                                          description = ''
                                                            path is the relative path of the file to map the key to.
                                                            May not be an absolute path.
                                                            May not contain the path element '..'.
                                                            May not start with the string '..'.
                                                          '';
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    })
                                                  )
                                                );
                                                default = null;
                                                description = ''
                                                  items if unspecified, each key-value pair in the Data field of the referenced
                                                  ConfigMap will be projected into the volume as a file whose name is the
                                                  key and content is the value. If specified, the listed keys will be
                                                  projected into the specified paths, and unlisted keys will not be
                                                  present. If a key is specified which is not present in the ConfigMap,
                                                  the volume setup will error unless it is marked optional. Paths must be
                                                  relative and may not contain the '..' path or start with '..'.
                                                '';
                                              };
                                              name = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Name of the referent.
                                                  This field is effectively required, but due to backwards compatibility is
                                                  allowed to be empty. Instances of this type with an empty value here are
                                                  almost certainly wrong.
                                                  More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                                '';
                                              };
                                              optional = mkOption {
                                                type = (types.nullOr types.bool);
                                                default = null;
                                                description = "optional specify whether the ConfigMap or its keys must be defined";
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = "configMap information about the configMap data to project";
                                      };
                                      downwardAPI = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              items = mkOption {
                                                type = (
                                                  types.nullOr (
                                                    types.listOf (mkTypedSubmodule {
                                                      options = {
                                                        fieldRef = mkOption {
                                                          type = (
                                                            types.nullOr (mkTypedSubmodule {
                                                              options = {
                                                                apiVersion = mkOption {
                                                                  type = (types.nullOr types.str);
                                                                  default = null;
                                                                  description = "Version of the schema the FieldPath is written in terms of, defaults to \"v1\".";
                                                                };
                                                                fieldPath = mkOption {
                                                                  type = types.str;
                                                                  description = "Path of the field to select in the specified API version.";
                                                                };
                                                              };
                                                              freeformType = types.attrs;
                                                            })
                                                          );
                                                          default = null;
                                                          description = "Required: Selects a field of the pod: only annotations, labels, name, namespace and uid are supported.";
                                                        };
                                                        mode = mkOption {
                                                          type = (types.nullOr types.int);
                                                          default = null;
                                                          description = ''
                                                            Optional: mode bits used to set permissions on this file, must be an octal value
                                                            between 0000 and 0777 or a decimal value between 0 and 511.
                                                            YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                                            If not specified, the volume defaultMode will be used.
                                                            This might be in conflict with other options that affect the file
                                                            mode, like fsGroup, and the result can be other mode bits set.
                                                          '';
                                                        };
                                                        path = mkOption {
                                                          type = types.str;
                                                          description = "Required: Path is  the relative path name of the file to be created. Must not be absolute or contain the '..' path. Must be utf-8 encoded. The first item of the relative path must not start with '..'";
                                                        };
                                                        resourceFieldRef = mkOption {
                                                          type = (
                                                            types.nullOr (mkTypedSubmodule {
                                                              options = {
                                                                containerName = mkOption {
                                                                  type = (types.nullOr types.str);
                                                                  default = null;
                                                                  description = "Container name: required for volumes, optional for env vars";
                                                                };
                                                                divisor = mkOption {
                                                                  type = (types.nullOr types.anything);
                                                                  default = null;
                                                                  description = "Specifies the output format of the exposed resources, defaults to \"1\"";
                                                                };
                                                                resource = mkOption {
                                                                  type = types.str;
                                                                  description = "Required: resource to select";
                                                                };
                                                              };
                                                              freeformType = types.attrs;
                                                            })
                                                          );
                                                          default = null;
                                                          description = ''
                                                            Selects a resource of the container: only resources limits and requests
                                                            (limits.cpu, limits.memory, requests.cpu and requests.memory) are currently supported.
                                                          '';
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    })
                                                  )
                                                );
                                                default = null;
                                                description = "Items is a list of DownwardAPIVolume file";
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = "downwardAPI information about the downwardAPI data to project";
                                      };
                                      podCertificate = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              certificateChainPath = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Write the certificate chain at this path in the projected volume.

                                                  Most applications should use credentialBundlePath.  When using keyPath
                                                  and certificateChainPath, your application needs to check that the key
                                                  and leaf certificate are consistent, because it is possible to read the
                                                  files mid-rotation.
                                                '';
                                              };
                                              credentialBundlePath = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Write the credential bundle at this path in the projected volume.

                                                  The credential bundle is a single file that contains multiple PEM blocks.
                                                  The first PEM block is a PRIVATE KEY block, containing a PKCS#8 private
                                                  key.

                                                  The remaining blocks are CERTIFICATE blocks, containing the issued
                                                  certificate chain from the signer (leaf and any intermediates).

                                                  Using credentialBundlePath lets your Pod's application code make a single
                                                  atomic read that retrieves a consistent key and certificate chain.  If you
                                                  project them to separate files, your application code will need to
                                                  additionally check that the leaf certificate was issued to the key.
                                                '';
                                              };
                                              keyPath = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Write the key at this path in the projected volume.

                                                  Most applications should use credentialBundlePath.  When using keyPath
                                                  and certificateChainPath, your application needs to check that the key
                                                  and leaf certificate are consistent, because it is possible to read the
                                                  files mid-rotation.
                                                '';
                                              };
                                              keyType = mkOption {
                                                type = types.str;
                                                description = ''
                                                  The type of keypair Kubelet will generate for the pod.

                                                  Valid values are "RSA3072", "RSA4096", "ECDSAP256", "ECDSAP384",
                                                  "ECDSAP521", and "ED25519".
                                                '';
                                              };
                                              maxExpirationSeconds = mkOption {
                                                type = (types.nullOr types.int);
                                                default = null;
                                                description = ''
                                                  maxExpirationSeconds is the maximum lifetime permitted for the
                                                  certificate.

                                                  Kubelet copies this value verbatim into the PodCertificateRequests it
                                                  generates for this projection.

                                                  If omitted, kube-apiserver will set it to 86400(24 hours). kube-apiserver
                                                  will reject values shorter than 3600 (1 hour).  The maximum allowable
                                                  value is 7862400 (91 days).

                                                  The signer implementation is then free to issue a certificate with any
                                                  lifetime *shorter* than MaxExpirationSeconds, but no shorter than 3600
                                                  seconds (1 hour).  This constraint is enforced by kube-apiserver.
                                                  `kubernetes.io` signers will never issue certificates with a lifetime
                                                  longer than 24 hours.
                                                '';
                                              };
                                              signerName = mkOption {
                                                type = types.str;
                                                description = "Kubelet's generated CSRs will be addressed to this signer.";
                                              };
                                              userAnnotations = mkOption {
                                                type = (types.nullOr (types.attrsOf types.str));
                                                default = null;
                                                description = ''
                                                  userAnnotations allow pod authors to pass additional information to
                                                  the signer implementation.  Kubernetes does not restrict or validate this
                                                  metadata in any way.

                                                  These values are copied verbatim into the `spec.unverifiedUserAnnotations` field of
                                                  the PodCertificateRequest objects that Kubelet creates.

                                                  Entries are subject to the same validation as object metadata annotations,
                                                  with the addition that all keys must be domain-prefixed. No restrictions
                                                  are placed on values, except an overall size limitation on the entire field.

                                                  Signers should document the keys and values they support. Signers should
                                                  deny requests that contain keys they do not recognize.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = ''
                                          Projects an auto-rotating credential bundle (private key and certificate
                                          chain) that the pod can use either as a TLS client or server.

                                          Kubelet generates a private key and uses it to send a
                                          PodCertificateRequest to the named signer.  Once the signer approves the
                                          request and issues a certificate chain, Kubelet writes the key and
                                          certificate chain to the pod filesystem.  The pod does not start until
                                          certificates have been issued for each podCertificate projected volume
                                          source in its spec.

                                          Kubelet will begin trying to rotate the certificate at the time indicated
                                          by the signer using the PodCertificateRequest.Status.BeginRefreshAt
                                          timestamp.

                                          Kubelet can write a single file, indicated by the credentialBundlePath
                                          field, or separate files, indicated by the keyPath and
                                          certificateChainPath fields.

                                          The credential bundle is a single file in PEM format.  The first PEM
                                          entry is the private key (in PKCS#8 format), and the remaining PEM
                                          entries are the certificate chain issued by the signer (typically,
                                          signers will return their certificate chain in leaf-to-root order).

                                          Prefer using the credential bundle format, since your application code
                                          can read it atomically.  If you use keyPath and certificateChainPath,
                                          your application must make two separate file reads. If these coincide
                                          with a certificate rotation, it is possible that the private key and leaf
                                          certificate you read may not correspond to each other.  Your application
                                          will need to check for this condition, and re-read until they are
                                          consistent.

                                          The named signer controls chooses the format of the certificate it
                                          issues; consult the signer implementation's documentation to learn how to
                                          use the certificates it issues.
                                        '';
                                      };
                                      secret = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              items = mkOption {
                                                type = (
                                                  types.nullOr (
                                                    types.listOf (mkTypedSubmodule {
                                                      options = {
                                                        key = mkOption {
                                                          type = types.str;
                                                          description = "key is the key to project.";
                                                        };
                                                        mode = mkOption {
                                                          type = (types.nullOr types.int);
                                                          default = null;
                                                          description = ''
                                                            mode is Optional: mode bits used to set permissions on this file.
                                                            Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                                            YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                                            If not specified, the volume defaultMode will be used.
                                                            This might be in conflict with other options that affect the file
                                                            mode, like fsGroup, and the result can be other mode bits set.
                                                          '';
                                                        };
                                                        path = mkOption {
                                                          type = types.str;
                                                          description = ''
                                                            path is the relative path of the file to map the key to.
                                                            May not be an absolute path.
                                                            May not contain the path element '..'.
                                                            May not start with the string '..'.
                                                          '';
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    })
                                                  )
                                                );
                                                default = null;
                                                description = ''
                                                  items if unspecified, each key-value pair in the Data field of the referenced
                                                  Secret will be projected into the volume as a file whose name is the
                                                  key and content is the value. If specified, the listed keys will be
                                                  projected into the specified paths, and unlisted keys will not be
                                                  present. If a key is specified which is not present in the Secret,
                                                  the volume setup will error unless it is marked optional. Paths must be
                                                  relative and may not contain the '..' path or start with '..'.
                                                '';
                                              };
                                              name = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Name of the referent.
                                                  This field is effectively required, but due to backwards compatibility is
                                                  allowed to be empty. Instances of this type with an empty value here are
                                                  almost certainly wrong.
                                                  More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                                '';
                                              };
                                              optional = mkOption {
                                                type = (types.nullOr types.bool);
                                                default = null;
                                                description = "optional field specify whether the Secret or its key must be defined";
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = "secret information about the secret data to project";
                                      };
                                      serviceAccountToken = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              audience = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  audience is the intended audience of the token. A recipient of a token
                                                  must identify itself with an identifier specified in the audience of the
                                                  token, and otherwise should reject the token. The audience defaults to the
                                                  identifier of the apiserver.
                                                '';
                                              };
                                              expirationSeconds = mkOption {
                                                type = (types.nullOr types.int);
                                                default = null;
                                                description = ''
                                                  expirationSeconds is the requested duration of validity of the service
                                                  account token. As the token approaches expiration, the kubelet volume
                                                  plugin will proactively rotate the service account token. The kubelet will
                                                  start trying to rotate the token if the token is older than 80 percent of
                                                  its time to live or if the token is older than 24 hours.Defaults to 1 hour
                                                  and must be at least 10 minutes.
                                                '';
                                              };
                                              path = mkOption {
                                                type = types.str;
                                                description = ''
                                                  path is the path relative to the mount point of the file to project the
                                                  token into.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = "serviceAccountToken is information about the serviceAccountToken data to project";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                )
                              );
                              default = null;
                              description = ''
                                sources is the list of volume projections. Each entry in this list
                                handles one source.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "projected items for all in one resources secrets, configmaps, and downward API";
                    };
                    quobyte = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            group = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                group to map volume access to
                                Default is no group
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the Quobyte volume to be mounted with read-only permissions.
                                Defaults to false.
                              '';
                            };
                            registry = mkOption {
                              type = types.str;
                              description = ''
                                registry represents a single or multiple Quobyte Registry services
                                specified as a string as host:port pair (multiple entries are separated with commas)
                                which acts as the central registry for volumes
                              '';
                            };
                            tenant = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                tenant owning the given Quobyte volume in the Backend
                                Used with dynamically provisioned Quobyte volumes, value is set by the plugin
                              '';
                            };
                            user = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                user to map volume access to
                                Defaults to serivceaccount user
                              '';
                            };
                            volume = mkOption {
                              type = types.str;
                              description = "volume is a string that references an already created Quobyte volume by name.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        quobyte represents a Quobyte mount on the host that shares a pod's lifetime.
                        Deprecated: Quobyte is deprecated and the in-tree quobyte type is no longer supported.
                      '';
                    };
                    rbd = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type of the volume that you want to mount.
                                Tip: Ensure that the filesystem type is supported by the host operating system.
                                Examples: "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#rbd
                              '';
                            };
                            image = mkOption {
                              type = types.str;
                              description = ''
                                image is the rados image name.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            keyring = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                keyring is the path to key ring for RBDUser.
                                Default is /etc/ceph/keyring.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            monitors = mkOption {
                              type = (types.listOf types.str);
                              description = ''
                                monitors is a collection of Ceph monitors.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            pool = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                pool is the rados pool name.
                                Default is rbd.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the ReadOnly setting in VolumeMounts.
                                Defaults to false.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                secretRef is name of the authentication secret for RBDUser. If provided
                                overrides keyring.
                                Default is nil.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            user = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                user is the rados user name.
                                Default is admin.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        rbd represents a Rados Block Device mount on the host that shares a pod's lifetime.
                        Deprecated: RBD is deprecated and the in-tree rbd type is no longer supported.
                      '';
                    };
                    scaleIO = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs".
                                Default is "xfs".
                              '';
                            };
                            gateway = mkOption {
                              type = types.str;
                              description = "gateway is the host address of the ScaleIO API Gateway.";
                            };
                            protectionDomain = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "protectionDomain is the name of the ScaleIO Protection Domain for the configured storage.";
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly Defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                }
                              );
                              description = ''
                                secretRef references to the secret for ScaleIO user and other
                                sensitive information. If this is not provided, Login operation will fail.
                              '';
                            };
                            sslEnabled = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = "sslEnabled Flag enable/disable SSL communication with Gateway, default false";
                            };
                            storageMode = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                storageMode indicates whether the storage for a volume should be ThickProvisioned or ThinProvisioned.
                                Default is ThinProvisioned.
                              '';
                            };
                            storagePool = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "storagePool is the ScaleIO Storage Pool associated with the protection domain.";
                            };
                            system = mkOption {
                              type = types.str;
                              description = "system is the name of the storage system as configured in ScaleIO.";
                            };
                            volumeName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                volumeName is the name of a volume already created in the ScaleIO system
                                that is associated with this volume source.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        scaleIO represents a ScaleIO persistent volume attached and mounted on Kubernetes nodes.
                        Deprecated: ScaleIO is deprecated and the in-tree scaleIO type is no longer supported.
                      '';
                    };
                    secret = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            defaultMode = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                defaultMode is Optional: mode bits used to set permissions on created files by default.
                                Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                YAML accepts both octal and decimal values, JSON requires decimal values
                                for mode bits. Defaults to 0644.
                                Directories within the path are not affected by this setting.
                                This might be in conflict with other options that affect the file
                                mode, like fsGroup, and the result can be other mode bits set.
                              '';
                            };
                            items = mkOption {
                              type = (
                                types.nullOr (
                                  types.listOf (mkTypedSubmodule {
                                    options = {
                                      key = mkOption {
                                        type = types.str;
                                        description = "key is the key to project.";
                                      };
                                      mode = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          mode is Optional: mode bits used to set permissions on this file.
                                          Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                          YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                          If not specified, the volume defaultMode will be used.
                                          This might be in conflict with other options that affect the file
                                          mode, like fsGroup, and the result can be other mode bits set.
                                        '';
                                      };
                                      path = mkOption {
                                        type = types.str;
                                        description = ''
                                          path is the relative path of the file to map the key to.
                                          May not be an absolute path.
                                          May not contain the path element '..'.
                                          May not start with the string '..'.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                )
                              );
                              default = null;
                              description = ''
                                items If unspecified, each key-value pair in the Data field of the referenced
                                Secret will be projected into the volume as a file whose name is the
                                key and content is the value. If specified, the listed keys will be
                                projected into the specified paths, and unlisted keys will not be
                                present. If a key is specified which is not present in the Secret,
                                the volume setup will error unless it is marked optional. Paths must be
                                relative and may not contain the '..' path or start with '..'.
                              '';
                            };
                            optional = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = "optional field specify whether the Secret or its keys must be defined";
                            };
                            secretName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                secretName is the name of the secret in the pod's namespace to use.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#secret
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        secret represents a secret that should populate this volume.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#secret
                      '';
                    };
                    storageos = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                secretRef specifies the secret to use for obtaining the StorageOS API
                                credentials.  If not specified, default values will be attempted.
                              '';
                            };
                            volumeName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                volumeName is the human-readable name of the StorageOS volume.  Volume
                                names are only unique within a namespace.
                              '';
                            };
                            volumeNamespace = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                volumeNamespace specifies the scope of the volume within StorageOS.  If no
                                namespace is specified then the Pod's namespace will be used.  This allows the
                                Kubernetes name scoping to be mirrored within StorageOS for tighter integration.
                                Set VolumeName to any name to override the default behaviour.
                                Set to "default" if you are not using namespaces within StorageOS.
                                Namespaces that do not pre-exist within StorageOS will be created.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        storageOS represents a StorageOS volume attached and mounted on Kubernetes nodes.
                        Deprecated: StorageOS is deprecated and the in-tree storageos type is no longer supported.
                      '';
                    };
                    vsphereVolume = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            storagePolicyID = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "storagePolicyID is the storage Policy Based Management (SPBM) profile ID associated with the StoragePolicyName.";
                            };
                            storagePolicyName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "storagePolicyName is the storage Policy Based Management (SPBM) profile name.";
                            };
                            volumePath = mkOption {
                              type = types.str;
                              description = "volumePath is the path that identifies vSphere volume vmdk";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        vsphereVolume represents a vSphere volume attached and mounted on kubelets host machine.
                        Deprecated: VsphereVolume is deprecated. All operations for the in-tree vsphereVolume type
                        are redirected to the csi.vsphere.vmware.com CSI driver.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  NBSetupKey = mkResource {
    apiVersion = "netbird.io/v1";
    kind = "NBSetupKey";
    specType = (
      mkTypedSubmodule {
        options = {
          managementURL = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = "ManagementURL optional, override operator management URL";
          };
          secretKeyRef = mkOption {
            type = (
              mkTypedSubmodule {
                options = {
                  key = mkOption {
                    type = types.str;
                    description = "The key of the secret to select from.  Must be a valid secret key.";
                  };
                  name = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      Name of the referent.
                      This field is effectively required, but due to backwards compatibility is
                      allowed to be empty. Instances of this type with an empty value here are
                      almost certainly wrong.
                      More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                    '';
                  };
                  optional = mkOption {
                    type = (types.nullOr types.bool);
                    default = null;
                    description = "Specify whether the Secret or its key must be defined";
                  };
                };
                freeformType = types.attrs;
              }
            );
            description = "SecretKeyRef is a reference to the secret containing the setup key";
          };
          volumeMounts = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    mountPath = mkOption {
                      type = types.str;
                      description = ''
                        Path within the container at which the volume should be mounted.  Must
                        not contain ':'.
                      '';
                    };
                    mountPropagation = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        mountPropagation determines how mounts are propagated from the host
                        to container and the other way around.
                        When not set, MountPropagationNone is used.
                        This field is beta in 1.10.
                        When RecursiveReadOnly is set to IfPossible or to Enabled, MountPropagation must be None or unspecified
                        (which defaults to None).
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = "This must match the Name of a Volume.";
                    };
                    readOnly = mkOption {
                      type = (types.nullOr types.bool);
                      default = null;
                      description = ''
                        Mounted read-only if true, read-write otherwise (false or unspecified).
                        Defaults to false.
                      '';
                    };
                    recursiveReadOnly = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        RecursiveReadOnly specifies whether read-only mounts should be handled
                        recursively.

                        If ReadOnly is false, this field has no meaning and must be unspecified.

                        If ReadOnly is true, and this field is set to Disabled, the mount is not made
                        recursively read-only.  If this field is set to IfPossible, the mount is made
                        recursively read-only, if it is supported by the container runtime.  If this
                        field is set to Enabled, the mount is made recursively read-only if it is
                        supported by the container runtime, otherwise the pod will not be started and
                        an error will be generated to indicate the reason.

                        If this field is set to IfPossible or Enabled, MountPropagation must be set to
                        None (or be unspecified, which defaults to None).

                        If this field is not specified, it is treated as an equivalent of Disabled.
                      '';
                    };
                    subPath = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Path within the volume from which the container's volume should be mounted.
                        Defaults to "" (volume's root).
                      '';
                    };
                    subPathExpr = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Expanded path within the volume from which the container's volume should be mounted.
                        Behaves similarly to SubPath but environment variable references $(VAR_NAME) are expanded using the container's environment.
                        Defaults to "" (volume's root).
                        SubPathExpr and SubPath are mutually exclusive.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = "VolumeMounts optional, additional volumeMounts for NetBird container";
          };
          volumes = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    awsElasticBlockStore = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type of the volume that you want to mount.
                                Tip: Ensure that the filesystem type is supported by the host operating system.
                                Examples: "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#awselasticblockstore
                              '';
                            };
                            partition = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                partition is the partition in the volume that you want to mount.
                                If omitted, the default is to mount by volume name.
                                Examples: For volume /dev/sda1, you specify the partition as "1".
                                Similarly, the volume partition for /dev/sda is "0" (or you can leave the property empty).
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly value true will force the readOnly setting in VolumeMounts.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#awselasticblockstore
                              '';
                            };
                            volumeID = mkOption {
                              type = types.str;
                              description = ''
                                volumeID is unique ID of the persistent disk resource in AWS (Amazon EBS volume).
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#awselasticblockstore
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        awsElasticBlockStore represents an AWS Disk resource that is attached to a
                        kubelet's host machine and then exposed to the pod.
                        Deprecated: AWSElasticBlockStore is deprecated. All operations for the in-tree
                        awsElasticBlockStore type are redirected to the ebs.csi.aws.com CSI driver.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#awselasticblockstore
                      '';
                    };
                    azureDisk = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            cachingMode = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "cachingMode is the Host Caching mode: None, Read Only, Read Write.";
                            };
                            diskName = mkOption {
                              type = types.str;
                              description = "diskName is the Name of the data disk in the blob storage";
                            };
                            diskURI = mkOption {
                              type = types.str;
                              description = "diskURI is the URI of data disk in the blob storage";
                            };
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is Filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            kind = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "kind expected values are Shared: multiple blob disks per storage account  Dedicated: single blob disk per storage account  Managed: azure managed data disk (only in managed availability set). defaults to shared";
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly Defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        azureDisk represents an Azure Data Disk mount on the host and bind mount to the pod.
                        Deprecated: AzureDisk is deprecated. All operations for the in-tree azureDisk type
                        are redirected to the disk.csi.azure.com CSI driver.
                      '';
                    };
                    azureFile = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            secretName = mkOption {
                              type = types.str;
                              description = "secretName is the  name of secret that contains Azure Storage Account Name and Key";
                            };
                            shareName = mkOption {
                              type = types.str;
                              description = "shareName is the azure share Name";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        azureFile represents an Azure File Service mount on the host and bind mount to the pod.
                        Deprecated: AzureFile is deprecated. All operations for the in-tree azureFile type
                        are redirected to the file.csi.azure.com CSI driver.
                      '';
                    };
                    cephfs = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            monitors = mkOption {
                              type = (types.listOf types.str);
                              description = ''
                                monitors is Required: Monitors is a collection of Ceph monitors
                                More info: https://examples.k8s.io/volumes/cephfs/README.md#how-to-use-it
                              '';
                            };
                            path = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "path is Optional: Used as the mounted root, rather than the full Ceph tree, default is /";
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly is Optional: Defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                                More info: https://examples.k8s.io/volumes/cephfs/README.md#how-to-use-it
                              '';
                            };
                            secretFile = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                secretFile is Optional: SecretFile is the path to key ring for User, default is /etc/ceph/user.secret
                                More info: https://examples.k8s.io/volumes/cephfs/README.md#how-to-use-it
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                secretRef is Optional: SecretRef is reference to the authentication secret for User, default is empty.
                                More info: https://examples.k8s.io/volumes/cephfs/README.md#how-to-use-it
                              '';
                            };
                            user = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                user is optional: User is the rados user name, default is admin
                                More info: https://examples.k8s.io/volumes/cephfs/README.md#how-to-use-it
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        cephFS represents a Ceph FS mount on the host that shares a pod's lifetime.
                        Deprecated: CephFS is deprecated and the in-tree cephfs type is no longer supported.
                      '';
                    };
                    cinder = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Examples: "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                                More info: https://examples.k8s.io/mysql-cinder-pd/README.md
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                                More info: https://examples.k8s.io/mysql-cinder-pd/README.md
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                secretRef is optional: points to a secret object containing parameters used to connect
                                to OpenStack.
                              '';
                            };
                            volumeID = mkOption {
                              type = types.str;
                              description = ''
                                volumeID used to identify the volume in cinder.
                                More info: https://examples.k8s.io/mysql-cinder-pd/README.md
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        cinder represents a cinder volume attached and mounted on kubelets host machine.
                        Deprecated: Cinder is deprecated. All operations for the in-tree cinder type
                        are redirected to the cinder.csi.openstack.org CSI driver.
                        More info: https://examples.k8s.io/mysql-cinder-pd/README.md
                      '';
                    };
                    configMap = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            defaultMode = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                defaultMode is optional: mode bits used to set permissions on created files by default.
                                Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                Defaults to 0644.
                                Directories within the path are not affected by this setting.
                                This might be in conflict with other options that affect the file
                                mode, like fsGroup, and the result can be other mode bits set.
                              '';
                            };
                            items = mkOption {
                              type = (
                                types.nullOr (
                                  types.listOf (mkTypedSubmodule {
                                    options = {
                                      key = mkOption {
                                        type = types.str;
                                        description = "key is the key to project.";
                                      };
                                      mode = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          mode is Optional: mode bits used to set permissions on this file.
                                          Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                          YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                          If not specified, the volume defaultMode will be used.
                                          This might be in conflict with other options that affect the file
                                          mode, like fsGroup, and the result can be other mode bits set.
                                        '';
                                      };
                                      path = mkOption {
                                        type = types.str;
                                        description = ''
                                          path is the relative path of the file to map the key to.
                                          May not be an absolute path.
                                          May not contain the path element '..'.
                                          May not start with the string '..'.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                )
                              );
                              default = null;
                              description = ''
                                items if unspecified, each key-value pair in the Data field of the referenced
                                ConfigMap will be projected into the volume as a file whose name is the
                                key and content is the value. If specified, the listed keys will be
                                projected into the specified paths, and unlisted keys will not be
                                present. If a key is specified which is not present in the ConfigMap,
                                the volume setup will error unless it is marked optional. Paths must be
                                relative and may not contain the '..' path or start with '..'.
                              '';
                            };
                            name = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Name of the referent.
                                This field is effectively required, but due to backwards compatibility is
                                allowed to be empty. Instances of this type with an empty value here are
                                almost certainly wrong.
                                More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                              '';
                            };
                            optional = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = "optional specify whether the ConfigMap or its keys must be defined";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "configMap represents a configMap that should populate this volume";
                    };
                    csi = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            driver = mkOption {
                              type = types.str;
                              description = ''
                                driver is the name of the CSI driver that handles this volume.
                                Consult with your admin for the correct name as registered in the cluster.
                              '';
                            };
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType to mount. Ex. "ext4", "xfs", "ntfs".
                                If not provided, the empty value is passed to the associated CSI driver
                                which will determine the default filesystem to apply.
                              '';
                            };
                            nodePublishSecretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                nodePublishSecretRef is a reference to the secret object containing
                                sensitive information to pass to the CSI driver to complete the CSI
                                NodePublishVolume and NodeUnpublishVolume calls.
                                This field is optional, and  may be empty if no secret is required. If the
                                secret object contains more than one secret, all secret references are passed.
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly specifies a read-only configuration for the volume.
                                Defaults to false (read/write).
                              '';
                            };
                            volumeAttributes = mkOption {
                              type = (types.nullOr (types.attrsOf types.str));
                              default = null;
                              description = ''
                                volumeAttributes stores driver-specific properties that are passed to the CSI
                                driver. Consult your driver's documentation for supported values.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "csi (Container Storage Interface) represents ephemeral storage that is handled by certain external CSI drivers.";
                    };
                    downwardAPI = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            defaultMode = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                Optional: mode bits to use on created files by default. Must be a
                                Optional: mode bits used to set permissions on created files by default.
                                Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                Defaults to 0644.
                                Directories within the path are not affected by this setting.
                                This might be in conflict with other options that affect the file
                                mode, like fsGroup, and the result can be other mode bits set.
                              '';
                            };
                            items = mkOption {
                              type = (
                                types.nullOr (
                                  types.listOf (mkTypedSubmodule {
                                    options = {
                                      fieldRef = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              apiVersion = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = "Version of the schema the FieldPath is written in terms of, defaults to \"v1\".";
                                              };
                                              fieldPath = mkOption {
                                                type = types.str;
                                                description = "Path of the field to select in the specified API version.";
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = "Required: Selects a field of the pod: only annotations, labels, name, namespace and uid are supported.";
                                      };
                                      mode = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          Optional: mode bits used to set permissions on this file, must be an octal value
                                          between 0000 and 0777 or a decimal value between 0 and 511.
                                          YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                          If not specified, the volume defaultMode will be used.
                                          This might be in conflict with other options that affect the file
                                          mode, like fsGroup, and the result can be other mode bits set.
                                        '';
                                      };
                                      path = mkOption {
                                        type = types.str;
                                        description = "Required: Path is  the relative path name of the file to be created. Must not be absolute or contain the '..' path. Must be utf-8 encoded. The first item of the relative path must not start with '..'";
                                      };
                                      resourceFieldRef = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              containerName = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = "Container name: required for volumes, optional for env vars";
                                              };
                                              divisor = mkOption {
                                                type = (types.nullOr types.anything);
                                                default = null;
                                                description = "Specifies the output format of the exposed resources, defaults to \"1\"";
                                              };
                                              resource = mkOption {
                                                type = types.str;
                                                description = "Required: resource to select";
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = ''
                                          Selects a resource of the container: only resources limits and requests
                                          (limits.cpu, limits.memory, requests.cpu and requests.memory) are currently supported.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                )
                              );
                              default = null;
                              description = "Items is a list of downward API volume file";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "downwardAPI represents downward API about the pod that should populate this volume";
                    };
                    emptyDir = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            medium = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                medium represents what type of storage medium should back this directory.
                                The default is "" which means to use the node's default medium.
                                Must be an empty string (default) or Memory.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#emptydir
                              '';
                            };
                            sizeLimit = mkOption {
                              type = (types.nullOr types.anything);
                              default = null;
                              description = ''
                                sizeLimit is the total amount of local storage required for this EmptyDir volume.
                                The size limit is also applicable for memory medium.
                                The maximum usage on memory medium EmptyDir would be the minimum value between
                                the SizeLimit specified here and the sum of memory limits of all containers in a pod.
                                The default is nil which means that the limit is undefined.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#emptydir
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        emptyDir represents a temporary directory that shares a pod's lifetime.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#emptydir
                      '';
                    };
                    ephemeral = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            volumeClaimTemplate = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    metadata = mkOption {
                                      type = (types.nullOr types.attrs);
                                      default = null;
                                      description = ''
                                        May contain labels and annotations that will be copied into the PVC
                                        when creating it. No other fields are allowed and will be rejected during
                                        validation.
                                      '';
                                    };
                                    spec = mkOption {
                                      type = (
                                        mkTypedSubmodule {
                                          options = {
                                            accessModes = mkOption {
                                              type = (types.nullOr (types.listOf types.str));
                                              default = null;
                                              description = ''
                                                accessModes contains the desired access modes the volume should have.
                                                More info: https://kubernetes.io/docs/concepts/storage/persistent-volumes#access-modes-1
                                              '';
                                            };
                                            dataSource = mkOption {
                                              type = (
                                                types.nullOr (mkTypedSubmodule {
                                                  options = {
                                                    apiGroup = mkOption {
                                                      type = (types.nullOr types.str);
                                                      default = null;
                                                      description = ''
                                                        APIGroup is the group for the resource being referenced.
                                                        If APIGroup is not specified, the specified Kind must be in the core API group.
                                                        For any other third-party types, APIGroup is required.
                                                      '';
                                                    };
                                                    kind = mkOption {
                                                      type = types.str;
                                                      description = "Kind is the type of resource being referenced";
                                                    };
                                                    name = mkOption {
                                                      type = types.str;
                                                      description = "Name is the name of resource being referenced";
                                                    };
                                                  };
                                                  freeformType = types.attrs;
                                                })
                                              );
                                              default = null;
                                              description = ''
                                                dataSource field can be used to specify either:
                                                * An existing VolumeSnapshot object (snapshot.storage.k8s.io/VolumeSnapshot)
                                                * An existing PVC (PersistentVolumeClaim)
                                                If the provisioner or an external controller can support the specified data source,
                                                it will create a new volume based on the contents of the specified data source.
                                                When the AnyVolumeDataSource feature gate is enabled, dataSource contents will be copied to dataSourceRef,
                                                and dataSourceRef contents will be copied to dataSource when dataSourceRef.namespace is not specified.
                                                If the namespace is specified, then dataSourceRef will not be copied to dataSource.
                                              '';
                                            };
                                            dataSourceRef = mkOption {
                                              type = (
                                                types.nullOr (mkTypedSubmodule {
                                                  options = {
                                                    apiGroup = mkOption {
                                                      type = (types.nullOr types.str);
                                                      default = null;
                                                      description = ''
                                                        APIGroup is the group for the resource being referenced.
                                                        If APIGroup is not specified, the specified Kind must be in the core API group.
                                                        For any other third-party types, APIGroup is required.
                                                      '';
                                                    };
                                                    kind = mkOption {
                                                      type = types.str;
                                                      description = "Kind is the type of resource being referenced";
                                                    };
                                                    name = mkOption {
                                                      type = types.str;
                                                      description = "Name is the name of resource being referenced";
                                                    };
                                                    namespace = mkOption {
                                                      type = (types.nullOr types.str);
                                                      default = null;
                                                      description = ''
                                                        Namespace is the namespace of resource being referenced
                                                        Note that when a namespace is specified, a gateway.networking.k8s.io/ReferenceGrant object is required in the referent namespace to allow that namespace's owner to accept the reference. See the ReferenceGrant documentation for details.
                                                        (Alpha) This field requires the CrossNamespaceVolumeDataSource feature gate to be enabled.
                                                      '';
                                                    };
                                                  };
                                                  freeformType = types.attrs;
                                                })
                                              );
                                              default = null;
                                              description = ''
                                                dataSourceRef specifies the object from which to populate the volume with data, if a non-empty
                                                volume is desired. This may be any object from a non-empty API group (non
                                                core object) or a PersistentVolumeClaim object.
                                                When this field is specified, volume binding will only succeed if the type of
                                                the specified object matches some installed volume populator or dynamic
                                                provisioner.
                                                This field will replace the functionality of the dataSource field and as such
                                                if both fields are non-empty, they must have the same value. For backwards
                                                compatibility, when namespace isn't specified in dataSourceRef,
                                                both fields (dataSource and dataSourceRef) will be set to the same
                                                value automatically if one of them is empty and the other is non-empty.
                                                When namespace is specified in dataSourceRef,
                                                dataSource isn't set to the same value and must be empty.
                                                There are three important differences between dataSource and dataSourceRef:
                                                * While dataSource only allows two specific types of objects, dataSourceRef
                                                  allows any non-core object, as well as PersistentVolumeClaim objects.
                                                * While dataSource ignores disallowed values (dropping them), dataSourceRef
                                                  preserves all values, and generates an error if a disallowed value is
                                                  specified.
                                                * While dataSource only allows local objects, dataSourceRef allows objects
                                                  in any namespaces.
                                                (Beta) Using this field requires the AnyVolumeDataSource feature gate to be enabled.
                                                (Alpha) Using the namespace field of dataSourceRef requires the CrossNamespaceVolumeDataSource feature gate to be enabled.
                                              '';
                                            };
                                            resources = mkOption {
                                              type = (
                                                types.nullOr (mkTypedSubmodule {
                                                  options = {
                                                    limits = mkOption {
                                                      type = (types.nullOr (types.attrsOf types.anything));
                                                      default = null;
                                                      description = ''
                                                        Limits describes the maximum amount of compute resources allowed.
                                                        More info: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
                                                      '';
                                                    };
                                                    requests = mkOption {
                                                      type = (types.nullOr (types.attrsOf types.anything));
                                                      default = null;
                                                      description = ''
                                                        Requests describes the minimum amount of compute resources required.
                                                        If Requests is omitted for a container, it defaults to Limits if that is explicitly specified,
                                                        otherwise to an implementation-defined value. Requests cannot exceed Limits.
                                                        More info: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
                                                      '';
                                                    };
                                                  };
                                                  freeformType = types.attrs;
                                                })
                                              );
                                              default = null;
                                              description = ''
                                                resources represents the minimum resources the volume should have.
                                                Users are allowed to specify resource requirements
                                                that are lower than previous value but must still be higher than capacity recorded in the
                                                status field of the claim.
                                                More info: https://kubernetes.io/docs/concepts/storage/persistent-volumes#resources
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
                                              description = "selector is a label query over volumes to consider for binding.";
                                            };
                                            storageClassName = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = ''
                                                storageClassName is the name of the StorageClass required by the claim.
                                                More info: https://kubernetes.io/docs/concepts/storage/persistent-volumes#class-1
                                              '';
                                            };
                                            volumeAttributesClassName = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = ''
                                                volumeAttributesClassName may be used to set the VolumeAttributesClass used by this claim.
                                                If specified, the CSI driver will create or update the volume with the attributes defined
                                                in the corresponding VolumeAttributesClass. This has a different purpose than storageClassName,
                                                it can be changed after the claim is created. An empty string or nil value indicates that no
                                                VolumeAttributesClass will be applied to the claim. If the claim enters an Infeasible error state,
                                                this field can be reset to its previous value (including nil) to cancel the modification.
                                                If the resource referred to by volumeAttributesClass does not exist, this PersistentVolumeClaim will be
                                                set to a Pending state, as reflected by the modifyVolumeStatus field, until such as a resource
                                                exists.
                                                More info: https://kubernetes.io/docs/concepts/storage/volume-attributes-classes/
                                              '';
                                            };
                                            volumeMode = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = ''
                                                volumeMode defines what type of volume is required by the claim.
                                                Value of Filesystem is implied when not included in claim spec.
                                              '';
                                            };
                                            volumeName = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = "volumeName is the binding reference to the PersistentVolume backing this claim.";
                                            };
                                          };
                                          freeformType = types.attrs;
                                        }
                                      );
                                      description = ''
                                        The specification for the PersistentVolumeClaim. The entire content is
                                        copied unchanged into the PVC that gets created from this
                                        template. The same fields as in a PersistentVolumeClaim
                                        are also valid here.
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                Will be used to create a stand-alone PVC to provision the volume.
                                The pod in which this EphemeralVolumeSource is embedded will be the
                                owner of the PVC, i.e. the PVC will be deleted together with the
                                pod.  The name of the PVC will be `<pod name>-<volume name>` where
                                `<volume name>` is the name from the `PodSpec.Volumes` array
                                entry. Pod validation will reject the pod if the concatenated name
                                is not valid for a PVC (for example, too long).

                                An existing PVC with that name that is not owned by the pod
                                will *not* be used for the pod to avoid using an unrelated
                                volume by mistake. Starting the pod is then blocked until
                                the unrelated PVC is removed. If such a pre-created PVC is
                                meant to be used by the pod, the PVC has to updated with an
                                owner reference to the pod once the pod exists. Normally
                                this should not be necessary, but it may be useful when
                                manually reconstructing a broken cluster.

                                This field is read-only and no changes will be made by Kubernetes
                                to the PVC after it has been created.

                                Required, must not be nil.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        ephemeral represents a volume that is handled by a cluster storage driver.
                        The volume's lifecycle is tied to the pod that defines it - it will be created before the pod starts,
                        and deleted when the pod is removed.

                        Use this if:
                        a) the volume is only needed while the pod runs,
                        b) features of normal volumes like restoring from snapshot or capacity
                           tracking are needed,
                        c) the storage driver is specified through a storage class, and
                        d) the storage driver supports dynamic volume provisioning through
                           a PersistentVolumeClaim (see EphemeralVolumeSource for more
                           information on the connection between this volume type
                           and PersistentVolumeClaim).

                        Use PersistentVolumeClaim or one of the vendor-specific
                        APIs for volumes that persist for longer than the lifecycle
                        of an individual pod.

                        Use CSI for light-weight local ephemeral volumes if the CSI driver is meant to
                        be used that way - see the documentation of the driver for
                        more information.

                        A pod can use both types of ephemeral volumes and
                        persistent volumes at the same time.
                      '';
                    };
                    fc = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            lun = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = "lun is Optional: FC target lun number";
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly is Optional: Defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            targetWWNs = mkOption {
                              type = (types.nullOr (types.listOf types.str));
                              default = null;
                              description = "targetWWNs is Optional: FC target worldwide names (WWNs)";
                            };
                            wwids = mkOption {
                              type = (types.nullOr (types.listOf types.str));
                              default = null;
                              description = ''
                                wwids Optional: FC volume world wide identifiers (wwids)
                                Either wwids or combination of targetWWNs and lun must be set, but not both simultaneously.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "fc represents a Fibre Channel resource that is attached to a kubelet's host machine and then exposed to the pod.";
                    };
                    flexVolume = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            driver = mkOption {
                              type = types.str;
                              description = "driver is the name of the driver to use for this volume.";
                            };
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". The default filesystem depends on FlexVolume script.
                              '';
                            };
                            options = mkOption {
                              type = (types.nullOr (types.attrsOf types.str));
                              default = null;
                              description = "options is Optional: this field holds extra command options if any.";
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly is Optional: defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                secretRef is Optional: secretRef is reference to the secret object containing
                                sensitive information to pass to the plugin scripts. This may be
                                empty if no secret object is specified. If the secret object
                                contains more than one secret, all secrets are passed to the plugin
                                scripts.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        flexVolume represents a generic volume resource that is
                        provisioned/attached using an exec based plugin.
                        Deprecated: FlexVolume is deprecated. Consider using a CSIDriver instead.
                      '';
                    };
                    flocker = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            datasetName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                datasetName is Name of the dataset stored as metadata -> name on the dataset for Flocker
                                should be considered as deprecated
                              '';
                            };
                            datasetUUID = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "datasetUUID is the UUID of the dataset. This is unique identifier of a Flocker dataset";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        flocker represents a Flocker volume attached to a kubelet's host machine. This depends on the Flocker control service being running.
                        Deprecated: Flocker is deprecated and the in-tree flocker type is no longer supported.
                      '';
                    };
                    gcePersistentDisk = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is filesystem type of the volume that you want to mount.
                                Tip: Ensure that the filesystem type is supported by the host operating system.
                                Examples: "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#gcepersistentdisk
                              '';
                            };
                            partition = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                partition is the partition in the volume that you want to mount.
                                If omitted, the default is to mount by volume name.
                                Examples: For volume /dev/sda1, you specify the partition as "1".
                                Similarly, the volume partition for /dev/sda is "0" (or you can leave the property empty).
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#gcepersistentdisk
                              '';
                            };
                            pdName = mkOption {
                              type = types.str;
                              description = ''
                                pdName is unique name of the PD resource in GCE. Used to identify the disk in GCE.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#gcepersistentdisk
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the ReadOnly setting in VolumeMounts.
                                Defaults to false.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#gcepersistentdisk
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        gcePersistentDisk represents a GCE Disk resource that is attached to a
                        kubelet's host machine and then exposed to the pod.
                        Deprecated: GCEPersistentDisk is deprecated. All operations for the in-tree
                        gcePersistentDisk type are redirected to the pd.csi.storage.gke.io CSI driver.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#gcepersistentdisk
                      '';
                    };
                    gitRepo = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            directory = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                directory is the target directory name.
                                Must not contain or start with '..'.  If '.' is supplied, the volume directory will be the
                                git repository.  Otherwise, if specified, the volume will contain the git repository in
                                the subdirectory with the given name.
                              '';
                            };
                            repository = mkOption {
                              type = types.str;
                              description = "repository is the URL";
                            };
                            revision = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "revision is the commit hash for the specified revision.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        gitRepo represents a git repository at a particular revision.
                        Deprecated: GitRepo is deprecated. To provision a container with a git repo, mount an
                        EmptyDir into an InitContainer that clones the repo using git, then mount the EmptyDir
                        into the Pod's container.
                      '';
                    };
                    glusterfs = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            endpoints = mkOption {
                              type = types.str;
                              description = "endpoints is the endpoint name that details Glusterfs topology.";
                            };
                            path = mkOption {
                              type = types.str;
                              description = ''
                                path is the Glusterfs volume path.
                                More info: https://examples.k8s.io/volumes/glusterfs/README.md#create-a-pod
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the Glusterfs volume to be mounted with read-only permissions.
                                Defaults to false.
                                More info: https://examples.k8s.io/volumes/glusterfs/README.md#create-a-pod
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        glusterfs represents a Glusterfs mount on the host that shares a pod's lifetime.
                        Deprecated: Glusterfs is deprecated and the in-tree glusterfs type is no longer supported.
                      '';
                    };
                    hostPath = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            path = mkOption {
                              type = types.str;
                              description = ''
                                path of the directory on the host.
                                If the path is a symlink, it will follow the link to the real path.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#hostpath
                              '';
                            };
                            type = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                type for HostPath Volume
                                Defaults to ""
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#hostpath
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        hostPath represents a pre-existing file or directory on the host
                        machine that is directly exposed to the container. This is generally
                        used for system agents or other privileged things that are allowed
                        to see the host machine. Most containers will NOT need this.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#hostpath
                      '';
                    };
                    image = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            pullPolicy = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Policy for pulling OCI objects. Possible values are:
                                Always: the kubelet always attempts to pull the reference. Container creation will fail If the pull fails.
                                Never: the kubelet never pulls the reference and only uses a local image or artifact. Container creation will fail if the reference isn't present.
                                IfNotPresent: the kubelet pulls if the reference isn't already present on disk. Container creation will fail if the reference isn't present and the pull fails.
                                Defaults to Always if :latest tag is specified, or IfNotPresent otherwise.
                              '';
                            };
                            reference = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Required: Image or artifact reference to be used.
                                Behaves in the same way as pod.spec.containers[*].image.
                                Pull secrets will be assembled in the same way as for the container image by looking up node credentials, SA image pull secrets, and pod spec image pull secrets.
                                More info: https://kubernetes.io/docs/concepts/containers/images
                                This field is optional to allow higher level config management to default or override
                                container images in workload controllers like Deployments and StatefulSets.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        image represents an OCI object (a container image or artifact) pulled and mounted on the kubelet's host machine.
                        The volume is resolved at pod startup depending on which PullPolicy value is provided:

                        - Always: the kubelet always attempts to pull the reference. Container creation will fail If the pull fails.
                        - Never: the kubelet never pulls the reference and only uses a local image or artifact. Container creation will fail if the reference isn't present.
                        - IfNotPresent: the kubelet pulls if the reference isn't already present on disk. Container creation will fail if the reference isn't present and the pull fails.

                        The volume gets re-resolved if the pod gets deleted and recreated, which means that new remote content will become available on pod recreation.
                        A failure to resolve or pull the image during pod startup will block containers from starting and may add significant latency. Failures will be retried using normal volume backoff and will be reported on the pod reason and message.
                        The types of objects that may be mounted by this volume are defined by the container runtime implementation on a host machine and at minimum must include all valid types supported by the container image field.
                        The OCI object gets mounted in a single directory (spec.containers[*].volumeMounts.mountPath) by merging the manifest layers in the same way as for container images.
                        The volume will be mounted read-only (ro).
                        Sub path mounts for containers are not supported (spec.containers[*].volumeMounts.subpath) before 1.33.
                        The field spec.securityContext.fsGroupChangePolicy has no effect on this volume type.
                      '';
                    };
                    iscsi = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            chapAuthDiscovery = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = "chapAuthDiscovery defines whether support iSCSI Discovery CHAP authentication";
                            };
                            chapAuthSession = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = "chapAuthSession defines whether support iSCSI Session CHAP authentication";
                            };
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type of the volume that you want to mount.
                                Tip: Ensure that the filesystem type is supported by the host operating system.
                                Examples: "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#iscsi
                              '';
                            };
                            initiatorName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                initiatorName is the custom iSCSI Initiator Name.
                                If initiatorName is specified with iscsiInterface simultaneously, new iSCSI interface
                                <target portal>:<volume name> will be created for the connection.
                              '';
                            };
                            iqn = mkOption {
                              type = types.str;
                              description = "iqn is the target iSCSI Qualified Name.";
                            };
                            iscsiInterface = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                iscsiInterface is the interface Name that uses an iSCSI transport.
                                Defaults to 'default' (tcp).
                              '';
                            };
                            lun = mkOption {
                              type = types.int;
                              description = "lun represents iSCSI Target Lun number.";
                            };
                            portals = mkOption {
                              type = (types.nullOr (types.listOf types.str));
                              default = null;
                              description = ''
                                portals is the iSCSI Target Portal List. The portal is either an IP or ip_addr:port if the port
                                is other than default (typically TCP ports 860 and 3260).
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the ReadOnly setting in VolumeMounts.
                                Defaults to false.
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = "secretRef is the CHAP Secret for iSCSI target and initiator authentication";
                            };
                            targetPortal = mkOption {
                              type = types.str;
                              description = ''
                                targetPortal is iSCSI Target Portal. The Portal is either an IP or ip_addr:port if the port
                                is other than default (typically TCP ports 860 and 3260).
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        iscsi represents an ISCSI Disk resource that is attached to a
                        kubelet's host machine and then exposed to the pod.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes/#iscsi
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = ''
                        name of the volume.
                        Must be a DNS_LABEL and unique within the pod.
                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                      '';
                    };
                    nfs = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            path = mkOption {
                              type = types.str;
                              description = ''
                                path that is exported by the NFS server.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#nfs
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the NFS export to be mounted with read-only permissions.
                                Defaults to false.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#nfs
                              '';
                            };
                            server = mkOption {
                              type = types.str;
                              description = ''
                                server is the hostname or IP address of the NFS server.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#nfs
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        nfs represents an NFS mount on the host that shares a pod's lifetime
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#nfs
                      '';
                    };
                    persistentVolumeClaim = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            claimName = mkOption {
                              type = types.str;
                              description = ''
                                claimName is the name of a PersistentVolumeClaim in the same namespace as the pod using this volume.
                                More info: https://kubernetes.io/docs/concepts/storage/persistent-volumes#persistentvolumeclaims
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly Will force the ReadOnly setting in VolumeMounts.
                                Default false.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        persistentVolumeClaimVolumeSource represents a reference to a
                        PersistentVolumeClaim in the same namespace.
                        More info: https://kubernetes.io/docs/concepts/storage/persistent-volumes#persistentvolumeclaims
                      '';
                    };
                    photonPersistentDisk = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            pdID = mkOption {
                              type = types.str;
                              description = "pdID is the ID that identifies Photon Controller persistent disk";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        photonPersistentDisk represents a PhotonController persistent disk attached and mounted on kubelets host machine.
                        Deprecated: PhotonPersistentDisk is deprecated and the in-tree photonPersistentDisk type is no longer supported.
                      '';
                    };
                    portworxVolume = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fSType represents the filesystem type to mount
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            volumeID = mkOption {
                              type = types.str;
                              description = "volumeID uniquely identifies a Portworx volume";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        portworxVolume represents a portworx volume attached and mounted on kubelets host machine.
                        Deprecated: PortworxVolume is deprecated. All operations for the in-tree portworxVolume type
                        are redirected to the pxd.portworx.com CSI driver.
                      '';
                    };
                    projected = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            defaultMode = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                defaultMode are the mode bits used to set permissions on created files by default.
                                Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                Directories within the path are not affected by this setting.
                                This might be in conflict with other options that affect the file
                                mode, like fsGroup, and the result can be other mode bits set.
                              '';
                            };
                            sources = mkOption {
                              type = (
                                types.nullOr (
                                  types.listOf (mkTypedSubmodule {
                                    options = {
                                      clusterTrustBundle = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              labelSelector = mkOption {
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
                                                  Select all ClusterTrustBundles that match this label selector.  Only has
                                                  effect if signerName is set.  Mutually-exclusive with name.  If unset,
                                                  interpreted as "match nothing".  If set but empty, interpreted as "match
                                                  everything".
                                                '';
                                              };
                                              name = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Select a single ClusterTrustBundle by object name.  Mutually-exclusive
                                                  with signerName and labelSelector.
                                                '';
                                              };
                                              optional = mkOption {
                                                type = (types.nullOr types.bool);
                                                default = null;
                                                description = ''
                                                  If true, don't block pod startup if the referenced ClusterTrustBundle(s)
                                                  aren't available.  If using name, then the named ClusterTrustBundle is
                                                  allowed not to exist.  If using signerName, then the combination of
                                                  signerName and labelSelector is allowed to match zero
                                                  ClusterTrustBundles.
                                                '';
                                              };
                                              path = mkOption {
                                                type = types.str;
                                                description = "Relative path from the volume root to write the bundle.";
                                              };
                                              signerName = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Select all ClusterTrustBundles that match this signer name.
                                                  Mutually-exclusive with name.  The contents of all selected
                                                  ClusterTrustBundles will be unified and deduplicated.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = ''
                                          ClusterTrustBundle allows a pod to access the `.spec.trustBundle` field
                                          of ClusterTrustBundle objects in an auto-updating file.

                                          Alpha, gated by the ClusterTrustBundleProjection feature gate.

                                          ClusterTrustBundle objects can either be selected by name, or by the
                                          combination of signer name and a label selector.

                                          Kubelet performs aggressive normalization of the PEM contents written
                                          into the pod filesystem.  Esoteric PEM features such as inter-block
                                          comments and block headers are stripped.  Certificates are deduplicated.
                                          The ordering of certificates within the file is arbitrary, and Kubelet
                                          may change the order over time.
                                        '';
                                      };
                                      configMap = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              items = mkOption {
                                                type = (
                                                  types.nullOr (
                                                    types.listOf (mkTypedSubmodule {
                                                      options = {
                                                        key = mkOption {
                                                          type = types.str;
                                                          description = "key is the key to project.";
                                                        };
                                                        mode = mkOption {
                                                          type = (types.nullOr types.int);
                                                          default = null;
                                                          description = ''
                                                            mode is Optional: mode bits used to set permissions on this file.
                                                            Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                                            YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                                            If not specified, the volume defaultMode will be used.
                                                            This might be in conflict with other options that affect the file
                                                            mode, like fsGroup, and the result can be other mode bits set.
                                                          '';
                                                        };
                                                        path = mkOption {
                                                          type = types.str;
                                                          description = ''
                                                            path is the relative path of the file to map the key to.
                                                            May not be an absolute path.
                                                            May not contain the path element '..'.
                                                            May not start with the string '..'.
                                                          '';
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    })
                                                  )
                                                );
                                                default = null;
                                                description = ''
                                                  items if unspecified, each key-value pair in the Data field of the referenced
                                                  ConfigMap will be projected into the volume as a file whose name is the
                                                  key and content is the value. If specified, the listed keys will be
                                                  projected into the specified paths, and unlisted keys will not be
                                                  present. If a key is specified which is not present in the ConfigMap,
                                                  the volume setup will error unless it is marked optional. Paths must be
                                                  relative and may not contain the '..' path or start with '..'.
                                                '';
                                              };
                                              name = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Name of the referent.
                                                  This field is effectively required, but due to backwards compatibility is
                                                  allowed to be empty. Instances of this type with an empty value here are
                                                  almost certainly wrong.
                                                  More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                                '';
                                              };
                                              optional = mkOption {
                                                type = (types.nullOr types.bool);
                                                default = null;
                                                description = "optional specify whether the ConfigMap or its keys must be defined";
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = "configMap information about the configMap data to project";
                                      };
                                      downwardAPI = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              items = mkOption {
                                                type = (
                                                  types.nullOr (
                                                    types.listOf (mkTypedSubmodule {
                                                      options = {
                                                        fieldRef = mkOption {
                                                          type = (
                                                            types.nullOr (mkTypedSubmodule {
                                                              options = {
                                                                apiVersion = mkOption {
                                                                  type = (types.nullOr types.str);
                                                                  default = null;
                                                                  description = "Version of the schema the FieldPath is written in terms of, defaults to \"v1\".";
                                                                };
                                                                fieldPath = mkOption {
                                                                  type = types.str;
                                                                  description = "Path of the field to select in the specified API version.";
                                                                };
                                                              };
                                                              freeformType = types.attrs;
                                                            })
                                                          );
                                                          default = null;
                                                          description = "Required: Selects a field of the pod: only annotations, labels, name, namespace and uid are supported.";
                                                        };
                                                        mode = mkOption {
                                                          type = (types.nullOr types.int);
                                                          default = null;
                                                          description = ''
                                                            Optional: mode bits used to set permissions on this file, must be an octal value
                                                            between 0000 and 0777 or a decimal value between 0 and 511.
                                                            YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                                            If not specified, the volume defaultMode will be used.
                                                            This might be in conflict with other options that affect the file
                                                            mode, like fsGroup, and the result can be other mode bits set.
                                                          '';
                                                        };
                                                        path = mkOption {
                                                          type = types.str;
                                                          description = "Required: Path is  the relative path name of the file to be created. Must not be absolute or contain the '..' path. Must be utf-8 encoded. The first item of the relative path must not start with '..'";
                                                        };
                                                        resourceFieldRef = mkOption {
                                                          type = (
                                                            types.nullOr (mkTypedSubmodule {
                                                              options = {
                                                                containerName = mkOption {
                                                                  type = (types.nullOr types.str);
                                                                  default = null;
                                                                  description = "Container name: required for volumes, optional for env vars";
                                                                };
                                                                divisor = mkOption {
                                                                  type = (types.nullOr types.anything);
                                                                  default = null;
                                                                  description = "Specifies the output format of the exposed resources, defaults to \"1\"";
                                                                };
                                                                resource = mkOption {
                                                                  type = types.str;
                                                                  description = "Required: resource to select";
                                                                };
                                                              };
                                                              freeformType = types.attrs;
                                                            })
                                                          );
                                                          default = null;
                                                          description = ''
                                                            Selects a resource of the container: only resources limits and requests
                                                            (limits.cpu, limits.memory, requests.cpu and requests.memory) are currently supported.
                                                          '';
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    })
                                                  )
                                                );
                                                default = null;
                                                description = "Items is a list of DownwardAPIVolume file";
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = "downwardAPI information about the downwardAPI data to project";
                                      };
                                      podCertificate = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              certificateChainPath = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Write the certificate chain at this path in the projected volume.

                                                  Most applications should use credentialBundlePath.  When using keyPath
                                                  and certificateChainPath, your application needs to check that the key
                                                  and leaf certificate are consistent, because it is possible to read the
                                                  files mid-rotation.
                                                '';
                                              };
                                              credentialBundlePath = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Write the credential bundle at this path in the projected volume.

                                                  The credential bundle is a single file that contains multiple PEM blocks.
                                                  The first PEM block is a PRIVATE KEY block, containing a PKCS#8 private
                                                  key.

                                                  The remaining blocks are CERTIFICATE blocks, containing the issued
                                                  certificate chain from the signer (leaf and any intermediates).

                                                  Using credentialBundlePath lets your Pod's application code make a single
                                                  atomic read that retrieves a consistent key and certificate chain.  If you
                                                  project them to separate files, your application code will need to
                                                  additionally check that the leaf certificate was issued to the key.
                                                '';
                                              };
                                              keyPath = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Write the key at this path in the projected volume.

                                                  Most applications should use credentialBundlePath.  When using keyPath
                                                  and certificateChainPath, your application needs to check that the key
                                                  and leaf certificate are consistent, because it is possible to read the
                                                  files mid-rotation.
                                                '';
                                              };
                                              keyType = mkOption {
                                                type = types.str;
                                                description = ''
                                                  The type of keypair Kubelet will generate for the pod.

                                                  Valid values are "RSA3072", "RSA4096", "ECDSAP256", "ECDSAP384",
                                                  "ECDSAP521", and "ED25519".
                                                '';
                                              };
                                              maxExpirationSeconds = mkOption {
                                                type = (types.nullOr types.int);
                                                default = null;
                                                description = ''
                                                  maxExpirationSeconds is the maximum lifetime permitted for the
                                                  certificate.

                                                  Kubelet copies this value verbatim into the PodCertificateRequests it
                                                  generates for this projection.

                                                  If omitted, kube-apiserver will set it to 86400(24 hours). kube-apiserver
                                                  will reject values shorter than 3600 (1 hour).  The maximum allowable
                                                  value is 7862400 (91 days).

                                                  The signer implementation is then free to issue a certificate with any
                                                  lifetime *shorter* than MaxExpirationSeconds, but no shorter than 3600
                                                  seconds (1 hour).  This constraint is enforced by kube-apiserver.
                                                  `kubernetes.io` signers will never issue certificates with a lifetime
                                                  longer than 24 hours.
                                                '';
                                              };
                                              signerName = mkOption {
                                                type = types.str;
                                                description = "Kubelet's generated CSRs will be addressed to this signer.";
                                              };
                                              userAnnotations = mkOption {
                                                type = (types.nullOr (types.attrsOf types.str));
                                                default = null;
                                                description = ''
                                                  userAnnotations allow pod authors to pass additional information to
                                                  the signer implementation.  Kubernetes does not restrict or validate this
                                                  metadata in any way.

                                                  These values are copied verbatim into the `spec.unverifiedUserAnnotations` field of
                                                  the PodCertificateRequest objects that Kubelet creates.

                                                  Entries are subject to the same validation as object metadata annotations,
                                                  with the addition that all keys must be domain-prefixed. No restrictions
                                                  are placed on values, except an overall size limitation on the entire field.

                                                  Signers should document the keys and values they support. Signers should
                                                  deny requests that contain keys they do not recognize.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = ''
                                          Projects an auto-rotating credential bundle (private key and certificate
                                          chain) that the pod can use either as a TLS client or server.

                                          Kubelet generates a private key and uses it to send a
                                          PodCertificateRequest to the named signer.  Once the signer approves the
                                          request and issues a certificate chain, Kubelet writes the key and
                                          certificate chain to the pod filesystem.  The pod does not start until
                                          certificates have been issued for each podCertificate projected volume
                                          source in its spec.

                                          Kubelet will begin trying to rotate the certificate at the time indicated
                                          by the signer using the PodCertificateRequest.Status.BeginRefreshAt
                                          timestamp.

                                          Kubelet can write a single file, indicated by the credentialBundlePath
                                          field, or separate files, indicated by the keyPath and
                                          certificateChainPath fields.

                                          The credential bundle is a single file in PEM format.  The first PEM
                                          entry is the private key (in PKCS#8 format), and the remaining PEM
                                          entries are the certificate chain issued by the signer (typically,
                                          signers will return their certificate chain in leaf-to-root order).

                                          Prefer using the credential bundle format, since your application code
                                          can read it atomically.  If you use keyPath and certificateChainPath,
                                          your application must make two separate file reads. If these coincide
                                          with a certificate rotation, it is possible that the private key and leaf
                                          certificate you read may not correspond to each other.  Your application
                                          will need to check for this condition, and re-read until they are
                                          consistent.

                                          The named signer controls chooses the format of the certificate it
                                          issues; consult the signer implementation's documentation to learn how to
                                          use the certificates it issues.
                                        '';
                                      };
                                      secret = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              items = mkOption {
                                                type = (
                                                  types.nullOr (
                                                    types.listOf (mkTypedSubmodule {
                                                      options = {
                                                        key = mkOption {
                                                          type = types.str;
                                                          description = "key is the key to project.";
                                                        };
                                                        mode = mkOption {
                                                          type = (types.nullOr types.int);
                                                          default = null;
                                                          description = ''
                                                            mode is Optional: mode bits used to set permissions on this file.
                                                            Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                                            YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                                            If not specified, the volume defaultMode will be used.
                                                            This might be in conflict with other options that affect the file
                                                            mode, like fsGroup, and the result can be other mode bits set.
                                                          '';
                                                        };
                                                        path = mkOption {
                                                          type = types.str;
                                                          description = ''
                                                            path is the relative path of the file to map the key to.
                                                            May not be an absolute path.
                                                            May not contain the path element '..'.
                                                            May not start with the string '..'.
                                                          '';
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    })
                                                  )
                                                );
                                                default = null;
                                                description = ''
                                                  items if unspecified, each key-value pair in the Data field of the referenced
                                                  Secret will be projected into the volume as a file whose name is the
                                                  key and content is the value. If specified, the listed keys will be
                                                  projected into the specified paths, and unlisted keys will not be
                                                  present. If a key is specified which is not present in the Secret,
                                                  the volume setup will error unless it is marked optional. Paths must be
                                                  relative and may not contain the '..' path or start with '..'.
                                                '';
                                              };
                                              name = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Name of the referent.
                                                  This field is effectively required, but due to backwards compatibility is
                                                  allowed to be empty. Instances of this type with an empty value here are
                                                  almost certainly wrong.
                                                  More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                                '';
                                              };
                                              optional = mkOption {
                                                type = (types.nullOr types.bool);
                                                default = null;
                                                description = "optional field specify whether the Secret or its key must be defined";
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = "secret information about the secret data to project";
                                      };
                                      serviceAccountToken = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              audience = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  audience is the intended audience of the token. A recipient of a token
                                                  must identify itself with an identifier specified in the audience of the
                                                  token, and otherwise should reject the token. The audience defaults to the
                                                  identifier of the apiserver.
                                                '';
                                              };
                                              expirationSeconds = mkOption {
                                                type = (types.nullOr types.int);
                                                default = null;
                                                description = ''
                                                  expirationSeconds is the requested duration of validity of the service
                                                  account token. As the token approaches expiration, the kubelet volume
                                                  plugin will proactively rotate the service account token. The kubelet will
                                                  start trying to rotate the token if the token is older than 80 percent of
                                                  its time to live or if the token is older than 24 hours.Defaults to 1 hour
                                                  and must be at least 10 minutes.
                                                '';
                                              };
                                              path = mkOption {
                                                type = types.str;
                                                description = ''
                                                  path is the path relative to the mount point of the file to project the
                                                  token into.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = "serviceAccountToken is information about the serviceAccountToken data to project";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                )
                              );
                              default = null;
                              description = ''
                                sources is the list of volume projections. Each entry in this list
                                handles one source.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "projected items for all in one resources secrets, configmaps, and downward API";
                    };
                    quobyte = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            group = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                group to map volume access to
                                Default is no group
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the Quobyte volume to be mounted with read-only permissions.
                                Defaults to false.
                              '';
                            };
                            registry = mkOption {
                              type = types.str;
                              description = ''
                                registry represents a single or multiple Quobyte Registry services
                                specified as a string as host:port pair (multiple entries are separated with commas)
                                which acts as the central registry for volumes
                              '';
                            };
                            tenant = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                tenant owning the given Quobyte volume in the Backend
                                Used with dynamically provisioned Quobyte volumes, value is set by the plugin
                              '';
                            };
                            user = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                user to map volume access to
                                Defaults to serivceaccount user
                              '';
                            };
                            volume = mkOption {
                              type = types.str;
                              description = "volume is a string that references an already created Quobyte volume by name.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        quobyte represents a Quobyte mount on the host that shares a pod's lifetime.
                        Deprecated: Quobyte is deprecated and the in-tree quobyte type is no longer supported.
                      '';
                    };
                    rbd = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type of the volume that you want to mount.
                                Tip: Ensure that the filesystem type is supported by the host operating system.
                                Examples: "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#rbd
                              '';
                            };
                            image = mkOption {
                              type = types.str;
                              description = ''
                                image is the rados image name.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            keyring = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                keyring is the path to key ring for RBDUser.
                                Default is /etc/ceph/keyring.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            monitors = mkOption {
                              type = (types.listOf types.str);
                              description = ''
                                monitors is a collection of Ceph monitors.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            pool = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                pool is the rados pool name.
                                Default is rbd.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly here will force the ReadOnly setting in VolumeMounts.
                                Defaults to false.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                secretRef is name of the authentication secret for RBDUser. If provided
                                overrides keyring.
                                Default is nil.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                            user = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                user is the rados user name.
                                Default is admin.
                                More info: https://examples.k8s.io/volumes/rbd/README.md#how-to-use-it
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        rbd represents a Rados Block Device mount on the host that shares a pod's lifetime.
                        Deprecated: RBD is deprecated and the in-tree rbd type is no longer supported.
                      '';
                    };
                    scaleIO = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs".
                                Default is "xfs".
                              '';
                            };
                            gateway = mkOption {
                              type = types.str;
                              description = "gateway is the host address of the ScaleIO API Gateway.";
                            };
                            protectionDomain = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "protectionDomain is the name of the ScaleIO Protection Domain for the configured storage.";
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly Defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                }
                              );
                              description = ''
                                secretRef references to the secret for ScaleIO user and other
                                sensitive information. If this is not provided, Login operation will fail.
                              '';
                            };
                            sslEnabled = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = "sslEnabled Flag enable/disable SSL communication with Gateway, default false";
                            };
                            storageMode = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                storageMode indicates whether the storage for a volume should be ThickProvisioned or ThinProvisioned.
                                Default is ThinProvisioned.
                              '';
                            };
                            storagePool = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "storagePool is the ScaleIO Storage Pool associated with the protection domain.";
                            };
                            system = mkOption {
                              type = types.str;
                              description = "system is the name of the storage system as configured in ScaleIO.";
                            };
                            volumeName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                volumeName is the name of a volume already created in the ScaleIO system
                                that is associated with this volume source.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        scaleIO represents a ScaleIO persistent volume attached and mounted on Kubernetes nodes.
                        Deprecated: ScaleIO is deprecated and the in-tree scaleIO type is no longer supported.
                      '';
                    };
                    secret = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            defaultMode = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                defaultMode is Optional: mode bits used to set permissions on created files by default.
                                Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                YAML accepts both octal and decimal values, JSON requires decimal values
                                for mode bits. Defaults to 0644.
                                Directories within the path are not affected by this setting.
                                This might be in conflict with other options that affect the file
                                mode, like fsGroup, and the result can be other mode bits set.
                              '';
                            };
                            items = mkOption {
                              type = (
                                types.nullOr (
                                  types.listOf (mkTypedSubmodule {
                                    options = {
                                      key = mkOption {
                                        type = types.str;
                                        description = "key is the key to project.";
                                      };
                                      mode = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          mode is Optional: mode bits used to set permissions on this file.
                                          Must be an octal value between 0000 and 0777 or a decimal value between 0 and 511.
                                          YAML accepts both octal and decimal values, JSON requires decimal values for mode bits.
                                          If not specified, the volume defaultMode will be used.
                                          This might be in conflict with other options that affect the file
                                          mode, like fsGroup, and the result can be other mode bits set.
                                        '';
                                      };
                                      path = mkOption {
                                        type = types.str;
                                        description = ''
                                          path is the relative path of the file to map the key to.
                                          May not be an absolute path.
                                          May not contain the path element '..'.
                                          May not start with the string '..'.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                )
                              );
                              default = null;
                              description = ''
                                items If unspecified, each key-value pair in the Data field of the referenced
                                Secret will be projected into the volume as a file whose name is the
                                key and content is the value. If specified, the listed keys will be
                                projected into the specified paths, and unlisted keys will not be
                                present. If a key is specified which is not present in the Secret,
                                the volume setup will error unless it is marked optional. Paths must be
                                relative and may not contain the '..' path or start with '..'.
                              '';
                            };
                            optional = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = "optional field specify whether the Secret or its keys must be defined";
                            };
                            secretName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                secretName is the name of the secret in the pod's namespace to use.
                                More info: https://kubernetes.io/docs/concepts/storage/volumes#secret
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        secret represents a secret that should populate this volume.
                        More info: https://kubernetes.io/docs/concepts/storage/volumes#secret
                      '';
                    };
                    storageos = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is the filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            readOnly = mkOption {
                              type = (types.nullOr types.bool);
                              default = null;
                              description = ''
                                readOnly defaults to false (read/write). ReadOnly here will force
                                the ReadOnly setting in VolumeMounts.
                              '';
                            };
                            secretRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name of the referent.
                                        This field is effectively required, but due to backwards compatibility is
                                        allowed to be empty. Instances of this type with an empty value here are
                                        almost certainly wrong.
                                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                secretRef specifies the secret to use for obtaining the StorageOS API
                                credentials.  If not specified, default values will be attempted.
                              '';
                            };
                            volumeName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                volumeName is the human-readable name of the StorageOS volume.  Volume
                                names are only unique within a namespace.
                              '';
                            };
                            volumeNamespace = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                volumeNamespace specifies the scope of the volume within StorageOS.  If no
                                namespace is specified then the Pod's namespace will be used.  This allows the
                                Kubernetes name scoping to be mirrored within StorageOS for tighter integration.
                                Set VolumeName to any name to override the default behaviour.
                                Set to "default" if you are not using namespaces within StorageOS.
                                Namespaces that do not pre-exist within StorageOS will be created.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        storageOS represents a StorageOS volume attached and mounted on Kubernetes nodes.
                        Deprecated: StorageOS is deprecated and the in-tree storageos type is no longer supported.
                      '';
                    };
                    vsphereVolume = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            fsType = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                fsType is filesystem type to mount.
                                Must be a filesystem type supported by the host operating system.
                                Ex. "ext4", "xfs", "ntfs". Implicitly inferred to be "ext4" if unspecified.
                              '';
                            };
                            storagePolicyID = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "storagePolicyID is the storage Policy Based Management (SPBM) profile ID associated with the StoragePolicyName.";
                            };
                            storagePolicyName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "storagePolicyName is the storage Policy Based Management (SPBM) profile name.";
                            };
                            volumePath = mkOption {
                              type = types.str;
                              description = "volumePath is the path that identifies vSphere volume vmdk";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        vsphereVolume represents a vSphere volume attached and mounted on kubelets host machine.
                        Deprecated: VsphereVolume is deprecated. All operations for the in-tree vsphereVolume type
                        are redirected to the csi.vsphere.vmware.com CSI driver.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = "Volumes optional, additional volumes for NetBird container";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  NetworkResource = mkResource {
    apiVersion = "netbird.io/v1alpha1";
    kind = "NetworkResource";
    specType = (
      mkTypedSubmodule {
        options = {
          groups = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    id = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "ID is the id of the group.";
                    };
                    localRef = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            name = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Name of the referent.
                                This field is effectively required, but due to backwards compatibility is
                                allowed to be empty. Instances of this type with an empty value here are
                                almost certainly wrong.
                                More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "LocalReference is a reference to a group in the same namespace.";
                    };
                    name = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "Name is the name of the group.";
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = "Groups are references to groups that the resource will be a part of.";
          };
          networkRouterRef = mkOption {
            type = (
              mkTypedSubmodule {
                options = {
                  name = mkOption {
                    type = types.str;
                    description = "Name of the referent.";
                  };
                  namespace = mkOption {
                    type = types.str;
                    description = "Namespace of the referent.";
                  };
                };
                freeformType = types.attrs;
              }
            );
            description = "NetworkRouterRef is a reference to the network and router where the resource will be created.";
          };
          serviceRef = mkOption {
            type = (
              mkTypedSubmodule {
                options = {
                  name = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      Name of the referent.
                      This field is effectively required, but due to backwards compatibility is
                      allowed to be empty. Instances of this type with an empty value here are
                      almost certainly wrong.
                      More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                    '';
                  };
                };
                freeformType = types.attrs;
              }
            );
            description = "ServiceRef is a reference to the service to expose in the Network.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  NetworkRouter = mkResource {
    apiVersion = "netbird.io/v1alpha1";
    kind = "NetworkRouter";
    specType = (
      mkTypedSubmodule {
        options = {
          dnsZoneRef = mkOption {
            type = (
              mkTypedSubmodule {
                options = {
                  name = mkOption {
                    type = types.str;
                    description = "Name is the domain name of an existing Netbird DNS zone, e.g. \"example.com\".";
                  };
                };
                freeformType = types.attrs;
              }
            );
            description = "DNSZoneRef is a reference to the DNS zone used to create records for resources.";
          };
          image = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = "Netbird client image.";
          };
          logLevel = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = "Log level for Netbird client.";
          };
          workloadOverride = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  annotations = mkOption {
                    type = (types.nullOr (types.attrsOf types.str));
                    default = null;
                    description = "Annotations that will be added.";
                  };
                  labels = mkOption {
                    type = (types.nullOr (types.attrsOf types.str));
                    default = null;
                    description = "Labels that will be added.";
                  };
                  podTemplate = mkOption {
                    type = (types.nullOr types.anything);
                    default = null;
                    description = "PodTemplate overrides the pod template.";
                  };
                  replicas = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = "Replicas sets the amount of client replicas.";
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = "WorkloadOverride contains configuration that will override the default workload.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  SetupKey = mkResource {
    apiVersion = "netbird.io/v1alpha1";
    kind = "SetupKey";
    specType = (
      mkTypedSubmodule {
        options = {
          allowExtraDnsLabels = mkOption {
            type = types.bool;
            description = "AllowExtraDnsLabels decides if peers added with the key can have extra DNS labels.";
          };
          autoGroups = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    id = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "ID is the id of the group.";
                    };
                    localRef = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            name = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Name of the referent.
                                This field is effectively required, but due to backwards compatibility is
                                allowed to be empty. Instances of this type with an empty value here are
                                almost certainly wrong.
                                More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "LocalReference is a reference to a group in the same namespace.";
                    };
                    name = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "Name is the name of the group.";
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = "AutoGroups are groups that will be automatically assigned to peers using setup key.";
          };
          duration = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = "Duration sets how long the setup key is valid for.";
          };
          ephemeral = mkOption {
            type = types.bool;
            description = "Ephemeral decides if peers added with the key are ephemeral or not.";
          };
          name = mkOption {
            type = types.str;
            description = "Name of the setup key.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  SidecarProfile = mkResource {
    apiVersion = "netbird.io/v1alpha1";
    kind = "SidecarProfile";
    specType = (
      mkTypedSubmodule {
        options = {
          containerOverride = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  env = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (mkTypedSubmodule {
                          options = {
                            name = mkOption {
                              type = types.str;
                              description = ''
                                Name of the environment variable.
                                May consist of any printable ASCII characters except '='.
                              '';
                            };
                            value = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Variable references $(VAR_NAME) are expanded
                                using the previously defined environment variables in the container and
                                any service environment variables. If a variable cannot be resolved,
                                the reference in the input string will be unchanged. Double $$ are reduced
                                to a single $, which allows for escaping the $(VAR_NAME) syntax: i.e.
                                "$$(VAR_NAME)" will produce the string literal "$(VAR_NAME)".
                                Escaped references will never be expanded, regardless of whether the variable
                                exists or not.
                                Defaults to "".
                              '';
                            };
                            valueFrom = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    configMapKeyRef = mkOption {
                                      type = (
                                        types.nullOr (mkTypedSubmodule {
                                          options = {
                                            key = mkOption {
                                              type = types.str;
                                              description = "The key to select.";
                                            };
                                            name = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = ''
                                                Name of the referent.
                                                This field is effectively required, but due to backwards compatibility is
                                                allowed to be empty. Instances of this type with an empty value here are
                                                almost certainly wrong.
                                                More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                              '';
                                            };
                                            optional = mkOption {
                                              type = (types.nullOr types.bool);
                                              default = null;
                                              description = "Specify whether the ConfigMap or its key must be defined";
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      );
                                      default = null;
                                      description = "Selects a key of a ConfigMap.";
                                    };
                                    fieldRef = mkOption {
                                      type = (
                                        types.nullOr (mkTypedSubmodule {
                                          options = {
                                            apiVersion = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = "Version of the schema the FieldPath is written in terms of, defaults to \"v1\".";
                                            };
                                            fieldPath = mkOption {
                                              type = types.str;
                                              description = "Path of the field to select in the specified API version.";
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      );
                                      default = null;
                                      description = ''
                                        Selects a field of the pod: supports metadata.name, metadata.namespace, `metadata.labels['<KEY>']`, `metadata.annotations['<KEY>']`,
                                        spec.nodeName, spec.serviceAccountName, status.hostIP, status.podIP, status.podIPs.
                                      '';
                                    };
                                    fileKeyRef = mkOption {
                                      type = (
                                        types.nullOr (mkTypedSubmodule {
                                          options = {
                                            key = mkOption {
                                              type = types.str;
                                              description = ''
                                                The key within the env file. An invalid key will prevent the pod from starting.
                                                The keys defined within a source may consist of any printable ASCII characters except '='.
                                                During Alpha stage of the EnvFiles feature gate, the key size is limited to 128 characters.
                                              '';
                                            };
                                            optional = mkOption {
                                              type = (types.nullOr types.bool);
                                              default = null;
                                              description = ''
                                                Specify whether the file or its key must be defined. If the file or key
                                                does not exist, then the env var is not published.
                                                If optional is set to true and the specified key does not exist,
                                                the environment variable will not be set in the Pod's containers.

                                                If optional is set to false and the specified key does not exist,
                                                an error will be returned during Pod creation.
                                              '';
                                            };
                                            path = mkOption {
                                              type = types.str;
                                              description = ''
                                                The path within the volume from which to select the file.
                                                Must be relative and may not contain the '..' path or start with '..'.
                                              '';
                                            };
                                            volumeName = mkOption {
                                              type = types.str;
                                              description = "The name of the volume mount containing the env file.";
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      );
                                      default = null;
                                      description = ''
                                        FileKeyRef selects a key of the env file.
                                        Requires the EnvFiles feature gate to be enabled.
                                      '';
                                    };
                                    resourceFieldRef = mkOption {
                                      type = (
                                        types.nullOr (mkTypedSubmodule {
                                          options = {
                                            containerName = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = "Container name: required for volumes, optional for env vars";
                                            };
                                            divisor = mkOption {
                                              type = (types.nullOr types.anything);
                                              default = null;
                                              description = "Specifies the output format of the exposed resources, defaults to \"1\"";
                                            };
                                            resource = mkOption {
                                              type = types.str;
                                              description = "Required: resource to select";
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      );
                                      default = null;
                                      description = ''
                                        Selects a resource of the container: only resources limits and requests
                                        (limits.cpu, limits.memory, limits.ephemeral-storage, requests.cpu, requests.memory and requests.ephemeral-storage) are currently supported.
                                      '';
                                    };
                                    secretKeyRef = mkOption {
                                      type = (
                                        types.nullOr (mkTypedSubmodule {
                                          options = {
                                            key = mkOption {
                                              type = types.str;
                                              description = "The key of the secret to select from.  Must be a valid secret key.";
                                            };
                                            name = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = ''
                                                Name of the referent.
                                                This field is effectively required, but due to backwards compatibility is
                                                allowed to be empty. Instances of this type with an empty value here are
                                                almost certainly wrong.
                                                More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                                              '';
                                            };
                                            optional = mkOption {
                                              type = (types.nullOr types.bool);
                                              default = null;
                                              description = "Specify whether the Secret or its key must be defined";
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      );
                                      default = null;
                                      description = "Selects a key of a secret in the pod's namespace";
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = "Source for the environment variable's value. Cannot be used if value is not empty.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                  };
                  image = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = "Image overrides the image used by the client.";
                  };
                  livenessProbe = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          exec = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  command = mkOption {
                                    type = (types.nullOr (types.listOf types.str));
                                    default = null;
                                    description = ''
                                      Command is the command line to execute inside the container, the working directory for the
                                      command  is root ('/') in the container's filesystem. The command is simply exec'd, it is
                                      not run inside a shell, so traditional shell instructions ('|', etc) won't work. To use
                                      a shell, you need to explicitly call out to that shell.
                                      Exit status of 0 is treated as live/healthy and non-zero is unhealthy.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "Exec specifies a command to execute in the container.";
                          };
                          failureThreshold = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Minimum consecutive failures for the probe to be considered failed after having succeeded.
                              Defaults to 3. Minimum value is 1.
                            '';
                          };
                          grpc = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  port = mkOption {
                                    type = types.int;
                                    description = "Port number of the gRPC service. Number must be in the range 1 to 65535.";
                                  };
                                  service = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      Service is the name of the service to place in the gRPC HealthCheckRequest
                                      (see https://github.com/grpc/grpc/blob/master/doc/health-checking.md).

                                      If this is not specified, the default behavior is defined by gRPC.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "GRPC specifies a GRPC HealthCheckRequest.";
                          };
                          httpGet = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  host = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      Host name to connect to, defaults to the pod IP. You probably want to set
                                      "Host" in httpHeaders instead.
                                    '';
                                  };
                                  httpHeaders = mkOption {
                                    type = (
                                      types.nullOr (
                                        types.listOf (mkTypedSubmodule {
                                          options = {
                                            name = mkOption {
                                              type = types.str;
                                              description = ''
                                                The header field name.
                                                This will be canonicalized upon output, so case-variant names will be understood as the same header.
                                              '';
                                            };
                                            value = mkOption {
                                              type = types.str;
                                              description = "The header field value";
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      )
                                    );
                                    default = null;
                                    description = "Custom headers to set in the request. HTTP allows repeated headers.";
                                  };
                                  path = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "Path to access on the HTTP server.";
                                  };
                                  port = mkOption {
                                    type = types.anything;
                                    description = ''
                                      Name or number of the port to access on the container.
                                      Number must be in the range 1 to 65535.
                                      Name must be an IANA_SVC_NAME.
                                    '';
                                  };
                                  scheme = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      Scheme to use for connecting to the host.
                                      Defaults to HTTP.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "HTTPGet specifies an HTTP GET request to perform.";
                          };
                          initialDelaySeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Number of seconds after the container has started before liveness probes are initiated.
                              More info: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle#container-probes
                            '';
                          };
                          periodSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              How often (in seconds) to perform the probe.
                              Default to 10 seconds. Minimum value is 1.
                            '';
                          };
                          successThreshold = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Minimum consecutive successes for the probe to be considered successful after having failed.
                              Defaults to 1. Must be 1 for liveness and startup. Minimum value is 1.
                            '';
                          };
                          tcpSocket = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  host = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "Optional: Host name to connect to, defaults to the pod IP.";
                                  };
                                  port = mkOption {
                                    type = types.anything;
                                    description = ''
                                      Number or name of the port to access on the container.
                                      Number must be in the range 1 to 65535.
                                      Name must be an IANA_SVC_NAME.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "TCPSocket specifies a connection to a TCP port.";
                          };
                          terminationGracePeriodSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Optional duration in seconds the pod needs to terminate gracefully upon probe failure.
                              The grace period is the duration in seconds after the processes running in the pod are sent
                              a termination signal and the time when the processes are forcibly halted with a kill signal.
                              Set this value longer than the expected cleanup time for your process.
                              If this value is nil, the pod's terminationGracePeriodSeconds will be used. Otherwise, this
                              value overrides the value provided by the pod spec.
                              Value must be non-negative integer. The value zero indicates stop immediately via
                              the kill signal (no opportunity to shut down).
                              This is a beta field and requires enabling ProbeTerminationGracePeriod feature gate.
                              Minimum value is 1. spec.terminationGracePeriodSeconds is used if unset.
                            '';
                          };
                          timeoutSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Number of seconds after which the probe times out.
                              Defaults to 1 second. Minimum value is 1.
                              More info: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle#container-probes
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = "LivenessProbe overrides the liveness probe for the sidecar container.";
                  };
                  readinessProbe = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          exec = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  command = mkOption {
                                    type = (types.nullOr (types.listOf types.str));
                                    default = null;
                                    description = ''
                                      Command is the command line to execute inside the container, the working directory for the
                                      command  is root ('/') in the container's filesystem. The command is simply exec'd, it is
                                      not run inside a shell, so traditional shell instructions ('|', etc) won't work. To use
                                      a shell, you need to explicitly call out to that shell.
                                      Exit status of 0 is treated as live/healthy and non-zero is unhealthy.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "Exec specifies a command to execute in the container.";
                          };
                          failureThreshold = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Minimum consecutive failures for the probe to be considered failed after having succeeded.
                              Defaults to 3. Minimum value is 1.
                            '';
                          };
                          grpc = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  port = mkOption {
                                    type = types.int;
                                    description = "Port number of the gRPC service. Number must be in the range 1 to 65535.";
                                  };
                                  service = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      Service is the name of the service to place in the gRPC HealthCheckRequest
                                      (see https://github.com/grpc/grpc/blob/master/doc/health-checking.md).

                                      If this is not specified, the default behavior is defined by gRPC.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "GRPC specifies a GRPC HealthCheckRequest.";
                          };
                          httpGet = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  host = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      Host name to connect to, defaults to the pod IP. You probably want to set
                                      "Host" in httpHeaders instead.
                                    '';
                                  };
                                  httpHeaders = mkOption {
                                    type = (
                                      types.nullOr (
                                        types.listOf (mkTypedSubmodule {
                                          options = {
                                            name = mkOption {
                                              type = types.str;
                                              description = ''
                                                The header field name.
                                                This will be canonicalized upon output, so case-variant names will be understood as the same header.
                                              '';
                                            };
                                            value = mkOption {
                                              type = types.str;
                                              description = "The header field value";
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      )
                                    );
                                    default = null;
                                    description = "Custom headers to set in the request. HTTP allows repeated headers.";
                                  };
                                  path = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "Path to access on the HTTP server.";
                                  };
                                  port = mkOption {
                                    type = types.anything;
                                    description = ''
                                      Name or number of the port to access on the container.
                                      Number must be in the range 1 to 65535.
                                      Name must be an IANA_SVC_NAME.
                                    '';
                                  };
                                  scheme = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      Scheme to use for connecting to the host.
                                      Defaults to HTTP.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "HTTPGet specifies an HTTP GET request to perform.";
                          };
                          initialDelaySeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Number of seconds after the container has started before liveness probes are initiated.
                              More info: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle#container-probes
                            '';
                          };
                          periodSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              How often (in seconds) to perform the probe.
                              Default to 10 seconds. Minimum value is 1.
                            '';
                          };
                          successThreshold = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Minimum consecutive successes for the probe to be considered successful after having failed.
                              Defaults to 1. Must be 1 for liveness and startup. Minimum value is 1.
                            '';
                          };
                          tcpSocket = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  host = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "Optional: Host name to connect to, defaults to the pod IP.";
                                  };
                                  port = mkOption {
                                    type = types.anything;
                                    description = ''
                                      Number or name of the port to access on the container.
                                      Number must be in the range 1 to 65535.
                                      Name must be an IANA_SVC_NAME.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "TCPSocket specifies a connection to a TCP port.";
                          };
                          terminationGracePeriodSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Optional duration in seconds the pod needs to terminate gracefully upon probe failure.
                              The grace period is the duration in seconds after the processes running in the pod are sent
                              a termination signal and the time when the processes are forcibly halted with a kill signal.
                              Set this value longer than the expected cleanup time for your process.
                              If this value is nil, the pod's terminationGracePeriodSeconds will be used. Otherwise, this
                              value overrides the value provided by the pod spec.
                              Value must be non-negative integer. The value zero indicates stop immediately via
                              the kill signal (no opportunity to shut down).
                              This is a beta field and requires enabling ProbeTerminationGracePeriod feature gate.
                              Minimum value is 1. spec.terminationGracePeriodSeconds is used if unset.
                            '';
                          };
                          timeoutSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Number of seconds after which the probe times out.
                              Defaults to 1 second. Minimum value is 1.
                              More info: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle#container-probes
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = "ReadinessProbe overrides the readiness probe for the sidecar container.";
                  };
                  securityContext = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          allowPrivilegeEscalation = mkOption {
                            type = (types.nullOr types.bool);
                            default = null;
                            description = ''
                              AllowPrivilegeEscalation controls whether a process can gain more
                              privileges than its parent process. This bool directly controls if
                              the no_new_privs flag will be set on the container process.
                              AllowPrivilegeEscalation is true always when the container is:
                              1) run as Privileged
                              2) has CAP_SYS_ADMIN
                              Note that this field cannot be set when spec.os.name is windows.
                            '';
                          };
                          appArmorProfile = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  localhostProfile = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      localhostProfile indicates a profile loaded on the node that should be used.
                                      The profile must be preconfigured on the node to work.
                                      Must match the loaded name of the profile.
                                      Must be set if and only if type is "Localhost".
                                    '';
                                  };
                                  type = mkOption {
                                    type = types.str;
                                    description = ''
                                      type indicates which kind of AppArmor profile will be applied.
                                      Valid options are:
                                        Localhost - a profile pre-loaded on the node.
                                        RuntimeDefault - the container runtime's default profile.
                                        Unconfined - no AppArmor enforcement.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              appArmorProfile is the AppArmor options to use by this container. If set, this profile
                              overrides the pod's appArmorProfile.
                              Note that this field cannot be set when spec.os.name is windows.
                            '';
                          };
                          capabilities = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  add = mkOption {
                                    type = (types.nullOr (types.listOf types.str));
                                    default = null;
                                    description = "Added capabilities";
                                  };
                                  drop = mkOption {
                                    type = (types.nullOr (types.listOf types.str));
                                    default = null;
                                    description = "Removed capabilities";
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              The capabilities to add/drop when running containers.
                              Defaults to the default set of capabilities granted by the container runtime.
                              Note that this field cannot be set when spec.os.name is windows.
                            '';
                          };
                          privileged = mkOption {
                            type = (types.nullOr types.bool);
                            default = null;
                            description = ''
                              Run container in privileged mode.
                              Processes in privileged containers are essentially equivalent to root on the host.
                              Defaults to false.
                              Note that this field cannot be set when spec.os.name is windows.
                            '';
                          };
                          procMount = mkOption {
                            type = (types.nullOr types.str);
                            default = null;
                            description = ''
                              procMount denotes the type of proc mount to use for the containers.
                              The default value is Default which uses the container runtime defaults for
                              readonly paths and masked paths.
                              Note that this field cannot be set when spec.os.name is windows.
                            '';
                          };
                          readOnlyRootFilesystem = mkOption {
                            type = (types.nullOr types.bool);
                            default = null;
                            description = ''
                              Whether this container has a read-only root filesystem.
                              Default is false.
                              Note that this field cannot be set when spec.os.name is windows.
                            '';
                          };
                          runAsGroup = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              The GID to run the entrypoint of the container process.
                              Uses runtime default if unset.
                              May also be set in PodSecurityContext.  If set in both SecurityContext and
                              PodSecurityContext, the value specified in SecurityContext takes precedence.
                              Note that this field cannot be set when spec.os.name is windows.
                            '';
                          };
                          runAsNonRoot = mkOption {
                            type = (types.nullOr types.bool);
                            default = null;
                            description = ''
                              Indicates that the container must run as a non-root user.
                              If true, the Kubelet will validate the image at runtime to ensure that it
                              does not run as UID 0 (root) and fail to start the container if it does.
                              If unset or false, no such validation will be performed.
                              May also be set in PodSecurityContext.  If set in both SecurityContext and
                              PodSecurityContext, the value specified in SecurityContext takes precedence.
                            '';
                          };
                          runAsUser = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              The UID to run the entrypoint of the container process.
                              Defaults to user specified in image metadata if unspecified.
                              May also be set in PodSecurityContext.  If set in both SecurityContext and
                              PodSecurityContext, the value specified in SecurityContext takes precedence.
                              Note that this field cannot be set when spec.os.name is windows.
                            '';
                          };
                          seLinuxOptions = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  level = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "Level is SELinux level label that applies to the container.";
                                  };
                                  role = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "Role is a SELinux role label that applies to the container.";
                                  };
                                  type = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "Type is a SELinux type label that applies to the container.";
                                  };
                                  user = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "User is a SELinux user label that applies to the container.";
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              The SELinux context to be applied to the container.
                              If unspecified, the container runtime will allocate a random SELinux context for each
                              container.  May also be set in PodSecurityContext.  If set in both SecurityContext and
                              PodSecurityContext, the value specified in SecurityContext takes precedence.
                              Note that this field cannot be set when spec.os.name is windows.
                            '';
                          };
                          seccompProfile = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  localhostProfile = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      localhostProfile indicates a profile defined in a file on the node should be used.
                                      The profile must be preconfigured on the node to work.
                                      Must be a descending path, relative to the kubelet's configured seccomp profile location.
                                      Must be set if type is "Localhost". Must NOT be set for any other type.
                                    '';
                                  };
                                  type = mkOption {
                                    type = types.str;
                                    description = ''
                                      type indicates which kind of seccomp profile will be applied.
                                      Valid options are:

                                      Localhost - a profile defined in a file on the node should be used.
                                      RuntimeDefault - the container runtime default profile should be used.
                                      Unconfined - no profile should be applied.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              The seccomp options to use by this container. If seccomp options are
                              provided at both the pod & container level, the container options
                              override the pod options.
                              Note that this field cannot be set when spec.os.name is windows.
                            '';
                          };
                          windowsOptions = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  gmsaCredentialSpec = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      GMSACredentialSpec is where the GMSA admission webhook
                                      (https://github.com/kubernetes-sigs/windows-gmsa) inlines the contents of the
                                      GMSA credential spec named by the GMSACredentialSpecName field.
                                    '';
                                  };
                                  gmsaCredentialSpecName = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "GMSACredentialSpecName is the name of the GMSA credential spec to use.";
                                  };
                                  hostProcess = mkOption {
                                    type = (types.nullOr types.bool);
                                    default = null;
                                    description = ''
                                      HostProcess determines if a container should be run as a 'Host Process' container.
                                      All of a Pod's containers must have the same effective HostProcess value
                                      (it is not allowed to have a mix of HostProcess containers and non-HostProcess containers).
                                      In addition, if HostProcess is true then HostNetwork must also be set to true.
                                    '';
                                  };
                                  runAsUserName = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      The UserName in Windows to run the entrypoint of the container process.
                                      Defaults to the user specified in image metadata if unspecified.
                                      May also be set in PodSecurityContext. If set in both SecurityContext and
                                      PodSecurityContext, the value specified in SecurityContext takes precedence.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              The Windows specific settings applied to all containers.
                              If unspecified, the options from the PodSecurityContext will be used.
                              If set in both SecurityContext and PodSecurityContext, the value specified in SecurityContext takes precedence.
                              Note that this field cannot be set when spec.os.name is linux.
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      SecurityContext holds security configuration that will be applied to a container.
                      Some fields are present in both SecurityContext and PodSecurityContext.  When both
                      are set, the values in SecurityContext take precedence.
                    '';
                  };
                  startupProbe = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          exec = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  command = mkOption {
                                    type = (types.nullOr (types.listOf types.str));
                                    default = null;
                                    description = ''
                                      Command is the command line to execute inside the container, the working directory for the
                                      command  is root ('/') in the container's filesystem. The command is simply exec'd, it is
                                      not run inside a shell, so traditional shell instructions ('|', etc) won't work. To use
                                      a shell, you need to explicitly call out to that shell.
                                      Exit status of 0 is treated as live/healthy and non-zero is unhealthy.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "Exec specifies a command to execute in the container.";
                          };
                          failureThreshold = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Minimum consecutive failures for the probe to be considered failed after having succeeded.
                              Defaults to 3. Minimum value is 1.
                            '';
                          };
                          grpc = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  port = mkOption {
                                    type = types.int;
                                    description = "Port number of the gRPC service. Number must be in the range 1 to 65535.";
                                  };
                                  service = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      Service is the name of the service to place in the gRPC HealthCheckRequest
                                      (see https://github.com/grpc/grpc/blob/master/doc/health-checking.md).

                                      If this is not specified, the default behavior is defined by gRPC.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "GRPC specifies a GRPC HealthCheckRequest.";
                          };
                          httpGet = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  host = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      Host name to connect to, defaults to the pod IP. You probably want to set
                                      "Host" in httpHeaders instead.
                                    '';
                                  };
                                  httpHeaders = mkOption {
                                    type = (
                                      types.nullOr (
                                        types.listOf (mkTypedSubmodule {
                                          options = {
                                            name = mkOption {
                                              type = types.str;
                                              description = ''
                                                The header field name.
                                                This will be canonicalized upon output, so case-variant names will be understood as the same header.
                                              '';
                                            };
                                            value = mkOption {
                                              type = types.str;
                                              description = "The header field value";
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      )
                                    );
                                    default = null;
                                    description = "Custom headers to set in the request. HTTP allows repeated headers.";
                                  };
                                  path = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "Path to access on the HTTP server.";
                                  };
                                  port = mkOption {
                                    type = types.anything;
                                    description = ''
                                      Name or number of the port to access on the container.
                                      Number must be in the range 1 to 65535.
                                      Name must be an IANA_SVC_NAME.
                                    '';
                                  };
                                  scheme = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      Scheme to use for connecting to the host.
                                      Defaults to HTTP.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "HTTPGet specifies an HTTP GET request to perform.";
                          };
                          initialDelaySeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Number of seconds after the container has started before liveness probes are initiated.
                              More info: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle#container-probes
                            '';
                          };
                          periodSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              How often (in seconds) to perform the probe.
                              Default to 10 seconds. Minimum value is 1.
                            '';
                          };
                          successThreshold = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Minimum consecutive successes for the probe to be considered successful after having failed.
                              Defaults to 1. Must be 1 for liveness and startup. Minimum value is 1.
                            '';
                          };
                          tcpSocket = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  host = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = "Optional: Host name to connect to, defaults to the pod IP.";
                                  };
                                  port = mkOption {
                                    type = types.anything;
                                    description = ''
                                      Number or name of the port to access on the container.
                                      Number must be in the range 1 to 65535.
                                      Name must be an IANA_SVC_NAME.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = "TCPSocket specifies a connection to a TCP port.";
                          };
                          terminationGracePeriodSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Optional duration in seconds the pod needs to terminate gracefully upon probe failure.
                              The grace period is the duration in seconds after the processes running in the pod are sent
                              a termination signal and the time when the processes are forcibly halted with a kill signal.
                              Set this value longer than the expected cleanup time for your process.
                              If this value is nil, the pod's terminationGracePeriodSeconds will be used. Otherwise, this
                              value overrides the value provided by the pod spec.
                              Value must be non-negative integer. The value zero indicates stop immediately via
                              the kill signal (no opportunity to shut down).
                              This is a beta field and requires enabling ProbeTerminationGracePeriod feature gate.
                              Minimum value is 1. spec.terminationGracePeriodSeconds is used if unset.
                            '';
                          };
                          timeoutSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              Number of seconds after which the probe times out.
                              Defaults to 1 second. Minimum value is 1.
                              More info: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle#container-probes
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = "StartupProbe overrides the startup probe for the sidecar container.";
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
          };
          extraDNSLabels = mkOption {
            type = (types.nullOr (types.listOf types.str));
            default = null;
            description = "ExtraDNSLabels assigns additional DNS names to peers beyond their default hostname.";
          };
          injectionMode = mkOption {
            type = (
              types.nullOr (
                types.enum [
                  "Sidecar"
                  "Container"
                ]
              )
            );
            default = null;
            description = "InjectionMode defines whether the sidecar is injected as a native Kubernetes sidecar container or as a regular container.";
          };
          podSelector = mkOption {
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
              PodSelector determines which pods the profile should apply to.
              An empty slector means the profile will apply to all pods in the namespace.
            '';
          };
          setupKeyRef = mkOption {
            type = (
              mkTypedSubmodule {
                options = {
                  name = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      Name of the referent.
                      This field is effectively required, but due to backwards compatibility is
                      allowed to be empty. Instances of this type with an empty value here are
                      almost certainly wrong.
                      More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                    '';
                  };
                };
                freeformType = types.attrs;
              }
            );
            description = "SetupKeyRef is the reference to the setup key used in the client.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

}
