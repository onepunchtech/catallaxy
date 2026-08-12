{ lib, k8sTypes }:

let
  inherit (lib) mkOption types;
  inherit (k8sTypes) mkTypedSubmodule mkResource;
in
{
  CiliumClusterwideEnvoyConfig = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumClusterwideEnvoyConfig";
    specType = (
      mkTypedSubmodule {
        options = {
          backendServices = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      description = ''
                        Name is the name of a destination Kubernetes service that identifies traffic
                        to be redirected.
                      '';
                    };
                    namespace = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Namespace is the Kubernetes service namespace.
                        In CiliumEnvoyConfig namespace defaults to the namespace of the CEC,
                        In CiliumClusterwideEnvoyConfig namespace defaults to "default".
                      '';
                    };
                    number = mkOption {
                      type = (types.nullOr (types.listOf types.str));
                      default = null;
                      description = ''
                        Ports is a set of port numbers, which can be used for filtering in case of underlying
                        is exposing multiple port numbers.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              BackendServices specifies Kubernetes services whose backends
              are automatically synced to Envoy using EDS.  Traffic for these
              services is not forwarded to an Envoy listener. This allows an
              Envoy listener load balance traffic to these backends while
              normal Cilium service load balancing takes care of balancing
              traffic for these services at the same time.
            '';
          };
          nodeSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
              NodeSelector is a label selector that determines to which nodes
              this configuration applies.
              If nil, then this config applies to all nodes.
            '';
          };
          resources = mkOption {
            type = (types.listOf types.attrs);
            description = ''
              Envoy xDS resources, a list of the following Envoy resource types:
              type.googleapis.com/envoy.config.listener.v3.Listener,
              type.googleapis.com/envoy.config.route.v3.RouteConfiguration,
              type.googleapis.com/envoy.config.cluster.v3.Cluster,
              type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment, and
              type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret.
            '';
          };
          services = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    listener = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Listener specifies the name of the Envoy listener the
                        service traffic is redirected to. The listener must be
                        specified in the Envoy 'resources' of the same
                        CiliumEnvoyConfig.

                        If omitted, the first listener specified in 'resources' is
                        used.
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = ''
                        Name is the name of a destination Kubernetes service that identifies traffic
                        to be redirected.
                      '';
                    };
                    namespace = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Namespace is the Kubernetes service namespace.
                        In CiliumEnvoyConfig namespace this is overridden to the namespace of the CEC,
                        In CiliumClusterwideEnvoyConfig namespace defaults to "default".
                      '';
                    };
                    ports = mkOption {
                      type = (types.nullOr (types.listOf types.int));
                      default = null;
                      description = ''
                        Ports is a set of service's frontend ports that should be redirected to the Envoy
                        listener. By default all frontend ports of the service are redirected.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Services specifies Kubernetes services for which traffic is
              forwarded to an Envoy listener for L7 load balancing. Backends
              of these services are automatically synced to Envoy usign EDS.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumClusterwideNetworkPolicy = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumClusterwideNetworkPolicy";
    specType = (
      mkTypedSubmodule {
        options = {
          description = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = ''
              Description is a free form string, it can be used by the creator of
              the rule to store human readable explanation of the purpose of this
              rule. Rules cannot be identified by comment.
            '';
          };
          egress = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    authentication = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            mode = mkOption {
                              type = (
                                types.enum [
                                  "disabled"
                                  "required"
                                  "test-always-fail"
                                ]
                              );
                              description = "Mode is the required authentication mode for the allowed traffic, if any.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "Authentication is the required authentication type for the allowed traffic, if any.";
                    };
                    icmps = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              fields = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        family = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "IPv4"
                                                "IPv6"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Family is a IP address version.
                                            Currently, we support `IPv4` and `IPv6`.
                                            `IPv4` is set as default.
                                          '';
                                        };
                                        type = mkOption {
                                          type = types.anything;
                                          description = ''
                                            Type is a ICMP-type.
                                            It should be an 8bit code (0-255), or it's CamelCase name (for example, "EchoReply").
                                            Allowed ICMP types are:
                                                Ipv4: EchoReply | DestinationUnreachable | Redirect | Echo | EchoRequest |
                                            		     RouterAdvertisement | RouterSelection | TimeExceeded | ParameterProblem |
                                            			 Timestamp | TimestampReply | Photuris | ExtendedEcho Request | ExtendedEcho Reply
                                                Ipv6: DestinationUnreachable | PacketTooBig | TimeExceeded | ParameterProblem |
                                            			 EchoRequest | EchoReply | MulticastListenerQuery| MulticastListenerReport |
                                            			 MulticastListenerDone | RouterSolicitation | RouterAdvertisement | NeighborSolicitation |
                                            			 NeighborAdvertisement | RedirectMessage | RouterRenumbering | ICMPNodeInformationQuery |
                                            			 ICMPNodeInformationResponse | InverseNeighborDiscoverySolicitation | InverseNeighborDiscoveryAdvertisement |
                                            			 HomeAgentAddressDiscoveryRequest | HomeAgentAddressDiscoveryReply | MobilePrefixSolicitation |
                                            			 MobilePrefixAdvertisement | DuplicateAddressRequestCodeSuffix | DuplicateAddressConfirmationCodeSuffix |
                                            			 ExtendedEchoRequest | ExtendedEchoReply
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Fields is a list of ICMP fields.";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ICMPs is a list of ICMP rule identified by type number
                        which the endpoint subject to the rule is allowed to connect to.

                        Example:
                        Any endpoint with the label "app=httpd" is allowed to initiate
                        type 8 ICMP connections.
                      '';
                    };
                    toCIDR = mkOption {
                      type = (types.nullOr (types.listOf types.str));
                      default = null;
                      description = ''
                        ToCIDR is a list of IP blocks which the endpoint subject to the rule
                        is allowed to initiate connections. Only connections destined for
                        outside of the cluster and not targeting the host will be subject
                        to CIDR rules.  This will match on the destination IP address of
                        outgoing connections. Adding a prefix into ToCIDR or into ToCIDRSet
                        with no ExcludeCIDRs is equivalent. Overlaps are allowed between
                        ToCIDR and ToCIDRSet.

                        Example:
                        Any endpoint with the label "app=database-proxy" is allowed to
                        initiate connections to 10.2.3.0/24
                      '';
                    };
                    toCIDRSet = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              cidr = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = "CIDR is a CIDR prefix / IP Block.";
                              };
                              cidrGroupRef = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  CIDRGroupRef is a reference to a CiliumCIDRGroup object.
                                  A CiliumCIDRGroup contains a list of CIDRs that the endpoint, subject to
                                  the rule, can (Ingress/Egress) or cannot (IngressDeny/EgressDeny) receive
                                  connections from.
                                '';
                              };
                              cidrGroupSelector = mkOption {
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
                                                  type = (
                                                    types.enum [
                                                      "In"
                                                      "NotIn"
                                                      "Exists"
                                                      "DoesNotExist"
                                                    ]
                                                  );
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
                                  CIDRGroupSelector selects CiliumCIDRGroups by their labels,
                                  rather than by name.
                                '';
                              };
                              except = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ExceptCIDRs is a list of IP blocks which the endpoint subject to the rule
                                  is not allowed to initiate connections to. These CIDR prefixes should be
                                  contained within Cidr, using ExceptCIDRs together with CIDRGroupRef is not
                                  supported yet.
                                  These exceptions are only applied to the Cidr in this CIDRRule, and do not
                                  apply to any other CIDR prefixes in any other CIDRRules.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToCIDRSet is a list of IP blocks which the endpoint subject to the rule
                        is allowed to initiate connections to in addition to connections
                        which are allowed via ToEndpoints, along with a list of subnets contained
                        within their corresponding IP block to which traffic should not be
                        allowed. This will match on the destination IP address of outgoing
                        connections. Adding a prefix into ToCIDR or into ToCIDRSet with no
                        ExcludeCIDRs is equivalent. Overlaps are allowed between ToCIDR and
                        ToCIDRSet.

                        Example:
                        Any endpoint with the label "app=database-proxy" is allowed to
                        initiate connections to 10.2.3.0/24 except from IPs in subnet 10.2.3.0/28.
                      '';
                    };
                    toEndpoints = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToEndpoints is a list of endpoints identified by an EndpointSelector to
                        which the endpoints subject to the rule are allowed to communicate.

                        Example:
                        Any endpoint with the label "role=frontend" can communicate with any
                        endpoint carrying the label "role=backend".
                      '';
                    };
                    toEntities = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (
                            types.enum [
                              "all"
                              "world"
                              "cluster"
                              "host"
                              "init"
                              "ingress"
                              "unmanaged"
                              "remote-node"
                              "health"
                              "none"
                              "kube-apiserver"
                            ]
                          )
                        )
                      );
                      default = null;
                      description = ''
                        ToEntities is a list of special entities to which the endpoint subject
                        to the rule is allowed to initiate connections. Supported entities are
                        `world`, `cluster`,`host`,`remote-node`,`kube-apiserver`, `init`,
                        `health`,`unmanaged` and `all`.
                      '';
                    };
                    toFQDNs = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              matchName = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  MatchName matches literal DNS names. A trailing "." is automatically added
                                  when missing.
                                '';
                              };
                              matchPattern = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  MatchPattern allows using wildcards to match DNS names. All wildcards are
                                  case insensitive. The wildcards are:
                                  - "*" matches 0 or more DNS valid characters, and may occur anywhere in
                                  the pattern. As a special case a "*" as the leftmost character, without a
                                  following "." matches all subdomains as well as the name to the right.
                                  A trailing "." is automatically added when missing.

                                  Examples:
                                  `*.cilium.io` matches subomains of cilium at that level
                                    www.cilium.io and blog.cilium.io match, cilium.io and google.com do not
                                  `*cilium.io` matches cilium.io and all subdomains ends with "cilium.io"
                                    except those containing "." separator, subcilium.io and sub-cilium.io match,
                                    www.cilium.io and blog.cilium.io does not
                                  sub*.cilium.io matches subdomains of cilium where the subdomain component
                                  begins with "sub"
                                    sub.cilium.io and subdomain.cilium.io match, www.cilium.io,
                                    blog.cilium.io, cilium.io and google.com do not
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToFQDN allows whitelisting DNS names in place of IPs. The IPs that result
                        from DNS resolution of `ToFQDN.MatchName`s are added to the same
                        EgressRule object as ToCIDRSet entries, and behave accordingly. Any L4 and
                        L7 rules within this EgressRule will also apply to these IPs.
                        The DNS -> IP mapping is re-resolved periodically from within the
                        cilium-agent, and the IPs in the DNS response are effected in the policy
                        for selected pods as-is (i.e. the list of IPs is not modified in any way).
                        Note: An explicit rule to allow for DNS traffic is needed for the pods, as
                        ToFQDN counts as an egress rule and will enforce egress policy when
                        PolicyEnforcment=default.
                        Note: If the resolved IPs are IPs within the kubernetes cluster, the
                        ToFQDN rule will not apply to that IP.
                        Note: ToFQDN cannot occur in the same policy as other To* rules.
                      '';
                    };
                    toGroups = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              aws = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      labels = mkOption {
                                        type = (types.nullOr (types.attrsOf types.str));
                                        default = null;
                                      };
                                      region = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      securityGroupsIds = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                      securityGroupsNames = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "AWSGroup is an structure that can be used to whitelisting information from AWS integration";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToGroups is a directive that allows the integration with multiple outside
                        providers. Currently, only AWS is supported, and the rule can select by
                        multiple sub directives:

                        Example:
                        toGroups:
                        - aws:
                            securityGroupsIds:
                            - 'sg-XXXXXXXXXXXXX'
                      '';
                    };
                    toNodes = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToNodes is a list of nodes identified by an
                        EndpointSelector to which endpoints subject to the rule is allowed to communicate.
                      '';
                    };
                    toPorts = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              listener = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      envoyConfig = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              kind = mkOption {
                                                type = (
                                                  types.nullOr (
                                                    types.enum [
                                                      "CiliumEnvoyConfig"
                                                      "CiliumClusterwideEnvoyConfig"
                                                    ]
                                                  )
                                                );
                                                default = null;
                                                description = ''
                                                  Kind is the resource type being referred to. Defaults to CiliumEnvoyConfig or
                                                  CiliumClusterwideEnvoyConfig for CiliumNetworkPolicy and CiliumClusterwideNetworkPolicy,
                                                  respectively. The only case this is currently explicitly needed is when referring to a
                                                  CiliumClusterwideEnvoyConfig from CiliumNetworkPolicy, as using a namespaced listener
                                                  from a cluster scoped policy is not allowed.
                                                '';
                                              };
                                              name = mkOption {
                                                type = types.str;
                                                description = ''
                                                  Name is the resource name of the CiliumEnvoyConfig or CiliumClusterwideEnvoyConfig where
                                                  the listener is defined in.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          EnvoyConfig is a reference to the CEC or CCEC resource in which
                                          the listener is defined.
                                        '';
                                      };
                                      name = mkOption {
                                        type = types.str;
                                        description = "Name is the name of the listener.";
                                      };
                                      priority = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          Priority for this Listener that is used when multiple rules would apply different
                                          listeners to a policy map entry. Behavior of this is implementation dependent.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  listener specifies the name of a custom Envoy listener to which this traffic should be
                                  redirected to.
                                '';
                              };
                              originatingTLS = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      certificate = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Certificate is the file name or k8s secret item name for the certificate
                                          chain. If omitted, 'tls.crt' is assumed, if it exists. If given, the
                                          item must exist.
                                        '';
                                      };
                                      privateKey = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          PrivateKey is the file name or k8s secret item name for the private key
                                          matching the certificate chain. If omitted, 'tls.key' is assumed, if it
                                          exists. If given, the item must exist.
                                        '';
                                      };
                                      secret = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              name = mkOption {
                                                type = types.str;
                                                description = "Name is the name of the secret.";
                                              };
                                              namespace = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Namespace is the namespace in which the secret exists. Context of use
                                                  determines the default value if left out (e.g., "default").
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          Secret is the secret that contains the certificates and private key for
                                          the TLS context.
                                          By default, Cilium will search in this secret for the following items:
                                           - 'ca.crt'  - Which represents the trusted CA to verify remote source.
                                           - 'tls.crt' - Which represents the public key certificate.
                                           - 'tls.key' - Which represents the private key matching the public key
                                                         certificate.
                                        '';
                                      };
                                      trustedCA = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          TrustedCA is the file name or k8s secret item name for the trusted CA.
                                          If omitted, 'ca.crt' is assumed, if it exists. If given, the item must
                                          exist.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  OriginatingTLS is the TLS context for the connections originated by
                                  the L7 proxy.  For egress policy this specifies the client-side TLS
                                  parameters for the upstream connection originating from the L7 proxy
                                  to the remote destination. For ingress policy this specifies the
                                  client-side TLS parameters for the connection from the L7 proxy to
                                  the local endpoint.
                                '';
                              };
                              ports = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        endPort = mkOption {
                                          type = (types.nullOr types.int);
                                          default = null;
                                          description = "EndPort can only be an L4 port number.";
                                        };
                                        port = mkOption {
                                          type = types.str;
                                          description = ''
                                            Port can be an L4 port number, or a name in the form of "http"
                                            or "http-8080".
                                          '';
                                        };
                                        protocol = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "TCP"
                                                "UDP"
                                                "SCTP"
                                                "ANY"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Protocol is the L4 protocol. If omitted or empty, any protocol
                                            matches. Accepted values: "TCP", "UDP", "SCTP", "ANY"

                                            Matching on ICMP is not supported.

                                            Named port specified for a container may narrow this down, but may not
                                            contradict this.
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Ports is a list of L4 port/protocol";
                              };
                              rules = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      dns = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                matchName = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    MatchName matches literal DNS names. A trailing "." is automatically added
                                                    when missing.
                                                  '';
                                                };
                                                matchPattern = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    MatchPattern allows using wildcards to match DNS names. All wildcards are
                                                    case insensitive. The wildcards are:
                                                    - "*" matches 0 or more DNS valid characters, and may occur anywhere in
                                                    the pattern. As a special case a "*" as the leftmost character, without a
                                                    following "." matches all subdomains as well as the name to the right.
                                                    A trailing "." is automatically added when missing.

                                                    Examples:
                                                    `*.cilium.io` matches subomains of cilium at that level
                                                      www.cilium.io and blog.cilium.io match, cilium.io and google.com do not
                                                    `*cilium.io` matches cilium.io and all subdomains ends with "cilium.io"
                                                      except those containing "." separator, subcilium.io and sub-cilium.io match,
                                                      www.cilium.io and blog.cilium.io does not
                                                    sub*.cilium.io matches subdomains of cilium where the subdomain component
                                                    begins with "sub"
                                                      sub.cilium.io and subdomain.cilium.io match, www.cilium.io,
                                                      blog.cilium.io, cilium.io and google.com do not
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "DNS-specific rules.";
                                      };
                                      http = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                headerMatches = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          mismatch = mkOption {
                                                            type = (
                                                              types.nullOr (
                                                                types.enum [
                                                                  "LOG"
                                                                  "ADD"
                                                                  "DELETE"
                                                                  "REPLACE"
                                                                ]
                                                              )
                                                            );
                                                            default = null;
                                                            description = ''
                                                              Mismatch identifies what to do in case there is no match. The default is
                                                              to drop the request. Otherwise the overall rule is still considered as
                                                              matching, but the mismatches are logged in the access log.
                                                            '';
                                                          };
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = "Name identifies the header.";
                                                          };
                                                          secret = mkOption {
                                                            type = (
                                                              types.nullOr (mkTypedSubmodule {
                                                                options = {
                                                                  name = mkOption {
                                                                    type = types.str;
                                                                    description = "Name is the name of the secret.";
                                                                  };
                                                                  namespace = mkOption {
                                                                    type = (types.nullOr types.str);
                                                                    default = null;
                                                                    description = ''
                                                                      Namespace is the namespace in which the secret exists. Context of use
                                                                      determines the default value if left out (e.g., "default").
                                                                    '';
                                                                  };
                                                                };
                                                                freeformType = types.attrs;
                                                              })
                                                            );
                                                            default = null;
                                                            description = ''
                                                              Secret refers to a secret that contains the value to be matched against.
                                                              The secret must only contain one entry. If the referred secret does not
                                                              exist, and there is no "Value" specified, the match will fail.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = (types.nullOr types.str);
                                                            default = null;
                                                            description = ''
                                                              Value matches the exact value of the header. Can be specified either
                                                              alone or together with "Secret"; will be used as the header value if the
                                                              secret can not be found in the latter case.
                                                            '';
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    HeaderMatches is a list of HTTP headers which must be
                                                    present and match against the given values. Mismatch field can be used
                                                    to specify what to do when there is no match.
                                                  '';
                                                };
                                                headers = mkOption {
                                                  type = (types.nullOr (types.listOf types.str));
                                                  default = null;
                                                  description = ''
                                                    Headers is a list of HTTP headers which must be present in the
                                                    request. If omitted or empty, requests are allowed regardless of
                                                    headers present.
                                                  '';
                                                };
                                                host = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Host is an extended POSIX regex matched against the host header of a
                                                    request. Examples:

                                                    - foo.bar.com will match the host fooXbar.com or foo-bar.com
                                                    - foo\.bar\.com will only match the host foo.bar.com

                                                    If omitted or empty, the value of the host header is ignored.
                                                  '';
                                                };
                                                method = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Method is an extended POSIX regex matched against the method of a
                                                    request, e.g. "GET", "POST", "PUT", "PATCH", "DELETE", ...

                                                    If omitted or empty, all methods are allowed.
                                                  '';
                                                };
                                                path = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Path is an extended POSIX regex matched against the path of a
                                                    request. Currently it can contain characters disallowed from the
                                                    conventional "path" part of a URL as defined by RFC 3986.

                                                    If omitted or empty, all paths are all allowed.
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "HTTP specific rules.";
                                      };
                                      kafka = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                apiKey = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    APIKey is a case-insensitive string matched against the key of a
                                                    request, e.g. "produce", "fetch", "createtopic", "deletetopic", et al
                                                    Reference: https://kafka.apache.org/protocol#protocol_api_keys

                                                    If omitted or empty, and if Role is not specified, then all keys are allowed.
                                                  '';
                                                };
                                                apiVersion = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    APIVersion is the version matched against the api version of the
                                                    Kafka message. If set, it has to be a string representing a positive
                                                    integer.

                                                    If omitted or empty, all versions are allowed.
                                                  '';
                                                };
                                                clientID = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    ClientID is the client identifier as provided in the request.

                                                    From Kafka protocol documentation:
                                                    This is a user supplied identifier for the client application. The
                                                    user can use any identifier they like and it will be used when
                                                    logging errors, monitoring aggregates, etc. For example, one might
                                                    want to monitor not just the requests per second overall, but the
                                                    number coming from each client application (each of which could
                                                    reside on multiple servers). This id acts as a logical grouping
                                                    across all requests from a particular client.

                                                    If omitted or empty, all client identifiers are allowed.
                                                  '';
                                                };
                                                role = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.enum [
                                                        "produce"
                                                        "consume"
                                                      ]
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Role is a case-insensitive string and describes a group of API keys
                                                    necessary to perform certain higher-level Kafka operations such as "produce"
                                                    or "consume". A Role automatically expands into all APIKeys required
                                                    to perform the specified higher-level operation.

                                                    The following values are supported:
                                                     - "produce": Allow producing to the topics specified in the rule
                                                     - "consume": Allow consuming from the topics specified in the rule

                                                    This field is incompatible with the APIKey field, i.e APIKey and Role
                                                    cannot both be specified in the same rule.

                                                    If omitted or empty, and if APIKey is not specified, then all keys are
                                                    allowed.
                                                  '';
                                                };
                                                topic = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Topic is the topic name contained in the message. If a Kafka request
                                                    contains multiple topics, then all topics must be allowed or the
                                                    message will be rejected.

                                                    This constraint is ignored if the matched request message type
                                                    doesn't contain any topic. Maximum size of Topic can be 249
                                                    characters as per recent Kafka spec and allowed characters are
                                                    a-z, A-Z, 0-9, -, . and _.

                                                    Older Kafka versions had longer topic lengths of 255, but in Kafka 0.10
                                                    version the length was changed from 255 to 249. For compatibility
                                                    reasons we are using 255.

                                                    If omitted or empty, all topics are allowed.
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "Kafka-specific rules.";
                                      };
                                      l7 = mkOption {
                                        type = (types.nullOr (types.listOf (types.attrsOf types.str)));
                                        default = null;
                                        description = "Key-value pair rules.";
                                      };
                                      l7proto = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = "Name of the L7 protocol for which the Key-value pair rules apply.";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  Rules is a list of additional port level rules which must be met in
                                  order for the PortRule to allow the traffic. If omitted or empty,
                                  no layer 7 rules are enforced.
                                '';
                              };
                              serverNames = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ServerNames is a list of allowed TLS SNI values. If not empty, then
                                  TLS must be present and one of the provided SNIs must be indicated in the
                                  TLS handshake.
                                '';
                              };
                              terminatingTLS = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      certificate = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Certificate is the file name or k8s secret item name for the certificate
                                          chain. If omitted, 'tls.crt' is assumed, if it exists. If given, the
                                          item must exist.
                                        '';
                                      };
                                      privateKey = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          PrivateKey is the file name or k8s secret item name for the private key
                                          matching the certificate chain. If omitted, 'tls.key' is assumed, if it
                                          exists. If given, the item must exist.
                                        '';
                                      };
                                      secret = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              name = mkOption {
                                                type = types.str;
                                                description = "Name is the name of the secret.";
                                              };
                                              namespace = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Namespace is the namespace in which the secret exists. Context of use
                                                  determines the default value if left out (e.g., "default").
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          Secret is the secret that contains the certificates and private key for
                                          the TLS context.
                                          By default, Cilium will search in this secret for the following items:
                                           - 'ca.crt'  - Which represents the trusted CA to verify remote source.
                                           - 'tls.crt' - Which represents the public key certificate.
                                           - 'tls.key' - Which represents the private key matching the public key
                                                         certificate.
                                        '';
                                      };
                                      trustedCA = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          TrustedCA is the file name or k8s secret item name for the trusted CA.
                                          If omitted, 'ca.crt' is assumed, if it exists. If given, the item must
                                          exist.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  TerminatingTLS is the TLS context for the connection terminated by
                                  the L7 proxy.  For egress policy this specifies the server-side TLS
                                  parameters to be applied on the connections originated from the local
                                  endpoint and terminated by the L7 proxy. For ingress policy this specifies
                                  the server-side TLS parameters to be applied on the connections
                                  originated from a remote source and terminated by the L7 proxy.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToPorts is a list of destination ports identified by port number and
                        protocol which the endpoint subject to the rule is allowed to
                        connect to.

                        Example:
                        Any endpoint with the label "role=frontend" is allowed to initiate
                        connections to destination port 8080/tcp
                      '';
                    };
                    toRequires = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToRequires is a list of additional constraints which must be met
                        in order for the selected endpoints to be able to connect to other
                        endpoints. These additional constraints do no by itself grant access
                        privileges and must always be accompanied with at least one matching
                        ToEndpoints.

                        Example:
                        Any Endpoint with the label "team=A" requires any endpoint to which it
                        communicates to also carry the label "team=A".
                      '';
                    };
                    toServices = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              k8sService = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      namespace = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      serviceName = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "K8sService selects service by name and namespace pair";
                              };
                              k8sServiceSelector = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      namespace = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      selector = mkOption {
                                        type = (
                                          mkTypedSubmodule {
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
                                                          type = (
                                                            types.enum [
                                                              "In"
                                                              "NotIn"
                                                              "Exists"
                                                              "DoesNotExist"
                                                            ]
                                                          );
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
                                          }
                                        );
                                        description = "ServiceSelector is a label selector for k8s services";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "K8sServiceSelector selects services by k8s labels and namespace";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToServices is a list of services to which the endpoint subject
                        to the rule is allowed to initiate connections.
                        Currently Cilium only supports toServices for K8s services.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Egress is a list of EgressRule which are enforced at egress.
              If omitted or empty, this rule does not apply at egress.
            '';
          };
          egressDeny = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    icmps = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              fields = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        family = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "IPv4"
                                                "IPv6"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Family is a IP address version.
                                            Currently, we support `IPv4` and `IPv6`.
                                            `IPv4` is set as default.
                                          '';
                                        };
                                        type = mkOption {
                                          type = types.anything;
                                          description = ''
                                            Type is a ICMP-type.
                                            It should be an 8bit code (0-255), or it's CamelCase name (for example, "EchoReply").
                                            Allowed ICMP types are:
                                                Ipv4: EchoReply | DestinationUnreachable | Redirect | Echo | EchoRequest |
                                            		     RouterAdvertisement | RouterSelection | TimeExceeded | ParameterProblem |
                                            			 Timestamp | TimestampReply | Photuris | ExtendedEcho Request | ExtendedEcho Reply
                                                Ipv6: DestinationUnreachable | PacketTooBig | TimeExceeded | ParameterProblem |
                                            			 EchoRequest | EchoReply | MulticastListenerQuery| MulticastListenerReport |
                                            			 MulticastListenerDone | RouterSolicitation | RouterAdvertisement | NeighborSolicitation |
                                            			 NeighborAdvertisement | RedirectMessage | RouterRenumbering | ICMPNodeInformationQuery |
                                            			 ICMPNodeInformationResponse | InverseNeighborDiscoverySolicitation | InverseNeighborDiscoveryAdvertisement |
                                            			 HomeAgentAddressDiscoveryRequest | HomeAgentAddressDiscoveryReply | MobilePrefixSolicitation |
                                            			 MobilePrefixAdvertisement | DuplicateAddressRequestCodeSuffix | DuplicateAddressConfirmationCodeSuffix |
                                            			 ExtendedEchoRequest | ExtendedEchoReply
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Fields is a list of ICMP fields.";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ICMPs is a list of ICMP rule identified by type number
                        which the endpoint subject to the rule is not allowed to connect to.

                        Example:
                        Any endpoint with the label "app=httpd" is not allowed to initiate
                        type 8 ICMP connections.
                      '';
                    };
                    toCIDR = mkOption {
                      type = (types.nullOr (types.listOf types.str));
                      default = null;
                      description = ''
                        ToCIDR is a list of IP blocks which the endpoint subject to the rule
                        is allowed to initiate connections. Only connections destined for
                        outside of the cluster and not targeting the host will be subject
                        to CIDR rules.  This will match on the destination IP address of
                        outgoing connections. Adding a prefix into ToCIDR or into ToCIDRSet
                        with no ExcludeCIDRs is equivalent. Overlaps are allowed between
                        ToCIDR and ToCIDRSet.

                        Example:
                        Any endpoint with the label "app=database-proxy" is allowed to
                        initiate connections to 10.2.3.0/24
                      '';
                    };
                    toCIDRSet = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              cidr = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = "CIDR is a CIDR prefix / IP Block.";
                              };
                              cidrGroupRef = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  CIDRGroupRef is a reference to a CiliumCIDRGroup object.
                                  A CiliumCIDRGroup contains a list of CIDRs that the endpoint, subject to
                                  the rule, can (Ingress/Egress) or cannot (IngressDeny/EgressDeny) receive
                                  connections from.
                                '';
                              };
                              cidrGroupSelector = mkOption {
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
                                                  type = (
                                                    types.enum [
                                                      "In"
                                                      "NotIn"
                                                      "Exists"
                                                      "DoesNotExist"
                                                    ]
                                                  );
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
                                  CIDRGroupSelector selects CiliumCIDRGroups by their labels,
                                  rather than by name.
                                '';
                              };
                              except = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ExceptCIDRs is a list of IP blocks which the endpoint subject to the rule
                                  is not allowed to initiate connections to. These CIDR prefixes should be
                                  contained within Cidr, using ExceptCIDRs together with CIDRGroupRef is not
                                  supported yet.
                                  These exceptions are only applied to the Cidr in this CIDRRule, and do not
                                  apply to any other CIDR prefixes in any other CIDRRules.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToCIDRSet is a list of IP blocks which the endpoint subject to the rule
                        is allowed to initiate connections to in addition to connections
                        which are allowed via ToEndpoints, along with a list of subnets contained
                        within their corresponding IP block to which traffic should not be
                        allowed. This will match on the destination IP address of outgoing
                        connections. Adding a prefix into ToCIDR or into ToCIDRSet with no
                        ExcludeCIDRs is equivalent. Overlaps are allowed between ToCIDR and
                        ToCIDRSet.

                        Example:
                        Any endpoint with the label "app=database-proxy" is allowed to
                        initiate connections to 10.2.3.0/24 except from IPs in subnet 10.2.3.0/28.
                      '';
                    };
                    toEndpoints = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToEndpoints is a list of endpoints identified by an EndpointSelector to
                        which the endpoints subject to the rule are allowed to communicate.

                        Example:
                        Any endpoint with the label "role=frontend" can communicate with any
                        endpoint carrying the label "role=backend".
                      '';
                    };
                    toEntities = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (
                            types.enum [
                              "all"
                              "world"
                              "cluster"
                              "host"
                              "init"
                              "ingress"
                              "unmanaged"
                              "remote-node"
                              "health"
                              "none"
                              "kube-apiserver"
                            ]
                          )
                        )
                      );
                      default = null;
                      description = ''
                        ToEntities is a list of special entities to which the endpoint subject
                        to the rule is allowed to initiate connections. Supported entities are
                        `world`, `cluster`,`host`,`remote-node`,`kube-apiserver`, `init`,
                        `health`,`unmanaged` and `all`.
                      '';
                    };
                    toGroups = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              aws = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      labels = mkOption {
                                        type = (types.nullOr (types.attrsOf types.str));
                                        default = null;
                                      };
                                      region = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      securityGroupsIds = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                      securityGroupsNames = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "AWSGroup is an structure that can be used to whitelisting information from AWS integration";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToGroups is a directive that allows the integration with multiple outside
                        providers. Currently, only AWS is supported, and the rule can select by
                        multiple sub directives:

                        Example:
                        toGroups:
                        - aws:
                            securityGroupsIds:
                            - 'sg-XXXXXXXXXXXXX'
                      '';
                    };
                    toNodes = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToNodes is a list of nodes identified by an
                        EndpointSelector to which endpoints subject to the rule is allowed to communicate.
                      '';
                    };
                    toPorts = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              ports = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        endPort = mkOption {
                                          type = (types.nullOr types.int);
                                          default = null;
                                          description = "EndPort can only be an L4 port number.";
                                        };
                                        port = mkOption {
                                          type = types.str;
                                          description = ''
                                            Port can be an L4 port number, or a name in the form of "http"
                                            or "http-8080".
                                          '';
                                        };
                                        protocol = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "TCP"
                                                "UDP"
                                                "SCTP"
                                                "ANY"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Protocol is the L4 protocol. If omitted or empty, any protocol
                                            matches. Accepted values: "TCP", "UDP", "SCTP", "ANY"

                                            Matching on ICMP is not supported.

                                            Named port specified for a container may narrow this down, but may not
                                            contradict this.
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Ports is a list of L4 port/protocol";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToPorts is a list of destination ports identified by port number and
                        protocol which the endpoint subject to the rule is not allowed to connect
                        to.

                        Example:
                        Any endpoint with the label "role=frontend" is not allowed to initiate
                        connections to destination port 8080/tcp
                      '';
                    };
                    toRequires = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToRequires is a list of additional constraints which must be met
                        in order for the selected endpoints to be able to connect to other
                        endpoints. These additional constraints do no by itself grant access
                        privileges and must always be accompanied with at least one matching
                        ToEndpoints.

                        Example:
                        Any Endpoint with the label "team=A" requires any endpoint to which it
                        communicates to also carry the label "team=A".
                      '';
                    };
                    toServices = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              k8sService = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      namespace = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      serviceName = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "K8sService selects service by name and namespace pair";
                              };
                              k8sServiceSelector = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      namespace = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      selector = mkOption {
                                        type = (
                                          mkTypedSubmodule {
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
                                                          type = (
                                                            types.enum [
                                                              "In"
                                                              "NotIn"
                                                              "Exists"
                                                              "DoesNotExist"
                                                            ]
                                                          );
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
                                          }
                                        );
                                        description = "ServiceSelector is a label selector for k8s services";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "K8sServiceSelector selects services by k8s labels and namespace";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToServices is a list of services to which the endpoint subject
                        to the rule is allowed to initiate connections.
                        Currently Cilium only supports toServices for K8s services.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              EgressDeny is a list of EgressDenyRule which are enforced at egress.
              Any rule inserted here will be denied regardless of the allowed egress
              rules in the 'egress' field.
              If omitted or empty, this rule does not apply at egress.
            '';
          };
          enableDefaultDeny = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  egress = mkOption {
                    type = (types.nullOr types.bool);
                    default = null;
                    description = ''
                      Whether or not the endpoint should have a default-deny rule applied
                      to egress traffic.
                    '';
                  };
                  ingress = mkOption {
                    type = (types.nullOr types.bool);
                    default = null;
                    description = ''
                      Whether or not the endpoint should have a default-deny rule applied
                      to ingress traffic.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              EnableDefaultDeny determines whether this policy configures the
              subject endpoint(s) to have a default deny mode. If enabled,
              this causes all traffic not explicitly allowed by a network policy
              to be dropped.

              If not specified, the default is true for each traffic direction
              that has rules, and false otherwise. For example, if a policy
              only has Ingress or IngressDeny rules, then the default for
              ingress is true and egress is false.

              If multiple policies apply to an endpoint, that endpoint's default deny
              will be enabled if any policy requests it.

              This is useful for creating broad-based network policies that will not
              cause endpoints to enter default-deny mode.
            '';
          };
          endpointSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
              EndpointSelector selects all endpoints which should be subject to
              this rule. EndpointSelector and NodeSelector cannot be both empty and
              are mutually exclusive.
            '';
          };
          ingress = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    authentication = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            mode = mkOption {
                              type = (
                                types.enum [
                                  "disabled"
                                  "required"
                                  "test-always-fail"
                                ]
                              );
                              description = "Mode is the required authentication mode for the allowed traffic, if any.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "Authentication is the required authentication type for the allowed traffic, if any.";
                    };
                    fromCIDR = mkOption {
                      type = (types.nullOr (types.listOf types.str));
                      default = null;
                      description = ''
                        FromCIDR is a list of IP blocks which the endpoint subject to the
                        rule is allowed to receive connections from. Only connections which
                        do *not* originate from the cluster or from the local host are subject
                        to CIDR rules. In order to allow in-cluster connectivity, use the
                        FromEndpoints field.  This will match on the source IP address of
                        incoming connections. Adding  a prefix into FromCIDR or into
                        FromCIDRSet with no ExcludeCIDRs is  equivalent.  Overlaps are
                        allowed between FromCIDR and FromCIDRSet.

                        Example:
                        Any endpoint with the label "app=my-legacy-pet" is allowed to receive
                        connections from 10.3.9.1
                      '';
                    };
                    fromCIDRSet = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              cidr = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = "CIDR is a CIDR prefix / IP Block.";
                              };
                              cidrGroupRef = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  CIDRGroupRef is a reference to a CiliumCIDRGroup object.
                                  A CiliumCIDRGroup contains a list of CIDRs that the endpoint, subject to
                                  the rule, can (Ingress/Egress) or cannot (IngressDeny/EgressDeny) receive
                                  connections from.
                                '';
                              };
                              cidrGroupSelector = mkOption {
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
                                                  type = (
                                                    types.enum [
                                                      "In"
                                                      "NotIn"
                                                      "Exists"
                                                      "DoesNotExist"
                                                    ]
                                                  );
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
                                  CIDRGroupSelector selects CiliumCIDRGroups by their labels,
                                  rather than by name.
                                '';
                              };
                              except = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ExceptCIDRs is a list of IP blocks which the endpoint subject to the rule
                                  is not allowed to initiate connections to. These CIDR prefixes should be
                                  contained within Cidr, using ExceptCIDRs together with CIDRGroupRef is not
                                  supported yet.
                                  These exceptions are only applied to the Cidr in this CIDRRule, and do not
                                  apply to any other CIDR prefixes in any other CIDRRules.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        FromCIDRSet is a list of IP blocks which the endpoint subject to the
                        rule is allowed to receive connections from in addition to FromEndpoints,
                        along with a list of subnets contained within their corresponding IP block
                        from which traffic should not be allowed.
                        This will match on the source IP address of incoming connections. Adding
                        a prefix into FromCIDR or into FromCIDRSet with no ExcludeCIDRs is
                        equivalent. Overlaps are allowed between FromCIDR and FromCIDRSet.

                        Example:
                        Any endpoint with the label "app=my-legacy-pet" is allowed to receive
                        connections from 10.0.0.0/8 except from IPs in subnet 10.96.0.0/12.
                      '';
                    };
                    fromEndpoints = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromEndpoints is a list of endpoints identified by an
                        EndpointSelector which are allowed to communicate with the endpoint
                        subject to the rule.

                        Example:
                        Any endpoint with the label "role=backend" can be consumed by any
                        endpoint carrying the label "role=frontend".
                      '';
                    };
                    fromEntities = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (
                            types.enum [
                              "all"
                              "world"
                              "cluster"
                              "host"
                              "init"
                              "ingress"
                              "unmanaged"
                              "remote-node"
                              "health"
                              "none"
                              "kube-apiserver"
                            ]
                          )
                        )
                      );
                      default = null;
                      description = ''
                        FromEntities is a list of special entities which the endpoint subject
                        to the rule is allowed to receive connections from. Supported entities are
                        `world`, `cluster` and `host`
                      '';
                    };
                    fromGroups = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              aws = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      labels = mkOption {
                                        type = (types.nullOr (types.attrsOf types.str));
                                        default = null;
                                      };
                                      region = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      securityGroupsIds = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                      securityGroupsNames = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "AWSGroup is an structure that can be used to whitelisting information from AWS integration";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        FromGroups is a directive that allows the integration with multiple outside
                        providers. Currently, only AWS is supported, and the rule can select by
                        multiple sub directives:

                        Example:
                        FromGroups:
                        - aws:
                            securityGroupsIds:
                            - 'sg-XXXXXXXXXXXXX'
                      '';
                    };
                    fromNodes = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromNodes is a list of nodes identified by an
                        EndpointSelector which are allowed to communicate with the endpoint
                        subject to the rule.
                      '';
                    };
                    fromRequires = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromRequires is a list of additional constraints which must be met
                        in order for the selected endpoints to be reachable. These
                        additional constraints do no by itself grant access privileges and
                        must always be accompanied with at least one matching FromEndpoints.

                        Example:
                        Any Endpoint with the label "team=A" requires consuming endpoint
                        to also carry the label "team=A".
                      '';
                    };
                    icmps = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              fields = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        family = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "IPv4"
                                                "IPv6"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Family is a IP address version.
                                            Currently, we support `IPv4` and `IPv6`.
                                            `IPv4` is set as default.
                                          '';
                                        };
                                        type = mkOption {
                                          type = types.anything;
                                          description = ''
                                            Type is a ICMP-type.
                                            It should be an 8bit code (0-255), or it's CamelCase name (for example, "EchoReply").
                                            Allowed ICMP types are:
                                                Ipv4: EchoReply | DestinationUnreachable | Redirect | Echo | EchoRequest |
                                            		     RouterAdvertisement | RouterSelection | TimeExceeded | ParameterProblem |
                                            			 Timestamp | TimestampReply | Photuris | ExtendedEcho Request | ExtendedEcho Reply
                                                Ipv6: DestinationUnreachable | PacketTooBig | TimeExceeded | ParameterProblem |
                                            			 EchoRequest | EchoReply | MulticastListenerQuery| MulticastListenerReport |
                                            			 MulticastListenerDone | RouterSolicitation | RouterAdvertisement | NeighborSolicitation |
                                            			 NeighborAdvertisement | RedirectMessage | RouterRenumbering | ICMPNodeInformationQuery |
                                            			 ICMPNodeInformationResponse | InverseNeighborDiscoverySolicitation | InverseNeighborDiscoveryAdvertisement |
                                            			 HomeAgentAddressDiscoveryRequest | HomeAgentAddressDiscoveryReply | MobilePrefixSolicitation |
                                            			 MobilePrefixAdvertisement | DuplicateAddressRequestCodeSuffix | DuplicateAddressConfirmationCodeSuffix |
                                            			 ExtendedEchoRequest | ExtendedEchoReply
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Fields is a list of ICMP fields.";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ICMPs is a list of ICMP rule identified by type number
                        which the endpoint subject to the rule is allowed to
                        receive connections on.

                        Example:
                        Any endpoint with the label "app=httpd" can only accept incoming
                        type 8 ICMP connections.
                      '';
                    };
                    toPorts = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              listener = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      envoyConfig = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              kind = mkOption {
                                                type = (
                                                  types.nullOr (
                                                    types.enum [
                                                      "CiliumEnvoyConfig"
                                                      "CiliumClusterwideEnvoyConfig"
                                                    ]
                                                  )
                                                );
                                                default = null;
                                                description = ''
                                                  Kind is the resource type being referred to. Defaults to CiliumEnvoyConfig or
                                                  CiliumClusterwideEnvoyConfig for CiliumNetworkPolicy and CiliumClusterwideNetworkPolicy,
                                                  respectively. The only case this is currently explicitly needed is when referring to a
                                                  CiliumClusterwideEnvoyConfig from CiliumNetworkPolicy, as using a namespaced listener
                                                  from a cluster scoped policy is not allowed.
                                                '';
                                              };
                                              name = mkOption {
                                                type = types.str;
                                                description = ''
                                                  Name is the resource name of the CiliumEnvoyConfig or CiliumClusterwideEnvoyConfig where
                                                  the listener is defined in.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          EnvoyConfig is a reference to the CEC or CCEC resource in which
                                          the listener is defined.
                                        '';
                                      };
                                      name = mkOption {
                                        type = types.str;
                                        description = "Name is the name of the listener.";
                                      };
                                      priority = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          Priority for this Listener that is used when multiple rules would apply different
                                          listeners to a policy map entry. Behavior of this is implementation dependent.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  listener specifies the name of a custom Envoy listener to which this traffic should be
                                  redirected to.
                                '';
                              };
                              originatingTLS = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      certificate = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Certificate is the file name or k8s secret item name for the certificate
                                          chain. If omitted, 'tls.crt' is assumed, if it exists. If given, the
                                          item must exist.
                                        '';
                                      };
                                      privateKey = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          PrivateKey is the file name or k8s secret item name for the private key
                                          matching the certificate chain. If omitted, 'tls.key' is assumed, if it
                                          exists. If given, the item must exist.
                                        '';
                                      };
                                      secret = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              name = mkOption {
                                                type = types.str;
                                                description = "Name is the name of the secret.";
                                              };
                                              namespace = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Namespace is the namespace in which the secret exists. Context of use
                                                  determines the default value if left out (e.g., "default").
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          Secret is the secret that contains the certificates and private key for
                                          the TLS context.
                                          By default, Cilium will search in this secret for the following items:
                                           - 'ca.crt'  - Which represents the trusted CA to verify remote source.
                                           - 'tls.crt' - Which represents the public key certificate.
                                           - 'tls.key' - Which represents the private key matching the public key
                                                         certificate.
                                        '';
                                      };
                                      trustedCA = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          TrustedCA is the file name or k8s secret item name for the trusted CA.
                                          If omitted, 'ca.crt' is assumed, if it exists. If given, the item must
                                          exist.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  OriginatingTLS is the TLS context for the connections originated by
                                  the L7 proxy.  For egress policy this specifies the client-side TLS
                                  parameters for the upstream connection originating from the L7 proxy
                                  to the remote destination. For ingress policy this specifies the
                                  client-side TLS parameters for the connection from the L7 proxy to
                                  the local endpoint.
                                '';
                              };
                              ports = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        endPort = mkOption {
                                          type = (types.nullOr types.int);
                                          default = null;
                                          description = "EndPort can only be an L4 port number.";
                                        };
                                        port = mkOption {
                                          type = types.str;
                                          description = ''
                                            Port can be an L4 port number, or a name in the form of "http"
                                            or "http-8080".
                                          '';
                                        };
                                        protocol = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "TCP"
                                                "UDP"
                                                "SCTP"
                                                "ANY"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Protocol is the L4 protocol. If omitted or empty, any protocol
                                            matches. Accepted values: "TCP", "UDP", "SCTP", "ANY"

                                            Matching on ICMP is not supported.

                                            Named port specified for a container may narrow this down, but may not
                                            contradict this.
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Ports is a list of L4 port/protocol";
                              };
                              rules = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      dns = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                matchName = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    MatchName matches literal DNS names. A trailing "." is automatically added
                                                    when missing.
                                                  '';
                                                };
                                                matchPattern = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    MatchPattern allows using wildcards to match DNS names. All wildcards are
                                                    case insensitive. The wildcards are:
                                                    - "*" matches 0 or more DNS valid characters, and may occur anywhere in
                                                    the pattern. As a special case a "*" as the leftmost character, without a
                                                    following "." matches all subdomains as well as the name to the right.
                                                    A trailing "." is automatically added when missing.

                                                    Examples:
                                                    `*.cilium.io` matches subomains of cilium at that level
                                                      www.cilium.io and blog.cilium.io match, cilium.io and google.com do not
                                                    `*cilium.io` matches cilium.io and all subdomains ends with "cilium.io"
                                                      except those containing "." separator, subcilium.io and sub-cilium.io match,
                                                      www.cilium.io and blog.cilium.io does not
                                                    sub*.cilium.io matches subdomains of cilium where the subdomain component
                                                    begins with "sub"
                                                      sub.cilium.io and subdomain.cilium.io match, www.cilium.io,
                                                      blog.cilium.io, cilium.io and google.com do not
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "DNS-specific rules.";
                                      };
                                      http = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                headerMatches = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          mismatch = mkOption {
                                                            type = (
                                                              types.nullOr (
                                                                types.enum [
                                                                  "LOG"
                                                                  "ADD"
                                                                  "DELETE"
                                                                  "REPLACE"
                                                                ]
                                                              )
                                                            );
                                                            default = null;
                                                            description = ''
                                                              Mismatch identifies what to do in case there is no match. The default is
                                                              to drop the request. Otherwise the overall rule is still considered as
                                                              matching, but the mismatches are logged in the access log.
                                                            '';
                                                          };
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = "Name identifies the header.";
                                                          };
                                                          secret = mkOption {
                                                            type = (
                                                              types.nullOr (mkTypedSubmodule {
                                                                options = {
                                                                  name = mkOption {
                                                                    type = types.str;
                                                                    description = "Name is the name of the secret.";
                                                                  };
                                                                  namespace = mkOption {
                                                                    type = (types.nullOr types.str);
                                                                    default = null;
                                                                    description = ''
                                                                      Namespace is the namespace in which the secret exists. Context of use
                                                                      determines the default value if left out (e.g., "default").
                                                                    '';
                                                                  };
                                                                };
                                                                freeformType = types.attrs;
                                                              })
                                                            );
                                                            default = null;
                                                            description = ''
                                                              Secret refers to a secret that contains the value to be matched against.
                                                              The secret must only contain one entry. If the referred secret does not
                                                              exist, and there is no "Value" specified, the match will fail.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = (types.nullOr types.str);
                                                            default = null;
                                                            description = ''
                                                              Value matches the exact value of the header. Can be specified either
                                                              alone or together with "Secret"; will be used as the header value if the
                                                              secret can not be found in the latter case.
                                                            '';
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    HeaderMatches is a list of HTTP headers which must be
                                                    present and match against the given values. Mismatch field can be used
                                                    to specify what to do when there is no match.
                                                  '';
                                                };
                                                headers = mkOption {
                                                  type = (types.nullOr (types.listOf types.str));
                                                  default = null;
                                                  description = ''
                                                    Headers is a list of HTTP headers which must be present in the
                                                    request. If omitted or empty, requests are allowed regardless of
                                                    headers present.
                                                  '';
                                                };
                                                host = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Host is an extended POSIX regex matched against the host header of a
                                                    request. Examples:

                                                    - foo.bar.com will match the host fooXbar.com or foo-bar.com
                                                    - foo\.bar\.com will only match the host foo.bar.com

                                                    If omitted or empty, the value of the host header is ignored.
                                                  '';
                                                };
                                                method = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Method is an extended POSIX regex matched against the method of a
                                                    request, e.g. "GET", "POST", "PUT", "PATCH", "DELETE", ...

                                                    If omitted or empty, all methods are allowed.
                                                  '';
                                                };
                                                path = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Path is an extended POSIX regex matched against the path of a
                                                    request. Currently it can contain characters disallowed from the
                                                    conventional "path" part of a URL as defined by RFC 3986.

                                                    If omitted or empty, all paths are all allowed.
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "HTTP specific rules.";
                                      };
                                      kafka = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                apiKey = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    APIKey is a case-insensitive string matched against the key of a
                                                    request, e.g. "produce", "fetch", "createtopic", "deletetopic", et al
                                                    Reference: https://kafka.apache.org/protocol#protocol_api_keys

                                                    If omitted or empty, and if Role is not specified, then all keys are allowed.
                                                  '';
                                                };
                                                apiVersion = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    APIVersion is the version matched against the api version of the
                                                    Kafka message. If set, it has to be a string representing a positive
                                                    integer.

                                                    If omitted or empty, all versions are allowed.
                                                  '';
                                                };
                                                clientID = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    ClientID is the client identifier as provided in the request.

                                                    From Kafka protocol documentation:
                                                    This is a user supplied identifier for the client application. The
                                                    user can use any identifier they like and it will be used when
                                                    logging errors, monitoring aggregates, etc. For example, one might
                                                    want to monitor not just the requests per second overall, but the
                                                    number coming from each client application (each of which could
                                                    reside on multiple servers). This id acts as a logical grouping
                                                    across all requests from a particular client.

                                                    If omitted or empty, all client identifiers are allowed.
                                                  '';
                                                };
                                                role = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.enum [
                                                        "produce"
                                                        "consume"
                                                      ]
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Role is a case-insensitive string and describes a group of API keys
                                                    necessary to perform certain higher-level Kafka operations such as "produce"
                                                    or "consume". A Role automatically expands into all APIKeys required
                                                    to perform the specified higher-level operation.

                                                    The following values are supported:
                                                     - "produce": Allow producing to the topics specified in the rule
                                                     - "consume": Allow consuming from the topics specified in the rule

                                                    This field is incompatible with the APIKey field, i.e APIKey and Role
                                                    cannot both be specified in the same rule.

                                                    If omitted or empty, and if APIKey is not specified, then all keys are
                                                    allowed.
                                                  '';
                                                };
                                                topic = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Topic is the topic name contained in the message. If a Kafka request
                                                    contains multiple topics, then all topics must be allowed or the
                                                    message will be rejected.

                                                    This constraint is ignored if the matched request message type
                                                    doesn't contain any topic. Maximum size of Topic can be 249
                                                    characters as per recent Kafka spec and allowed characters are
                                                    a-z, A-Z, 0-9, -, . and _.

                                                    Older Kafka versions had longer topic lengths of 255, but in Kafka 0.10
                                                    version the length was changed from 255 to 249. For compatibility
                                                    reasons we are using 255.

                                                    If omitted or empty, all topics are allowed.
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "Kafka-specific rules.";
                                      };
                                      l7 = mkOption {
                                        type = (types.nullOr (types.listOf (types.attrsOf types.str)));
                                        default = null;
                                        description = "Key-value pair rules.";
                                      };
                                      l7proto = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = "Name of the L7 protocol for which the Key-value pair rules apply.";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  Rules is a list of additional port level rules which must be met in
                                  order for the PortRule to allow the traffic. If omitted or empty,
                                  no layer 7 rules are enforced.
                                '';
                              };
                              serverNames = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ServerNames is a list of allowed TLS SNI values. If not empty, then
                                  TLS must be present and one of the provided SNIs must be indicated in the
                                  TLS handshake.
                                '';
                              };
                              terminatingTLS = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      certificate = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Certificate is the file name or k8s secret item name for the certificate
                                          chain. If omitted, 'tls.crt' is assumed, if it exists. If given, the
                                          item must exist.
                                        '';
                                      };
                                      privateKey = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          PrivateKey is the file name or k8s secret item name for the private key
                                          matching the certificate chain. If omitted, 'tls.key' is assumed, if it
                                          exists. If given, the item must exist.
                                        '';
                                      };
                                      secret = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              name = mkOption {
                                                type = types.str;
                                                description = "Name is the name of the secret.";
                                              };
                                              namespace = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Namespace is the namespace in which the secret exists. Context of use
                                                  determines the default value if left out (e.g., "default").
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          Secret is the secret that contains the certificates and private key for
                                          the TLS context.
                                          By default, Cilium will search in this secret for the following items:
                                           - 'ca.crt'  - Which represents the trusted CA to verify remote source.
                                           - 'tls.crt' - Which represents the public key certificate.
                                           - 'tls.key' - Which represents the private key matching the public key
                                                         certificate.
                                        '';
                                      };
                                      trustedCA = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          TrustedCA is the file name or k8s secret item name for the trusted CA.
                                          If omitted, 'ca.crt' is assumed, if it exists. If given, the item must
                                          exist.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  TerminatingTLS is the TLS context for the connection terminated by
                                  the L7 proxy.  For egress policy this specifies the server-side TLS
                                  parameters to be applied on the connections originated from the local
                                  endpoint and terminated by the L7 proxy. For ingress policy this specifies
                                  the server-side TLS parameters to be applied on the connections
                                  originated from a remote source and terminated by the L7 proxy.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToPorts is a list of destination ports identified by port number and
                        protocol which the endpoint subject to the rule is allowed to
                        receive connections on.

                        Example:
                        Any endpoint with the label "app=httpd" can only accept incoming
                        connections on port 80/tcp.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Ingress is a list of IngressRule which are enforced at ingress.
              If omitted or empty, this rule does not apply at ingress.
            '';
          };
          ingressDeny = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    fromCIDR = mkOption {
                      type = (types.nullOr (types.listOf types.str));
                      default = null;
                      description = ''
                        FromCIDR is a list of IP blocks which the endpoint subject to the
                        rule is allowed to receive connections from. Only connections which
                        do *not* originate from the cluster or from the local host are subject
                        to CIDR rules. In order to allow in-cluster connectivity, use the
                        FromEndpoints field.  This will match on the source IP address of
                        incoming connections. Adding  a prefix into FromCIDR or into
                        FromCIDRSet with no ExcludeCIDRs is  equivalent.  Overlaps are
                        allowed between FromCIDR and FromCIDRSet.

                        Example:
                        Any endpoint with the label "app=my-legacy-pet" is allowed to receive
                        connections from 10.3.9.1
                      '';
                    };
                    fromCIDRSet = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              cidr = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = "CIDR is a CIDR prefix / IP Block.";
                              };
                              cidrGroupRef = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  CIDRGroupRef is a reference to a CiliumCIDRGroup object.
                                  A CiliumCIDRGroup contains a list of CIDRs that the endpoint, subject to
                                  the rule, can (Ingress/Egress) or cannot (IngressDeny/EgressDeny) receive
                                  connections from.
                                '';
                              };
                              cidrGroupSelector = mkOption {
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
                                                  type = (
                                                    types.enum [
                                                      "In"
                                                      "NotIn"
                                                      "Exists"
                                                      "DoesNotExist"
                                                    ]
                                                  );
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
                                  CIDRGroupSelector selects CiliumCIDRGroups by their labels,
                                  rather than by name.
                                '';
                              };
                              except = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ExceptCIDRs is a list of IP blocks which the endpoint subject to the rule
                                  is not allowed to initiate connections to. These CIDR prefixes should be
                                  contained within Cidr, using ExceptCIDRs together with CIDRGroupRef is not
                                  supported yet.
                                  These exceptions are only applied to the Cidr in this CIDRRule, and do not
                                  apply to any other CIDR prefixes in any other CIDRRules.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        FromCIDRSet is a list of IP blocks which the endpoint subject to the
                        rule is allowed to receive connections from in addition to FromEndpoints,
                        along with a list of subnets contained within their corresponding IP block
                        from which traffic should not be allowed.
                        This will match on the source IP address of incoming connections. Adding
                        a prefix into FromCIDR or into FromCIDRSet with no ExcludeCIDRs is
                        equivalent. Overlaps are allowed between FromCIDR and FromCIDRSet.

                        Example:
                        Any endpoint with the label "app=my-legacy-pet" is allowed to receive
                        connections from 10.0.0.0/8 except from IPs in subnet 10.96.0.0/12.
                      '';
                    };
                    fromEndpoints = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromEndpoints is a list of endpoints identified by an
                        EndpointSelector which are allowed to communicate with the endpoint
                        subject to the rule.

                        Example:
                        Any endpoint with the label "role=backend" can be consumed by any
                        endpoint carrying the label "role=frontend".
                      '';
                    };
                    fromEntities = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (
                            types.enum [
                              "all"
                              "world"
                              "cluster"
                              "host"
                              "init"
                              "ingress"
                              "unmanaged"
                              "remote-node"
                              "health"
                              "none"
                              "kube-apiserver"
                            ]
                          )
                        )
                      );
                      default = null;
                      description = ''
                        FromEntities is a list of special entities which the endpoint subject
                        to the rule is allowed to receive connections from. Supported entities are
                        `world`, `cluster` and `host`
                      '';
                    };
                    fromGroups = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              aws = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      labels = mkOption {
                                        type = (types.nullOr (types.attrsOf types.str));
                                        default = null;
                                      };
                                      region = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      securityGroupsIds = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                      securityGroupsNames = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "AWSGroup is an structure that can be used to whitelisting information from AWS integration";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        FromGroups is a directive that allows the integration with multiple outside
                        providers. Currently, only AWS is supported, and the rule can select by
                        multiple sub directives:

                        Example:
                        FromGroups:
                        - aws:
                            securityGroupsIds:
                            - 'sg-XXXXXXXXXXXXX'
                      '';
                    };
                    fromNodes = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromNodes is a list of nodes identified by an
                        EndpointSelector which are allowed to communicate with the endpoint
                        subject to the rule.
                      '';
                    };
                    fromRequires = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromRequires is a list of additional constraints which must be met
                        in order for the selected endpoints to be reachable. These
                        additional constraints do no by itself grant access privileges and
                        must always be accompanied with at least one matching FromEndpoints.

                        Example:
                        Any Endpoint with the label "team=A" requires consuming endpoint
                        to also carry the label "team=A".
                      '';
                    };
                    icmps = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              fields = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        family = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "IPv4"
                                                "IPv6"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Family is a IP address version.
                                            Currently, we support `IPv4` and `IPv6`.
                                            `IPv4` is set as default.
                                          '';
                                        };
                                        type = mkOption {
                                          type = types.anything;
                                          description = ''
                                            Type is a ICMP-type.
                                            It should be an 8bit code (0-255), or it's CamelCase name (for example, "EchoReply").
                                            Allowed ICMP types are:
                                                Ipv4: EchoReply | DestinationUnreachable | Redirect | Echo | EchoRequest |
                                            		     RouterAdvertisement | RouterSelection | TimeExceeded | ParameterProblem |
                                            			 Timestamp | TimestampReply | Photuris | ExtendedEcho Request | ExtendedEcho Reply
                                                Ipv6: DestinationUnreachable | PacketTooBig | TimeExceeded | ParameterProblem |
                                            			 EchoRequest | EchoReply | MulticastListenerQuery| MulticastListenerReport |
                                            			 MulticastListenerDone | RouterSolicitation | RouterAdvertisement | NeighborSolicitation |
                                            			 NeighborAdvertisement | RedirectMessage | RouterRenumbering | ICMPNodeInformationQuery |
                                            			 ICMPNodeInformationResponse | InverseNeighborDiscoverySolicitation | InverseNeighborDiscoveryAdvertisement |
                                            			 HomeAgentAddressDiscoveryRequest | HomeAgentAddressDiscoveryReply | MobilePrefixSolicitation |
                                            			 MobilePrefixAdvertisement | DuplicateAddressRequestCodeSuffix | DuplicateAddressConfirmationCodeSuffix |
                                            			 ExtendedEchoRequest | ExtendedEchoReply
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Fields is a list of ICMP fields.";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ICMPs is a list of ICMP rule identified by type number
                        which the endpoint subject to the rule is not allowed to
                        receive connections on.

                        Example:
                        Any endpoint with the label "app=httpd" can not accept incoming
                        type 8 ICMP connections.
                      '';
                    };
                    toPorts = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              ports = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        endPort = mkOption {
                                          type = (types.nullOr types.int);
                                          default = null;
                                          description = "EndPort can only be an L4 port number.";
                                        };
                                        port = mkOption {
                                          type = types.str;
                                          description = ''
                                            Port can be an L4 port number, or a name in the form of "http"
                                            or "http-8080".
                                          '';
                                        };
                                        protocol = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "TCP"
                                                "UDP"
                                                "SCTP"
                                                "ANY"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Protocol is the L4 protocol. If omitted or empty, any protocol
                                            matches. Accepted values: "TCP", "UDP", "SCTP", "ANY"

                                            Matching on ICMP is not supported.

                                            Named port specified for a container may narrow this down, but may not
                                            contradict this.
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Ports is a list of L4 port/protocol";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToPorts is a list of destination ports identified by port number and
                        protocol which the endpoint subject to the rule is not allowed to
                        receive connections on.

                        Example:
                        Any endpoint with the label "app=httpd" can not accept incoming
                        connections on port 80/tcp.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              IngressDeny is a list of IngressDenyRule which are enforced at ingress.
              Any rule inserted here will be denied regardless of the allowed ingress
              rules in the 'ingress' field.
              If omitted or empty, this rule does not apply at ingress.
            '';
          };
          labels = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    key = mkOption {
                      type = types.str;
                    };
                    source = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "Source can be one of the above values (e.g.: LabelSourceContainer).";
                    };
                    value = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Labels is a list of optional strings which can be used to
              re-identify the rule or to store metadata. It is possible to lookup
              or delete strings based on labels. Labels are not required to be
              unique, multiple rules can have overlapping or identical labels.
            '';
          };
          nodeSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
              NodeSelector selects all nodes which should be subject to this rule.
              EndpointSelector and NodeSelector cannot be both empty and are mutually
              exclusive. Can only be used in CiliumClusterwideNetworkPolicies.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumEgressGatewayPolicy = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumEgressGatewayPolicy";
    specType = (
      mkTypedSubmodule {
        options = {
          destinationCIDRs = mkOption {
            type = (types.listOf types.str);
            description = ''
              DestinationCIDRs is a list of destination CIDRs for destination IP addresses.
              If a destination IP matches any one CIDR, it will be selected.
            '';
          };
          egressGateway = mkOption {
            type = (
              mkTypedSubmodule {
                options = {
                  egressIP = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      EgressIP is the source IP address that the egress traffic is SNATed
                      with.

                      Example:
                      When set to "192.168.1.100", matching egress traffic will be
                      redirected to the node matching the NodeSelector field and SNATed
                      with IP address 192.168.1.100.

                      When none of the Interface or EgressIP fields is specified, the
                      policy will use the first IPv4 assigned to the interface with the
                      default route.
                    '';
                  };
                  interface = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      Interface is the network interface to which the egress IP address
                      that the traffic is SNATed with is assigned.

                      Example:
                      When set to "eth1", matching egress traffic will be redirected to the
                      node matching the NodeSelector field and SNATed with the first IPv4
                      address assigned to the eth1 interface.

                      When none of the Interface or EgressIP fields is specified, the
                      policy will use the first IPv4 assigned to the interface with the
                      default route.
                    '';
                  };
                  nodeSelector = mkOption {
                    type = (
                      mkTypedSubmodule {
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
                                      type = (
                                        types.enum [
                                          "In"
                                          "NotIn"
                                          "Exists"
                                          "DoesNotExist"
                                        ]
                                      );
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
                      }
                    );
                    description = ''
                      This is a label selector which selects the node that should act as
                      egress gateway for the given policy.
                      In case multiple nodes are selected, only the first one in the
                      lexical ordering over the node names will be used.
                      This field follows standard label selector semantics.
                    '';
                  };
                };
                freeformType = types.attrs;
              }
            );
            description = "EgressGateway is the gateway node responsible for SNATing traffic.";
          };
          excludedCIDRs = mkOption {
            type = (types.nullOr (types.listOf types.str));
            default = null;
            description = ''
              ExcludedCIDRs is a list of destination CIDRs that will be excluded
              from the egress gateway redirection and SNAT logic.
              Should be a subset of destinationCIDRs otherwise it will not have any
              effect.
            '';
          };
          selectors = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
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
                                      type = (
                                        types.enum [
                                          "In"
                                          "NotIn"
                                          "Exists"
                                          "DoesNotExist"
                                        ]
                                      );
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
                      Selects Namespaces using cluster-scoped labels. This field follows standard label
                      selector semantics; if present but empty, it selects all namespaces.
                    '';
                  };
                  nodeSelector = mkOption {
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
                                      type = (
                                        types.enum [
                                          "In"
                                          "NotIn"
                                          "Exists"
                                          "DoesNotExist"
                                        ]
                                      );
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
                      This is a label selector which selects Pods by Node. This field follows standard label
                      selector semantics; if present but empty, it selects all nodes.
                    '';
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
                                      type = (
                                        types.enum [
                                          "In"
                                          "NotIn"
                                          "Exists"
                                          "DoesNotExist"
                                        ]
                                      );
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
                      This is a label selector which selects Pods. This field follows standard label
                      selector semantics; if present but empty, it selects all pods.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              Egress represents a list of rules by which egress traffic is
              filtered from the source pods.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumEndpoint = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumEndpoint";
    specType = types.attrs;
  };

  CiliumEnvoyConfig = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumEnvoyConfig";
    specType = (
      mkTypedSubmodule {
        options = {
          backendServices = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      description = ''
                        Name is the name of a destination Kubernetes service that identifies traffic
                        to be redirected.
                      '';
                    };
                    namespace = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Namespace is the Kubernetes service namespace.
                        In CiliumEnvoyConfig namespace defaults to the namespace of the CEC,
                        In CiliumClusterwideEnvoyConfig namespace defaults to "default".
                      '';
                    };
                    number = mkOption {
                      type = (types.nullOr (types.listOf types.str));
                      default = null;
                      description = ''
                        Ports is a set of port numbers, which can be used for filtering in case of underlying
                        is exposing multiple port numbers.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              BackendServices specifies Kubernetes services whose backends
              are automatically synced to Envoy using EDS.  Traffic for these
              services is not forwarded to an Envoy listener. This allows an
              Envoy listener load balance traffic to these backends while
              normal Cilium service load balancing takes care of balancing
              traffic for these services at the same time.
            '';
          };
          nodeSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
              NodeSelector is a label selector that determines to which nodes
              this configuration applies.
              If nil, then this config applies to all nodes.
            '';
          };
          resources = mkOption {
            type = (types.listOf types.attrs);
            description = ''
              Envoy xDS resources, a list of the following Envoy resource types:
              type.googleapis.com/envoy.config.listener.v3.Listener,
              type.googleapis.com/envoy.config.route.v3.RouteConfiguration,
              type.googleapis.com/envoy.config.cluster.v3.Cluster,
              type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment, and
              type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret.
            '';
          };
          services = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    listener = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Listener specifies the name of the Envoy listener the
                        service traffic is redirected to. The listener must be
                        specified in the Envoy 'resources' of the same
                        CiliumEnvoyConfig.

                        If omitted, the first listener specified in 'resources' is
                        used.
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = ''
                        Name is the name of a destination Kubernetes service that identifies traffic
                        to be redirected.
                      '';
                    };
                    namespace = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Namespace is the Kubernetes service namespace.
                        In CiliumEnvoyConfig namespace this is overridden to the namespace of the CEC,
                        In CiliumClusterwideEnvoyConfig namespace defaults to "default".
                      '';
                    };
                    ports = mkOption {
                      type = (types.nullOr (types.listOf types.int));
                      default = null;
                      description = ''
                        Ports is a set of service's frontend ports that should be redirected to the Envoy
                        listener. By default all frontend ports of the service are redirected.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Services specifies Kubernetes services for which traffic is
              forwarded to an Envoy listener for L7 load balancing. Backends
              of these services are automatically synced to Envoy usign EDS.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumExternalWorkload = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumExternalWorkload";
    specType = (
      mkTypedSubmodule {
        options = {
          "ipv4-alloc-cidr" = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = ''
              IPv4AllocCIDR is the range of IPv4 addresses in the CIDR format that the external workload can
              use to allocate IP addresses for the tunnel device and the health endpoint.
            '';
          };
          "ipv6-alloc-cidr" = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = ''
              IPv6AllocCIDR is the range of IPv6 addresses in the CIDR format that the external workload can
              use to allocate IP addresses for the tunnel device and the health endpoint.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumIdentity = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumIdentity";
    specType = types.attrs;
  };

  CiliumLocalRedirectPolicy = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumLocalRedirectPolicy";
    specType = (
      mkTypedSubmodule {
        options = {
          description = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = ''
              Description can be used by the creator of the policy to describe the
              purpose of this policy.
            '';
          };
          redirectBackend = mkOption {
            type = (
              mkTypedSubmodule {
                options = {
                  localEndpointSelector = mkOption {
                    type = (
                      mkTypedSubmodule {
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
                                      type = (
                                        types.enum [
                                          "In"
                                          "NotIn"
                                          "Exists"
                                          "DoesNotExist"
                                        ]
                                      );
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
                      }
                    );
                    description = "LocalEndpointSelector selects node local pod(s) where traffic is redirected to.";
                  };
                  toPorts = mkOption {
                    type = (
                      types.listOf (mkTypedSubmodule {
                        options = {
                          name = mkOption {
                            type = (types.nullOr types.str);
                            default = null;
                            description = ''
                              Name is a port name, which must contain at least one [a-z],
                              and may also contain [0-9] and '-' anywhere except adjacent to another
                              '-' or in the beginning or the end.
                            '';
                          };
                          port = mkOption {
                            type = types.str;
                            description = "Port is an L4 port number. The string will be strictly parsed as a single uint16.";
                          };
                          protocol = mkOption {
                            type = (
                              types.enum [
                                "TCP"
                                "UDP"
                              ]
                            );
                            description = ''
                              Protocol is the L4 protocol.
                              Accepted values: "TCP", "UDP"
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    description = ''
                      ToPorts is a list of L4 ports with protocol of node local pod(s) where traffic
                      is redirected to.
                      When multiple ports are specified, the ports must be named.
                    '';
                  };
                };
                freeformType = types.attrs;
              }
            );
            description = ''
              RedirectBackend specifies backend configuration to redirect traffic to.
              It can not be empty.
            '';
          };
          redirectFrontend = mkOption {
            type = (
              mkTypedSubmodule {
                options = {
                  addressMatcher = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          ip = mkOption {
                            type = types.str;
                            description = ''
                              IP is a destination ip address for traffic to be redirected.

                              Example:
                              When it is set to "169.254.169.254", traffic destined to
                              "169.254.169.254" is redirected.
                            '';
                          };
                          toPorts = mkOption {
                            type = (
                              types.listOf (mkTypedSubmodule {
                                options = {
                                  name = mkOption {
                                    type = (types.nullOr types.str);
                                    default = null;
                                    description = ''
                                      Name is a port name, which must contain at least one [a-z],
                                      and may also contain [0-9] and '-' anywhere except adjacent to another
                                      '-' or in the beginning or the end.
                                    '';
                                  };
                                  port = mkOption {
                                    type = types.str;
                                    description = "Port is an L4 port number. The string will be strictly parsed as a single uint16.";
                                  };
                                  protocol = mkOption {
                                    type = (
                                      types.enum [
                                        "TCP"
                                        "UDP"
                                      ]
                                    );
                                    description = ''
                                      Protocol is the L4 protocol.
                                      Accepted values: "TCP", "UDP"
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            description = ''
                              ToPorts is a list of destination L4 ports with protocol for traffic
                              to be redirected.
                              When multiple ports are specified, the ports must be named.

                              Example:
                              When set to Port: "53" and Protocol: UDP, traffic destined to port '53'
                              with UDP protocol is redirected.
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      AddressMatcher is a tuple {IP, port, protocol} that matches traffic to be
                      redirected.
                    '';
                  };
                  serviceMatcher = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          namespace = mkOption {
                            type = types.str;
                            description = ''
                              Namespace is the Kubernetes service namespace.
                              The service namespace must match the namespace of the parent Local
                              Redirect Policy.  For Cluster-wide Local Redirect Policy, this
                              can be any namespace.
                            '';
                          };
                          serviceName = mkOption {
                            type = types.str;
                            description = ''
                              Name is the name of a destination Kubernetes service that identifies traffic
                              to be redirected.
                              The service type needs to be ClusterIP.

                              Example:
                              When this field is populated with 'serviceName:myService', all the traffic
                              destined to the cluster IP of this service at the (specified)
                              service port(s) will be redirected.
                            '';
                          };
                          toPorts = mkOption {
                            type = (
                              types.nullOr (
                                types.listOf (mkTypedSubmodule {
                                  options = {
                                    name = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Name is a port name, which must contain at least one [a-z],
                                        and may also contain [0-9] and '-' anywhere except adjacent to another
                                        '-' or in the beginning or the end.
                                      '';
                                    };
                                    port = mkOption {
                                      type = types.str;
                                      description = "Port is an L4 port number. The string will be strictly parsed as a single uint16.";
                                    };
                                    protocol = mkOption {
                                      type = (
                                        types.enum [
                                          "TCP"
                                          "UDP"
                                        ]
                                      );
                                      description = ''
                                        Protocol is the L4 protocol.
                                        Accepted values: "TCP", "UDP"
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              )
                            );
                            default = null;
                            description = ''
                              ToPorts is a list of destination service L4 ports with protocol for
                              traffic to be redirected. If not specified, traffic for all the service
                              ports will be redirected.
                              When multiple ports are specified, the ports must be named.
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      ServiceMatcher specifies Kubernetes service and port that matches
                      traffic to be redirected.
                    '';
                  };
                };
                freeformType = types.attrs;
              }
            );
            description = ''
              RedirectFrontend specifies frontend configuration to redirect traffic from.
              It can not be empty.
            '';
          };
          skipRedirectFromBackend = mkOption {
            type = (types.nullOr types.bool);
            default = null;
            description = ''
              SkipRedirectFromBackend indicates whether traffic matching RedirectFrontend
              from RedirectBackend should skip redirection, and hence the traffic will
              be forwarded as-is.

              The default is false which means traffic matching RedirectFrontend will
              get redirected from all pods, including the RedirectBackend(s).

              Example: If RedirectFrontend is configured to "169.254.169.254:80" as the traffic
              that needs to be redirected to backends selected by RedirectBackend, if
              SkipRedirectFromBackend is set to true, traffic going to "169.254.169.254:80"
              from such backends will not be redirected back to the backends. Instead,
              the matched traffic from the backends will be forwarded to the original
              destination "169.254.169.254:80".
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumNetworkPolicy = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumNetworkPolicy";
    specType = (
      mkTypedSubmodule {
        options = {
          description = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = ''
              Description is a free form string, it can be used by the creator of
              the rule to store human readable explanation of the purpose of this
              rule. Rules cannot be identified by comment.
            '';
          };
          egress = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    authentication = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            mode = mkOption {
                              type = (
                                types.enum [
                                  "disabled"
                                  "required"
                                  "test-always-fail"
                                ]
                              );
                              description = "Mode is the required authentication mode for the allowed traffic, if any.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "Authentication is the required authentication type for the allowed traffic, if any.";
                    };
                    icmps = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              fields = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        family = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "IPv4"
                                                "IPv6"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Family is a IP address version.
                                            Currently, we support `IPv4` and `IPv6`.
                                            `IPv4` is set as default.
                                          '';
                                        };
                                        type = mkOption {
                                          type = types.anything;
                                          description = ''
                                            Type is a ICMP-type.
                                            It should be an 8bit code (0-255), or it's CamelCase name (for example, "EchoReply").
                                            Allowed ICMP types are:
                                                Ipv4: EchoReply | DestinationUnreachable | Redirect | Echo | EchoRequest |
                                            		     RouterAdvertisement | RouterSelection | TimeExceeded | ParameterProblem |
                                            			 Timestamp | TimestampReply | Photuris | ExtendedEcho Request | ExtendedEcho Reply
                                                Ipv6: DestinationUnreachable | PacketTooBig | TimeExceeded | ParameterProblem |
                                            			 EchoRequest | EchoReply | MulticastListenerQuery| MulticastListenerReport |
                                            			 MulticastListenerDone | RouterSolicitation | RouterAdvertisement | NeighborSolicitation |
                                            			 NeighborAdvertisement | RedirectMessage | RouterRenumbering | ICMPNodeInformationQuery |
                                            			 ICMPNodeInformationResponse | InverseNeighborDiscoverySolicitation | InverseNeighborDiscoveryAdvertisement |
                                            			 HomeAgentAddressDiscoveryRequest | HomeAgentAddressDiscoveryReply | MobilePrefixSolicitation |
                                            			 MobilePrefixAdvertisement | DuplicateAddressRequestCodeSuffix | DuplicateAddressConfirmationCodeSuffix |
                                            			 ExtendedEchoRequest | ExtendedEchoReply
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Fields is a list of ICMP fields.";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ICMPs is a list of ICMP rule identified by type number
                        which the endpoint subject to the rule is allowed to connect to.

                        Example:
                        Any endpoint with the label "app=httpd" is allowed to initiate
                        type 8 ICMP connections.
                      '';
                    };
                    toCIDR = mkOption {
                      type = (types.nullOr (types.listOf types.str));
                      default = null;
                      description = ''
                        ToCIDR is a list of IP blocks which the endpoint subject to the rule
                        is allowed to initiate connections. Only connections destined for
                        outside of the cluster and not targeting the host will be subject
                        to CIDR rules.  This will match on the destination IP address of
                        outgoing connections. Adding a prefix into ToCIDR or into ToCIDRSet
                        with no ExcludeCIDRs is equivalent. Overlaps are allowed between
                        ToCIDR and ToCIDRSet.

                        Example:
                        Any endpoint with the label "app=database-proxy" is allowed to
                        initiate connections to 10.2.3.0/24
                      '';
                    };
                    toCIDRSet = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              cidr = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = "CIDR is a CIDR prefix / IP Block.";
                              };
                              cidrGroupRef = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  CIDRGroupRef is a reference to a CiliumCIDRGroup object.
                                  A CiliumCIDRGroup contains a list of CIDRs that the endpoint, subject to
                                  the rule, can (Ingress/Egress) or cannot (IngressDeny/EgressDeny) receive
                                  connections from.
                                '';
                              };
                              cidrGroupSelector = mkOption {
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
                                                  type = (
                                                    types.enum [
                                                      "In"
                                                      "NotIn"
                                                      "Exists"
                                                      "DoesNotExist"
                                                    ]
                                                  );
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
                                  CIDRGroupSelector selects CiliumCIDRGroups by their labels,
                                  rather than by name.
                                '';
                              };
                              except = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ExceptCIDRs is a list of IP blocks which the endpoint subject to the rule
                                  is not allowed to initiate connections to. These CIDR prefixes should be
                                  contained within Cidr, using ExceptCIDRs together with CIDRGroupRef is not
                                  supported yet.
                                  These exceptions are only applied to the Cidr in this CIDRRule, and do not
                                  apply to any other CIDR prefixes in any other CIDRRules.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToCIDRSet is a list of IP blocks which the endpoint subject to the rule
                        is allowed to initiate connections to in addition to connections
                        which are allowed via ToEndpoints, along with a list of subnets contained
                        within their corresponding IP block to which traffic should not be
                        allowed. This will match on the destination IP address of outgoing
                        connections. Adding a prefix into ToCIDR or into ToCIDRSet with no
                        ExcludeCIDRs is equivalent. Overlaps are allowed between ToCIDR and
                        ToCIDRSet.

                        Example:
                        Any endpoint with the label "app=database-proxy" is allowed to
                        initiate connections to 10.2.3.0/24 except from IPs in subnet 10.2.3.0/28.
                      '';
                    };
                    toEndpoints = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToEndpoints is a list of endpoints identified by an EndpointSelector to
                        which the endpoints subject to the rule are allowed to communicate.

                        Example:
                        Any endpoint with the label "role=frontend" can communicate with any
                        endpoint carrying the label "role=backend".
                      '';
                    };
                    toEntities = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (
                            types.enum [
                              "all"
                              "world"
                              "cluster"
                              "host"
                              "init"
                              "ingress"
                              "unmanaged"
                              "remote-node"
                              "health"
                              "none"
                              "kube-apiserver"
                            ]
                          )
                        )
                      );
                      default = null;
                      description = ''
                        ToEntities is a list of special entities to which the endpoint subject
                        to the rule is allowed to initiate connections. Supported entities are
                        `world`, `cluster`,`host`,`remote-node`,`kube-apiserver`, `init`,
                        `health`,`unmanaged` and `all`.
                      '';
                    };
                    toFQDNs = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              matchName = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  MatchName matches literal DNS names. A trailing "." is automatically added
                                  when missing.
                                '';
                              };
                              matchPattern = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  MatchPattern allows using wildcards to match DNS names. All wildcards are
                                  case insensitive. The wildcards are:
                                  - "*" matches 0 or more DNS valid characters, and may occur anywhere in
                                  the pattern. As a special case a "*" as the leftmost character, without a
                                  following "." matches all subdomains as well as the name to the right.
                                  A trailing "." is automatically added when missing.

                                  Examples:
                                  `*.cilium.io` matches subomains of cilium at that level
                                    www.cilium.io and blog.cilium.io match, cilium.io and google.com do not
                                  `*cilium.io` matches cilium.io and all subdomains ends with "cilium.io"
                                    except those containing "." separator, subcilium.io and sub-cilium.io match,
                                    www.cilium.io and blog.cilium.io does not
                                  sub*.cilium.io matches subdomains of cilium where the subdomain component
                                  begins with "sub"
                                    sub.cilium.io and subdomain.cilium.io match, www.cilium.io,
                                    blog.cilium.io, cilium.io and google.com do not
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToFQDN allows whitelisting DNS names in place of IPs. The IPs that result
                        from DNS resolution of `ToFQDN.MatchName`s are added to the same
                        EgressRule object as ToCIDRSet entries, and behave accordingly. Any L4 and
                        L7 rules within this EgressRule will also apply to these IPs.
                        The DNS -> IP mapping is re-resolved periodically from within the
                        cilium-agent, and the IPs in the DNS response are effected in the policy
                        for selected pods as-is (i.e. the list of IPs is not modified in any way).
                        Note: An explicit rule to allow for DNS traffic is needed for the pods, as
                        ToFQDN counts as an egress rule and will enforce egress policy when
                        PolicyEnforcment=default.
                        Note: If the resolved IPs are IPs within the kubernetes cluster, the
                        ToFQDN rule will not apply to that IP.
                        Note: ToFQDN cannot occur in the same policy as other To* rules.
                      '';
                    };
                    toGroups = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              aws = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      labels = mkOption {
                                        type = (types.nullOr (types.attrsOf types.str));
                                        default = null;
                                      };
                                      region = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      securityGroupsIds = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                      securityGroupsNames = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "AWSGroup is an structure that can be used to whitelisting information from AWS integration";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToGroups is a directive that allows the integration with multiple outside
                        providers. Currently, only AWS is supported, and the rule can select by
                        multiple sub directives:

                        Example:
                        toGroups:
                        - aws:
                            securityGroupsIds:
                            - 'sg-XXXXXXXXXXXXX'
                      '';
                    };
                    toNodes = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToNodes is a list of nodes identified by an
                        EndpointSelector to which endpoints subject to the rule is allowed to communicate.
                      '';
                    };
                    toPorts = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              listener = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      envoyConfig = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              kind = mkOption {
                                                type = (
                                                  types.nullOr (
                                                    types.enum [
                                                      "CiliumEnvoyConfig"
                                                      "CiliumClusterwideEnvoyConfig"
                                                    ]
                                                  )
                                                );
                                                default = null;
                                                description = ''
                                                  Kind is the resource type being referred to. Defaults to CiliumEnvoyConfig or
                                                  CiliumClusterwideEnvoyConfig for CiliumNetworkPolicy and CiliumClusterwideNetworkPolicy,
                                                  respectively. The only case this is currently explicitly needed is when referring to a
                                                  CiliumClusterwideEnvoyConfig from CiliumNetworkPolicy, as using a namespaced listener
                                                  from a cluster scoped policy is not allowed.
                                                '';
                                              };
                                              name = mkOption {
                                                type = types.str;
                                                description = ''
                                                  Name is the resource name of the CiliumEnvoyConfig or CiliumClusterwideEnvoyConfig where
                                                  the listener is defined in.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          EnvoyConfig is a reference to the CEC or CCEC resource in which
                                          the listener is defined.
                                        '';
                                      };
                                      name = mkOption {
                                        type = types.str;
                                        description = "Name is the name of the listener.";
                                      };
                                      priority = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          Priority for this Listener that is used when multiple rules would apply different
                                          listeners to a policy map entry. Behavior of this is implementation dependent.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  listener specifies the name of a custom Envoy listener to which this traffic should be
                                  redirected to.
                                '';
                              };
                              originatingTLS = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      certificate = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Certificate is the file name or k8s secret item name for the certificate
                                          chain. If omitted, 'tls.crt' is assumed, if it exists. If given, the
                                          item must exist.
                                        '';
                                      };
                                      privateKey = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          PrivateKey is the file name or k8s secret item name for the private key
                                          matching the certificate chain. If omitted, 'tls.key' is assumed, if it
                                          exists. If given, the item must exist.
                                        '';
                                      };
                                      secret = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              name = mkOption {
                                                type = types.str;
                                                description = "Name is the name of the secret.";
                                              };
                                              namespace = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Namespace is the namespace in which the secret exists. Context of use
                                                  determines the default value if left out (e.g., "default").
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          Secret is the secret that contains the certificates and private key for
                                          the TLS context.
                                          By default, Cilium will search in this secret for the following items:
                                           - 'ca.crt'  - Which represents the trusted CA to verify remote source.
                                           - 'tls.crt' - Which represents the public key certificate.
                                           - 'tls.key' - Which represents the private key matching the public key
                                                         certificate.
                                        '';
                                      };
                                      trustedCA = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          TrustedCA is the file name or k8s secret item name for the trusted CA.
                                          If omitted, 'ca.crt' is assumed, if it exists. If given, the item must
                                          exist.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  OriginatingTLS is the TLS context for the connections originated by
                                  the L7 proxy.  For egress policy this specifies the client-side TLS
                                  parameters for the upstream connection originating from the L7 proxy
                                  to the remote destination. For ingress policy this specifies the
                                  client-side TLS parameters for the connection from the L7 proxy to
                                  the local endpoint.
                                '';
                              };
                              ports = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        endPort = mkOption {
                                          type = (types.nullOr types.int);
                                          default = null;
                                          description = "EndPort can only be an L4 port number.";
                                        };
                                        port = mkOption {
                                          type = types.str;
                                          description = ''
                                            Port can be an L4 port number, or a name in the form of "http"
                                            or "http-8080".
                                          '';
                                        };
                                        protocol = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "TCP"
                                                "UDP"
                                                "SCTP"
                                                "ANY"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Protocol is the L4 protocol. If omitted or empty, any protocol
                                            matches. Accepted values: "TCP", "UDP", "SCTP", "ANY"

                                            Matching on ICMP is not supported.

                                            Named port specified for a container may narrow this down, but may not
                                            contradict this.
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Ports is a list of L4 port/protocol";
                              };
                              rules = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      dns = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                matchName = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    MatchName matches literal DNS names. A trailing "." is automatically added
                                                    when missing.
                                                  '';
                                                };
                                                matchPattern = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    MatchPattern allows using wildcards to match DNS names. All wildcards are
                                                    case insensitive. The wildcards are:
                                                    - "*" matches 0 or more DNS valid characters, and may occur anywhere in
                                                    the pattern. As a special case a "*" as the leftmost character, without a
                                                    following "." matches all subdomains as well as the name to the right.
                                                    A trailing "." is automatically added when missing.

                                                    Examples:
                                                    `*.cilium.io` matches subomains of cilium at that level
                                                      www.cilium.io and blog.cilium.io match, cilium.io and google.com do not
                                                    `*cilium.io` matches cilium.io and all subdomains ends with "cilium.io"
                                                      except those containing "." separator, subcilium.io and sub-cilium.io match,
                                                      www.cilium.io and blog.cilium.io does not
                                                    sub*.cilium.io matches subdomains of cilium where the subdomain component
                                                    begins with "sub"
                                                      sub.cilium.io and subdomain.cilium.io match, www.cilium.io,
                                                      blog.cilium.io, cilium.io and google.com do not
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "DNS-specific rules.";
                                      };
                                      http = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                headerMatches = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          mismatch = mkOption {
                                                            type = (
                                                              types.nullOr (
                                                                types.enum [
                                                                  "LOG"
                                                                  "ADD"
                                                                  "DELETE"
                                                                  "REPLACE"
                                                                ]
                                                              )
                                                            );
                                                            default = null;
                                                            description = ''
                                                              Mismatch identifies what to do in case there is no match. The default is
                                                              to drop the request. Otherwise the overall rule is still considered as
                                                              matching, but the mismatches are logged in the access log.
                                                            '';
                                                          };
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = "Name identifies the header.";
                                                          };
                                                          secret = mkOption {
                                                            type = (
                                                              types.nullOr (mkTypedSubmodule {
                                                                options = {
                                                                  name = mkOption {
                                                                    type = types.str;
                                                                    description = "Name is the name of the secret.";
                                                                  };
                                                                  namespace = mkOption {
                                                                    type = (types.nullOr types.str);
                                                                    default = null;
                                                                    description = ''
                                                                      Namespace is the namespace in which the secret exists. Context of use
                                                                      determines the default value if left out (e.g., "default").
                                                                    '';
                                                                  };
                                                                };
                                                                freeformType = types.attrs;
                                                              })
                                                            );
                                                            default = null;
                                                            description = ''
                                                              Secret refers to a secret that contains the value to be matched against.
                                                              The secret must only contain one entry. If the referred secret does not
                                                              exist, and there is no "Value" specified, the match will fail.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = (types.nullOr types.str);
                                                            default = null;
                                                            description = ''
                                                              Value matches the exact value of the header. Can be specified either
                                                              alone or together with "Secret"; will be used as the header value if the
                                                              secret can not be found in the latter case.
                                                            '';
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    HeaderMatches is a list of HTTP headers which must be
                                                    present and match against the given values. Mismatch field can be used
                                                    to specify what to do when there is no match.
                                                  '';
                                                };
                                                headers = mkOption {
                                                  type = (types.nullOr (types.listOf types.str));
                                                  default = null;
                                                  description = ''
                                                    Headers is a list of HTTP headers which must be present in the
                                                    request. If omitted or empty, requests are allowed regardless of
                                                    headers present.
                                                  '';
                                                };
                                                host = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Host is an extended POSIX regex matched against the host header of a
                                                    request. Examples:

                                                    - foo.bar.com will match the host fooXbar.com or foo-bar.com
                                                    - foo\.bar\.com will only match the host foo.bar.com

                                                    If omitted or empty, the value of the host header is ignored.
                                                  '';
                                                };
                                                method = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Method is an extended POSIX regex matched against the method of a
                                                    request, e.g. "GET", "POST", "PUT", "PATCH", "DELETE", ...

                                                    If omitted or empty, all methods are allowed.
                                                  '';
                                                };
                                                path = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Path is an extended POSIX regex matched against the path of a
                                                    request. Currently it can contain characters disallowed from the
                                                    conventional "path" part of a URL as defined by RFC 3986.

                                                    If omitted or empty, all paths are all allowed.
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "HTTP specific rules.";
                                      };
                                      kafka = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                apiKey = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    APIKey is a case-insensitive string matched against the key of a
                                                    request, e.g. "produce", "fetch", "createtopic", "deletetopic", et al
                                                    Reference: https://kafka.apache.org/protocol#protocol_api_keys

                                                    If omitted or empty, and if Role is not specified, then all keys are allowed.
                                                  '';
                                                };
                                                apiVersion = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    APIVersion is the version matched against the api version of the
                                                    Kafka message. If set, it has to be a string representing a positive
                                                    integer.

                                                    If omitted or empty, all versions are allowed.
                                                  '';
                                                };
                                                clientID = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    ClientID is the client identifier as provided in the request.

                                                    From Kafka protocol documentation:
                                                    This is a user supplied identifier for the client application. The
                                                    user can use any identifier they like and it will be used when
                                                    logging errors, monitoring aggregates, etc. For example, one might
                                                    want to monitor not just the requests per second overall, but the
                                                    number coming from each client application (each of which could
                                                    reside on multiple servers). This id acts as a logical grouping
                                                    across all requests from a particular client.

                                                    If omitted or empty, all client identifiers are allowed.
                                                  '';
                                                };
                                                role = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.enum [
                                                        "produce"
                                                        "consume"
                                                      ]
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Role is a case-insensitive string and describes a group of API keys
                                                    necessary to perform certain higher-level Kafka operations such as "produce"
                                                    or "consume". A Role automatically expands into all APIKeys required
                                                    to perform the specified higher-level operation.

                                                    The following values are supported:
                                                     - "produce": Allow producing to the topics specified in the rule
                                                     - "consume": Allow consuming from the topics specified in the rule

                                                    This field is incompatible with the APIKey field, i.e APIKey and Role
                                                    cannot both be specified in the same rule.

                                                    If omitted or empty, and if APIKey is not specified, then all keys are
                                                    allowed.
                                                  '';
                                                };
                                                topic = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Topic is the topic name contained in the message. If a Kafka request
                                                    contains multiple topics, then all topics must be allowed or the
                                                    message will be rejected.

                                                    This constraint is ignored if the matched request message type
                                                    doesn't contain any topic. Maximum size of Topic can be 249
                                                    characters as per recent Kafka spec and allowed characters are
                                                    a-z, A-Z, 0-9, -, . and _.

                                                    Older Kafka versions had longer topic lengths of 255, but in Kafka 0.10
                                                    version the length was changed from 255 to 249. For compatibility
                                                    reasons we are using 255.

                                                    If omitted or empty, all topics are allowed.
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "Kafka-specific rules.";
                                      };
                                      l7 = mkOption {
                                        type = (types.nullOr (types.listOf (types.attrsOf types.str)));
                                        default = null;
                                        description = "Key-value pair rules.";
                                      };
                                      l7proto = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = "Name of the L7 protocol for which the Key-value pair rules apply.";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  Rules is a list of additional port level rules which must be met in
                                  order for the PortRule to allow the traffic. If omitted or empty,
                                  no layer 7 rules are enforced.
                                '';
                              };
                              serverNames = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ServerNames is a list of allowed TLS SNI values. If not empty, then
                                  TLS must be present and one of the provided SNIs must be indicated in the
                                  TLS handshake.
                                '';
                              };
                              terminatingTLS = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      certificate = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Certificate is the file name or k8s secret item name for the certificate
                                          chain. If omitted, 'tls.crt' is assumed, if it exists. If given, the
                                          item must exist.
                                        '';
                                      };
                                      privateKey = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          PrivateKey is the file name or k8s secret item name for the private key
                                          matching the certificate chain. If omitted, 'tls.key' is assumed, if it
                                          exists. If given, the item must exist.
                                        '';
                                      };
                                      secret = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              name = mkOption {
                                                type = types.str;
                                                description = "Name is the name of the secret.";
                                              };
                                              namespace = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Namespace is the namespace in which the secret exists. Context of use
                                                  determines the default value if left out (e.g., "default").
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          Secret is the secret that contains the certificates and private key for
                                          the TLS context.
                                          By default, Cilium will search in this secret for the following items:
                                           - 'ca.crt'  - Which represents the trusted CA to verify remote source.
                                           - 'tls.crt' - Which represents the public key certificate.
                                           - 'tls.key' - Which represents the private key matching the public key
                                                         certificate.
                                        '';
                                      };
                                      trustedCA = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          TrustedCA is the file name or k8s secret item name for the trusted CA.
                                          If omitted, 'ca.crt' is assumed, if it exists. If given, the item must
                                          exist.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  TerminatingTLS is the TLS context for the connection terminated by
                                  the L7 proxy.  For egress policy this specifies the server-side TLS
                                  parameters to be applied on the connections originated from the local
                                  endpoint and terminated by the L7 proxy. For ingress policy this specifies
                                  the server-side TLS parameters to be applied on the connections
                                  originated from a remote source and terminated by the L7 proxy.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToPorts is a list of destination ports identified by port number and
                        protocol which the endpoint subject to the rule is allowed to
                        connect to.

                        Example:
                        Any endpoint with the label "role=frontend" is allowed to initiate
                        connections to destination port 8080/tcp
                      '';
                    };
                    toRequires = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToRequires is a list of additional constraints which must be met
                        in order for the selected endpoints to be able to connect to other
                        endpoints. These additional constraints do no by itself grant access
                        privileges and must always be accompanied with at least one matching
                        ToEndpoints.

                        Example:
                        Any Endpoint with the label "team=A" requires any endpoint to which it
                        communicates to also carry the label "team=A".
                      '';
                    };
                    toServices = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              k8sService = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      namespace = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      serviceName = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "K8sService selects service by name and namespace pair";
                              };
                              k8sServiceSelector = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      namespace = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      selector = mkOption {
                                        type = (
                                          mkTypedSubmodule {
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
                                                          type = (
                                                            types.enum [
                                                              "In"
                                                              "NotIn"
                                                              "Exists"
                                                              "DoesNotExist"
                                                            ]
                                                          );
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
                                          }
                                        );
                                        description = "ServiceSelector is a label selector for k8s services";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "K8sServiceSelector selects services by k8s labels and namespace";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToServices is a list of services to which the endpoint subject
                        to the rule is allowed to initiate connections.
                        Currently Cilium only supports toServices for K8s services.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Egress is a list of EgressRule which are enforced at egress.
              If omitted or empty, this rule does not apply at egress.
            '';
          };
          egressDeny = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    icmps = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              fields = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        family = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "IPv4"
                                                "IPv6"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Family is a IP address version.
                                            Currently, we support `IPv4` and `IPv6`.
                                            `IPv4` is set as default.
                                          '';
                                        };
                                        type = mkOption {
                                          type = types.anything;
                                          description = ''
                                            Type is a ICMP-type.
                                            It should be an 8bit code (0-255), or it's CamelCase name (for example, "EchoReply").
                                            Allowed ICMP types are:
                                                Ipv4: EchoReply | DestinationUnreachable | Redirect | Echo | EchoRequest |
                                            		     RouterAdvertisement | RouterSelection | TimeExceeded | ParameterProblem |
                                            			 Timestamp | TimestampReply | Photuris | ExtendedEcho Request | ExtendedEcho Reply
                                                Ipv6: DestinationUnreachable | PacketTooBig | TimeExceeded | ParameterProblem |
                                            			 EchoRequest | EchoReply | MulticastListenerQuery| MulticastListenerReport |
                                            			 MulticastListenerDone | RouterSolicitation | RouterAdvertisement | NeighborSolicitation |
                                            			 NeighborAdvertisement | RedirectMessage | RouterRenumbering | ICMPNodeInformationQuery |
                                            			 ICMPNodeInformationResponse | InverseNeighborDiscoverySolicitation | InverseNeighborDiscoveryAdvertisement |
                                            			 HomeAgentAddressDiscoveryRequest | HomeAgentAddressDiscoveryReply | MobilePrefixSolicitation |
                                            			 MobilePrefixAdvertisement | DuplicateAddressRequestCodeSuffix | DuplicateAddressConfirmationCodeSuffix |
                                            			 ExtendedEchoRequest | ExtendedEchoReply
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Fields is a list of ICMP fields.";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ICMPs is a list of ICMP rule identified by type number
                        which the endpoint subject to the rule is not allowed to connect to.

                        Example:
                        Any endpoint with the label "app=httpd" is not allowed to initiate
                        type 8 ICMP connections.
                      '';
                    };
                    toCIDR = mkOption {
                      type = (types.nullOr (types.listOf types.str));
                      default = null;
                      description = ''
                        ToCIDR is a list of IP blocks which the endpoint subject to the rule
                        is allowed to initiate connections. Only connections destined for
                        outside of the cluster and not targeting the host will be subject
                        to CIDR rules.  This will match on the destination IP address of
                        outgoing connections. Adding a prefix into ToCIDR or into ToCIDRSet
                        with no ExcludeCIDRs is equivalent. Overlaps are allowed between
                        ToCIDR and ToCIDRSet.

                        Example:
                        Any endpoint with the label "app=database-proxy" is allowed to
                        initiate connections to 10.2.3.0/24
                      '';
                    };
                    toCIDRSet = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              cidr = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = "CIDR is a CIDR prefix / IP Block.";
                              };
                              cidrGroupRef = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  CIDRGroupRef is a reference to a CiliumCIDRGroup object.
                                  A CiliumCIDRGroup contains a list of CIDRs that the endpoint, subject to
                                  the rule, can (Ingress/Egress) or cannot (IngressDeny/EgressDeny) receive
                                  connections from.
                                '';
                              };
                              cidrGroupSelector = mkOption {
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
                                                  type = (
                                                    types.enum [
                                                      "In"
                                                      "NotIn"
                                                      "Exists"
                                                      "DoesNotExist"
                                                    ]
                                                  );
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
                                  CIDRGroupSelector selects CiliumCIDRGroups by their labels,
                                  rather than by name.
                                '';
                              };
                              except = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ExceptCIDRs is a list of IP blocks which the endpoint subject to the rule
                                  is not allowed to initiate connections to. These CIDR prefixes should be
                                  contained within Cidr, using ExceptCIDRs together with CIDRGroupRef is not
                                  supported yet.
                                  These exceptions are only applied to the Cidr in this CIDRRule, and do not
                                  apply to any other CIDR prefixes in any other CIDRRules.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToCIDRSet is a list of IP blocks which the endpoint subject to the rule
                        is allowed to initiate connections to in addition to connections
                        which are allowed via ToEndpoints, along with a list of subnets contained
                        within their corresponding IP block to which traffic should not be
                        allowed. This will match on the destination IP address of outgoing
                        connections. Adding a prefix into ToCIDR or into ToCIDRSet with no
                        ExcludeCIDRs is equivalent. Overlaps are allowed between ToCIDR and
                        ToCIDRSet.

                        Example:
                        Any endpoint with the label "app=database-proxy" is allowed to
                        initiate connections to 10.2.3.0/24 except from IPs in subnet 10.2.3.0/28.
                      '';
                    };
                    toEndpoints = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToEndpoints is a list of endpoints identified by an EndpointSelector to
                        which the endpoints subject to the rule are allowed to communicate.

                        Example:
                        Any endpoint with the label "role=frontend" can communicate with any
                        endpoint carrying the label "role=backend".
                      '';
                    };
                    toEntities = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (
                            types.enum [
                              "all"
                              "world"
                              "cluster"
                              "host"
                              "init"
                              "ingress"
                              "unmanaged"
                              "remote-node"
                              "health"
                              "none"
                              "kube-apiserver"
                            ]
                          )
                        )
                      );
                      default = null;
                      description = ''
                        ToEntities is a list of special entities to which the endpoint subject
                        to the rule is allowed to initiate connections. Supported entities are
                        `world`, `cluster`,`host`,`remote-node`,`kube-apiserver`, `init`,
                        `health`,`unmanaged` and `all`.
                      '';
                    };
                    toGroups = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              aws = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      labels = mkOption {
                                        type = (types.nullOr (types.attrsOf types.str));
                                        default = null;
                                      };
                                      region = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      securityGroupsIds = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                      securityGroupsNames = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "AWSGroup is an structure that can be used to whitelisting information from AWS integration";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToGroups is a directive that allows the integration with multiple outside
                        providers. Currently, only AWS is supported, and the rule can select by
                        multiple sub directives:

                        Example:
                        toGroups:
                        - aws:
                            securityGroupsIds:
                            - 'sg-XXXXXXXXXXXXX'
                      '';
                    };
                    toNodes = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToNodes is a list of nodes identified by an
                        EndpointSelector to which endpoints subject to the rule is allowed to communicate.
                      '';
                    };
                    toPorts = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              ports = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        endPort = mkOption {
                                          type = (types.nullOr types.int);
                                          default = null;
                                          description = "EndPort can only be an L4 port number.";
                                        };
                                        port = mkOption {
                                          type = types.str;
                                          description = ''
                                            Port can be an L4 port number, or a name in the form of "http"
                                            or "http-8080".
                                          '';
                                        };
                                        protocol = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "TCP"
                                                "UDP"
                                                "SCTP"
                                                "ANY"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Protocol is the L4 protocol. If omitted or empty, any protocol
                                            matches. Accepted values: "TCP", "UDP", "SCTP", "ANY"

                                            Matching on ICMP is not supported.

                                            Named port specified for a container may narrow this down, but may not
                                            contradict this.
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Ports is a list of L4 port/protocol";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToPorts is a list of destination ports identified by port number and
                        protocol which the endpoint subject to the rule is not allowed to connect
                        to.

                        Example:
                        Any endpoint with the label "role=frontend" is not allowed to initiate
                        connections to destination port 8080/tcp
                      '';
                    };
                    toRequires = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        ToRequires is a list of additional constraints which must be met
                        in order for the selected endpoints to be able to connect to other
                        endpoints. These additional constraints do no by itself grant access
                        privileges and must always be accompanied with at least one matching
                        ToEndpoints.

                        Example:
                        Any Endpoint with the label "team=A" requires any endpoint to which it
                        communicates to also carry the label "team=A".
                      '';
                    };
                    toServices = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              k8sService = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      namespace = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      serviceName = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "K8sService selects service by name and namespace pair";
                              };
                              k8sServiceSelector = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      namespace = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      selector = mkOption {
                                        type = (
                                          mkTypedSubmodule {
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
                                                          type = (
                                                            types.enum [
                                                              "In"
                                                              "NotIn"
                                                              "Exists"
                                                              "DoesNotExist"
                                                            ]
                                                          );
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
                                          }
                                        );
                                        description = "ServiceSelector is a label selector for k8s services";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "K8sServiceSelector selects services by k8s labels and namespace";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToServices is a list of services to which the endpoint subject
                        to the rule is allowed to initiate connections.
                        Currently Cilium only supports toServices for K8s services.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              EgressDeny is a list of EgressDenyRule which are enforced at egress.
              Any rule inserted here will be denied regardless of the allowed egress
              rules in the 'egress' field.
              If omitted or empty, this rule does not apply at egress.
            '';
          };
          enableDefaultDeny = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  egress = mkOption {
                    type = (types.nullOr types.bool);
                    default = null;
                    description = ''
                      Whether or not the endpoint should have a default-deny rule applied
                      to egress traffic.
                    '';
                  };
                  ingress = mkOption {
                    type = (types.nullOr types.bool);
                    default = null;
                    description = ''
                      Whether or not the endpoint should have a default-deny rule applied
                      to ingress traffic.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              EnableDefaultDeny determines whether this policy configures the
              subject endpoint(s) to have a default deny mode. If enabled,
              this causes all traffic not explicitly allowed by a network policy
              to be dropped.

              If not specified, the default is true for each traffic direction
              that has rules, and false otherwise. For example, if a policy
              only has Ingress or IngressDeny rules, then the default for
              ingress is true and egress is false.

              If multiple policies apply to an endpoint, that endpoint's default deny
              will be enabled if any policy requests it.

              This is useful for creating broad-based network policies that will not
              cause endpoints to enter default-deny mode.
            '';
          };
          endpointSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
              EndpointSelector selects all endpoints which should be subject to
              this rule. EndpointSelector and NodeSelector cannot be both empty and
              are mutually exclusive.
            '';
          };
          ingress = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    authentication = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            mode = mkOption {
                              type = (
                                types.enum [
                                  "disabled"
                                  "required"
                                  "test-always-fail"
                                ]
                              );
                              description = "Mode is the required authentication mode for the allowed traffic, if any.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = "Authentication is the required authentication type for the allowed traffic, if any.";
                    };
                    fromCIDR = mkOption {
                      type = (types.nullOr (types.listOf types.str));
                      default = null;
                      description = ''
                        FromCIDR is a list of IP blocks which the endpoint subject to the
                        rule is allowed to receive connections from. Only connections which
                        do *not* originate from the cluster or from the local host are subject
                        to CIDR rules. In order to allow in-cluster connectivity, use the
                        FromEndpoints field.  This will match on the source IP address of
                        incoming connections. Adding  a prefix into FromCIDR or into
                        FromCIDRSet with no ExcludeCIDRs is  equivalent.  Overlaps are
                        allowed between FromCIDR and FromCIDRSet.

                        Example:
                        Any endpoint with the label "app=my-legacy-pet" is allowed to receive
                        connections from 10.3.9.1
                      '';
                    };
                    fromCIDRSet = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              cidr = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = "CIDR is a CIDR prefix / IP Block.";
                              };
                              cidrGroupRef = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  CIDRGroupRef is a reference to a CiliumCIDRGroup object.
                                  A CiliumCIDRGroup contains a list of CIDRs that the endpoint, subject to
                                  the rule, can (Ingress/Egress) or cannot (IngressDeny/EgressDeny) receive
                                  connections from.
                                '';
                              };
                              cidrGroupSelector = mkOption {
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
                                                  type = (
                                                    types.enum [
                                                      "In"
                                                      "NotIn"
                                                      "Exists"
                                                      "DoesNotExist"
                                                    ]
                                                  );
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
                                  CIDRGroupSelector selects CiliumCIDRGroups by their labels,
                                  rather than by name.
                                '';
                              };
                              except = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ExceptCIDRs is a list of IP blocks which the endpoint subject to the rule
                                  is not allowed to initiate connections to. These CIDR prefixes should be
                                  contained within Cidr, using ExceptCIDRs together with CIDRGroupRef is not
                                  supported yet.
                                  These exceptions are only applied to the Cidr in this CIDRRule, and do not
                                  apply to any other CIDR prefixes in any other CIDRRules.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        FromCIDRSet is a list of IP blocks which the endpoint subject to the
                        rule is allowed to receive connections from in addition to FromEndpoints,
                        along with a list of subnets contained within their corresponding IP block
                        from which traffic should not be allowed.
                        This will match on the source IP address of incoming connections. Adding
                        a prefix into FromCIDR or into FromCIDRSet with no ExcludeCIDRs is
                        equivalent. Overlaps are allowed between FromCIDR and FromCIDRSet.

                        Example:
                        Any endpoint with the label "app=my-legacy-pet" is allowed to receive
                        connections from 10.0.0.0/8 except from IPs in subnet 10.96.0.0/12.
                      '';
                    };
                    fromEndpoints = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromEndpoints is a list of endpoints identified by an
                        EndpointSelector which are allowed to communicate with the endpoint
                        subject to the rule.

                        Example:
                        Any endpoint with the label "role=backend" can be consumed by any
                        endpoint carrying the label "role=frontend".
                      '';
                    };
                    fromEntities = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (
                            types.enum [
                              "all"
                              "world"
                              "cluster"
                              "host"
                              "init"
                              "ingress"
                              "unmanaged"
                              "remote-node"
                              "health"
                              "none"
                              "kube-apiserver"
                            ]
                          )
                        )
                      );
                      default = null;
                      description = ''
                        FromEntities is a list of special entities which the endpoint subject
                        to the rule is allowed to receive connections from. Supported entities are
                        `world`, `cluster` and `host`
                      '';
                    };
                    fromGroups = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              aws = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      labels = mkOption {
                                        type = (types.nullOr (types.attrsOf types.str));
                                        default = null;
                                      };
                                      region = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      securityGroupsIds = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                      securityGroupsNames = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "AWSGroup is an structure that can be used to whitelisting information from AWS integration";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        FromGroups is a directive that allows the integration with multiple outside
                        providers. Currently, only AWS is supported, and the rule can select by
                        multiple sub directives:

                        Example:
                        FromGroups:
                        - aws:
                            securityGroupsIds:
                            - 'sg-XXXXXXXXXXXXX'
                      '';
                    };
                    fromNodes = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromNodes is a list of nodes identified by an
                        EndpointSelector which are allowed to communicate with the endpoint
                        subject to the rule.
                      '';
                    };
                    fromRequires = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromRequires is a list of additional constraints which must be met
                        in order for the selected endpoints to be reachable. These
                        additional constraints do no by itself grant access privileges and
                        must always be accompanied with at least one matching FromEndpoints.

                        Example:
                        Any Endpoint with the label "team=A" requires consuming endpoint
                        to also carry the label "team=A".
                      '';
                    };
                    icmps = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              fields = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        family = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "IPv4"
                                                "IPv6"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Family is a IP address version.
                                            Currently, we support `IPv4` and `IPv6`.
                                            `IPv4` is set as default.
                                          '';
                                        };
                                        type = mkOption {
                                          type = types.anything;
                                          description = ''
                                            Type is a ICMP-type.
                                            It should be an 8bit code (0-255), or it's CamelCase name (for example, "EchoReply").
                                            Allowed ICMP types are:
                                                Ipv4: EchoReply | DestinationUnreachable | Redirect | Echo | EchoRequest |
                                            		     RouterAdvertisement | RouterSelection | TimeExceeded | ParameterProblem |
                                            			 Timestamp | TimestampReply | Photuris | ExtendedEcho Request | ExtendedEcho Reply
                                                Ipv6: DestinationUnreachable | PacketTooBig | TimeExceeded | ParameterProblem |
                                            			 EchoRequest | EchoReply | MulticastListenerQuery| MulticastListenerReport |
                                            			 MulticastListenerDone | RouterSolicitation | RouterAdvertisement | NeighborSolicitation |
                                            			 NeighborAdvertisement | RedirectMessage | RouterRenumbering | ICMPNodeInformationQuery |
                                            			 ICMPNodeInformationResponse | InverseNeighborDiscoverySolicitation | InverseNeighborDiscoveryAdvertisement |
                                            			 HomeAgentAddressDiscoveryRequest | HomeAgentAddressDiscoveryReply | MobilePrefixSolicitation |
                                            			 MobilePrefixAdvertisement | DuplicateAddressRequestCodeSuffix | DuplicateAddressConfirmationCodeSuffix |
                                            			 ExtendedEchoRequest | ExtendedEchoReply
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Fields is a list of ICMP fields.";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ICMPs is a list of ICMP rule identified by type number
                        which the endpoint subject to the rule is allowed to
                        receive connections on.

                        Example:
                        Any endpoint with the label "app=httpd" can only accept incoming
                        type 8 ICMP connections.
                      '';
                    };
                    toPorts = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              listener = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      envoyConfig = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              kind = mkOption {
                                                type = (
                                                  types.nullOr (
                                                    types.enum [
                                                      "CiliumEnvoyConfig"
                                                      "CiliumClusterwideEnvoyConfig"
                                                    ]
                                                  )
                                                );
                                                default = null;
                                                description = ''
                                                  Kind is the resource type being referred to. Defaults to CiliumEnvoyConfig or
                                                  CiliumClusterwideEnvoyConfig for CiliumNetworkPolicy and CiliumClusterwideNetworkPolicy,
                                                  respectively. The only case this is currently explicitly needed is when referring to a
                                                  CiliumClusterwideEnvoyConfig from CiliumNetworkPolicy, as using a namespaced listener
                                                  from a cluster scoped policy is not allowed.
                                                '';
                                              };
                                              name = mkOption {
                                                type = types.str;
                                                description = ''
                                                  Name is the resource name of the CiliumEnvoyConfig or CiliumClusterwideEnvoyConfig where
                                                  the listener is defined in.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          EnvoyConfig is a reference to the CEC or CCEC resource in which
                                          the listener is defined.
                                        '';
                                      };
                                      name = mkOption {
                                        type = types.str;
                                        description = "Name is the name of the listener.";
                                      };
                                      priority = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          Priority for this Listener that is used when multiple rules would apply different
                                          listeners to a policy map entry. Behavior of this is implementation dependent.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  listener specifies the name of a custom Envoy listener to which this traffic should be
                                  redirected to.
                                '';
                              };
                              originatingTLS = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      certificate = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Certificate is the file name or k8s secret item name for the certificate
                                          chain. If omitted, 'tls.crt' is assumed, if it exists. If given, the
                                          item must exist.
                                        '';
                                      };
                                      privateKey = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          PrivateKey is the file name or k8s secret item name for the private key
                                          matching the certificate chain. If omitted, 'tls.key' is assumed, if it
                                          exists. If given, the item must exist.
                                        '';
                                      };
                                      secret = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              name = mkOption {
                                                type = types.str;
                                                description = "Name is the name of the secret.";
                                              };
                                              namespace = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Namespace is the namespace in which the secret exists. Context of use
                                                  determines the default value if left out (e.g., "default").
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          Secret is the secret that contains the certificates and private key for
                                          the TLS context.
                                          By default, Cilium will search in this secret for the following items:
                                           - 'ca.crt'  - Which represents the trusted CA to verify remote source.
                                           - 'tls.crt' - Which represents the public key certificate.
                                           - 'tls.key' - Which represents the private key matching the public key
                                                         certificate.
                                        '';
                                      };
                                      trustedCA = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          TrustedCA is the file name or k8s secret item name for the trusted CA.
                                          If omitted, 'ca.crt' is assumed, if it exists. If given, the item must
                                          exist.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  OriginatingTLS is the TLS context for the connections originated by
                                  the L7 proxy.  For egress policy this specifies the client-side TLS
                                  parameters for the upstream connection originating from the L7 proxy
                                  to the remote destination. For ingress policy this specifies the
                                  client-side TLS parameters for the connection from the L7 proxy to
                                  the local endpoint.
                                '';
                              };
                              ports = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        endPort = mkOption {
                                          type = (types.nullOr types.int);
                                          default = null;
                                          description = "EndPort can only be an L4 port number.";
                                        };
                                        port = mkOption {
                                          type = types.str;
                                          description = ''
                                            Port can be an L4 port number, or a name in the form of "http"
                                            or "http-8080".
                                          '';
                                        };
                                        protocol = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "TCP"
                                                "UDP"
                                                "SCTP"
                                                "ANY"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Protocol is the L4 protocol. If omitted or empty, any protocol
                                            matches. Accepted values: "TCP", "UDP", "SCTP", "ANY"

                                            Matching on ICMP is not supported.

                                            Named port specified for a container may narrow this down, but may not
                                            contradict this.
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Ports is a list of L4 port/protocol";
                              };
                              rules = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      dns = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                matchName = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    MatchName matches literal DNS names. A trailing "." is automatically added
                                                    when missing.
                                                  '';
                                                };
                                                matchPattern = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    MatchPattern allows using wildcards to match DNS names. All wildcards are
                                                    case insensitive. The wildcards are:
                                                    - "*" matches 0 or more DNS valid characters, and may occur anywhere in
                                                    the pattern. As a special case a "*" as the leftmost character, without a
                                                    following "." matches all subdomains as well as the name to the right.
                                                    A trailing "." is automatically added when missing.

                                                    Examples:
                                                    `*.cilium.io` matches subomains of cilium at that level
                                                      www.cilium.io and blog.cilium.io match, cilium.io and google.com do not
                                                    `*cilium.io` matches cilium.io and all subdomains ends with "cilium.io"
                                                      except those containing "." separator, subcilium.io and sub-cilium.io match,
                                                      www.cilium.io and blog.cilium.io does not
                                                    sub*.cilium.io matches subdomains of cilium where the subdomain component
                                                    begins with "sub"
                                                      sub.cilium.io and subdomain.cilium.io match, www.cilium.io,
                                                      blog.cilium.io, cilium.io and google.com do not
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "DNS-specific rules.";
                                      };
                                      http = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                headerMatches = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          mismatch = mkOption {
                                                            type = (
                                                              types.nullOr (
                                                                types.enum [
                                                                  "LOG"
                                                                  "ADD"
                                                                  "DELETE"
                                                                  "REPLACE"
                                                                ]
                                                              )
                                                            );
                                                            default = null;
                                                            description = ''
                                                              Mismatch identifies what to do in case there is no match. The default is
                                                              to drop the request. Otherwise the overall rule is still considered as
                                                              matching, but the mismatches are logged in the access log.
                                                            '';
                                                          };
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = "Name identifies the header.";
                                                          };
                                                          secret = mkOption {
                                                            type = (
                                                              types.nullOr (mkTypedSubmodule {
                                                                options = {
                                                                  name = mkOption {
                                                                    type = types.str;
                                                                    description = "Name is the name of the secret.";
                                                                  };
                                                                  namespace = mkOption {
                                                                    type = (types.nullOr types.str);
                                                                    default = null;
                                                                    description = ''
                                                                      Namespace is the namespace in which the secret exists. Context of use
                                                                      determines the default value if left out (e.g., "default").
                                                                    '';
                                                                  };
                                                                };
                                                                freeformType = types.attrs;
                                                              })
                                                            );
                                                            default = null;
                                                            description = ''
                                                              Secret refers to a secret that contains the value to be matched against.
                                                              The secret must only contain one entry. If the referred secret does not
                                                              exist, and there is no "Value" specified, the match will fail.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = (types.nullOr types.str);
                                                            default = null;
                                                            description = ''
                                                              Value matches the exact value of the header. Can be specified either
                                                              alone or together with "Secret"; will be used as the header value if the
                                                              secret can not be found in the latter case.
                                                            '';
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    HeaderMatches is a list of HTTP headers which must be
                                                    present and match against the given values. Mismatch field can be used
                                                    to specify what to do when there is no match.
                                                  '';
                                                };
                                                headers = mkOption {
                                                  type = (types.nullOr (types.listOf types.str));
                                                  default = null;
                                                  description = ''
                                                    Headers is a list of HTTP headers which must be present in the
                                                    request. If omitted or empty, requests are allowed regardless of
                                                    headers present.
                                                  '';
                                                };
                                                host = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Host is an extended POSIX regex matched against the host header of a
                                                    request. Examples:

                                                    - foo.bar.com will match the host fooXbar.com or foo-bar.com
                                                    - foo\.bar\.com will only match the host foo.bar.com

                                                    If omitted or empty, the value of the host header is ignored.
                                                  '';
                                                };
                                                method = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Method is an extended POSIX regex matched against the method of a
                                                    request, e.g. "GET", "POST", "PUT", "PATCH", "DELETE", ...

                                                    If omitted or empty, all methods are allowed.
                                                  '';
                                                };
                                                path = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Path is an extended POSIX regex matched against the path of a
                                                    request. Currently it can contain characters disallowed from the
                                                    conventional "path" part of a URL as defined by RFC 3986.

                                                    If omitted or empty, all paths are all allowed.
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "HTTP specific rules.";
                                      };
                                      kafka = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                apiKey = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    APIKey is a case-insensitive string matched against the key of a
                                                    request, e.g. "produce", "fetch", "createtopic", "deletetopic", et al
                                                    Reference: https://kafka.apache.org/protocol#protocol_api_keys

                                                    If omitted or empty, and if Role is not specified, then all keys are allowed.
                                                  '';
                                                };
                                                apiVersion = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    APIVersion is the version matched against the api version of the
                                                    Kafka message. If set, it has to be a string representing a positive
                                                    integer.

                                                    If omitted or empty, all versions are allowed.
                                                  '';
                                                };
                                                clientID = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    ClientID is the client identifier as provided in the request.

                                                    From Kafka protocol documentation:
                                                    This is a user supplied identifier for the client application. The
                                                    user can use any identifier they like and it will be used when
                                                    logging errors, monitoring aggregates, etc. For example, one might
                                                    want to monitor not just the requests per second overall, but the
                                                    number coming from each client application (each of which could
                                                    reside on multiple servers). This id acts as a logical grouping
                                                    across all requests from a particular client.

                                                    If omitted or empty, all client identifiers are allowed.
                                                  '';
                                                };
                                                role = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.enum [
                                                        "produce"
                                                        "consume"
                                                      ]
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Role is a case-insensitive string and describes a group of API keys
                                                    necessary to perform certain higher-level Kafka operations such as "produce"
                                                    or "consume". A Role automatically expands into all APIKeys required
                                                    to perform the specified higher-level operation.

                                                    The following values are supported:
                                                     - "produce": Allow producing to the topics specified in the rule
                                                     - "consume": Allow consuming from the topics specified in the rule

                                                    This field is incompatible with the APIKey field, i.e APIKey and Role
                                                    cannot both be specified in the same rule.

                                                    If omitted or empty, and if APIKey is not specified, then all keys are
                                                    allowed.
                                                  '';
                                                };
                                                topic = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Topic is the topic name contained in the message. If a Kafka request
                                                    contains multiple topics, then all topics must be allowed or the
                                                    message will be rejected.

                                                    This constraint is ignored if the matched request message type
                                                    doesn't contain any topic. Maximum size of Topic can be 249
                                                    characters as per recent Kafka spec and allowed characters are
                                                    a-z, A-Z, 0-9, -, . and _.

                                                    Older Kafka versions had longer topic lengths of 255, but in Kafka 0.10
                                                    version the length was changed from 255 to 249. For compatibility
                                                    reasons we are using 255.

                                                    If omitted or empty, all topics are allowed.
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = "Kafka-specific rules.";
                                      };
                                      l7 = mkOption {
                                        type = (types.nullOr (types.listOf (types.attrsOf types.str)));
                                        default = null;
                                        description = "Key-value pair rules.";
                                      };
                                      l7proto = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = "Name of the L7 protocol for which the Key-value pair rules apply.";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  Rules is a list of additional port level rules which must be met in
                                  order for the PortRule to allow the traffic. If omitted or empty,
                                  no layer 7 rules are enforced.
                                '';
                              };
                              serverNames = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ServerNames is a list of allowed TLS SNI values. If not empty, then
                                  TLS must be present and one of the provided SNIs must be indicated in the
                                  TLS handshake.
                                '';
                              };
                              terminatingTLS = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      certificate = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Certificate is the file name or k8s secret item name for the certificate
                                          chain. If omitted, 'tls.crt' is assumed, if it exists. If given, the
                                          item must exist.
                                        '';
                                      };
                                      privateKey = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          PrivateKey is the file name or k8s secret item name for the private key
                                          matching the certificate chain. If omitted, 'tls.key' is assumed, if it
                                          exists. If given, the item must exist.
                                        '';
                                      };
                                      secret = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              name = mkOption {
                                                type = types.str;
                                                description = "Name is the name of the secret.";
                                              };
                                              namespace = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Namespace is the namespace in which the secret exists. Context of use
                                                  determines the default value if left out (e.g., "default").
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          Secret is the secret that contains the certificates and private key for
                                          the TLS context.
                                          By default, Cilium will search in this secret for the following items:
                                           - 'ca.crt'  - Which represents the trusted CA to verify remote source.
                                           - 'tls.crt' - Which represents the public key certificate.
                                           - 'tls.key' - Which represents the private key matching the public key
                                                         certificate.
                                        '';
                                      };
                                      trustedCA = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          TrustedCA is the file name or k8s secret item name for the trusted CA.
                                          If omitted, 'ca.crt' is assumed, if it exists. If given, the item must
                                          exist.
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  TerminatingTLS is the TLS context for the connection terminated by
                                  the L7 proxy.  For egress policy this specifies the server-side TLS
                                  parameters to be applied on the connections originated from the local
                                  endpoint and terminated by the L7 proxy. For ingress policy this specifies
                                  the server-side TLS parameters to be applied on the connections
                                  originated from a remote source and terminated by the L7 proxy.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToPorts is a list of destination ports identified by port number and
                        protocol which the endpoint subject to the rule is allowed to
                        receive connections on.

                        Example:
                        Any endpoint with the label "app=httpd" can only accept incoming
                        connections on port 80/tcp.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Ingress is a list of IngressRule which are enforced at ingress.
              If omitted or empty, this rule does not apply at ingress.
            '';
          };
          ingressDeny = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    fromCIDR = mkOption {
                      type = (types.nullOr (types.listOf types.str));
                      default = null;
                      description = ''
                        FromCIDR is a list of IP blocks which the endpoint subject to the
                        rule is allowed to receive connections from. Only connections which
                        do *not* originate from the cluster or from the local host are subject
                        to CIDR rules. In order to allow in-cluster connectivity, use the
                        FromEndpoints field.  This will match on the source IP address of
                        incoming connections. Adding  a prefix into FromCIDR or into
                        FromCIDRSet with no ExcludeCIDRs is  equivalent.  Overlaps are
                        allowed between FromCIDR and FromCIDRSet.

                        Example:
                        Any endpoint with the label "app=my-legacy-pet" is allowed to receive
                        connections from 10.3.9.1
                      '';
                    };
                    fromCIDRSet = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              cidr = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = "CIDR is a CIDR prefix / IP Block.";
                              };
                              cidrGroupRef = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  CIDRGroupRef is a reference to a CiliumCIDRGroup object.
                                  A CiliumCIDRGroup contains a list of CIDRs that the endpoint, subject to
                                  the rule, can (Ingress/Egress) or cannot (IngressDeny/EgressDeny) receive
                                  connections from.
                                '';
                              };
                              cidrGroupSelector = mkOption {
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
                                                  type = (
                                                    types.enum [
                                                      "In"
                                                      "NotIn"
                                                      "Exists"
                                                      "DoesNotExist"
                                                    ]
                                                  );
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
                                  CIDRGroupSelector selects CiliumCIDRGroups by their labels,
                                  rather than by name.
                                '';
                              };
                              except = mkOption {
                                type = (types.nullOr (types.listOf types.str));
                                default = null;
                                description = ''
                                  ExceptCIDRs is a list of IP blocks which the endpoint subject to the rule
                                  is not allowed to initiate connections to. These CIDR prefixes should be
                                  contained within Cidr, using ExceptCIDRs together with CIDRGroupRef is not
                                  supported yet.
                                  These exceptions are only applied to the Cidr in this CIDRRule, and do not
                                  apply to any other CIDR prefixes in any other CIDRRules.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        FromCIDRSet is a list of IP blocks which the endpoint subject to the
                        rule is allowed to receive connections from in addition to FromEndpoints,
                        along with a list of subnets contained within their corresponding IP block
                        from which traffic should not be allowed.
                        This will match on the source IP address of incoming connections. Adding
                        a prefix into FromCIDR or into FromCIDRSet with no ExcludeCIDRs is
                        equivalent. Overlaps are allowed between FromCIDR and FromCIDRSet.

                        Example:
                        Any endpoint with the label "app=my-legacy-pet" is allowed to receive
                        connections from 10.0.0.0/8 except from IPs in subnet 10.96.0.0/12.
                      '';
                    };
                    fromEndpoints = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromEndpoints is a list of endpoints identified by an
                        EndpointSelector which are allowed to communicate with the endpoint
                        subject to the rule.

                        Example:
                        Any endpoint with the label "role=backend" can be consumed by any
                        endpoint carrying the label "role=frontend".
                      '';
                    };
                    fromEntities = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (
                            types.enum [
                              "all"
                              "world"
                              "cluster"
                              "host"
                              "init"
                              "ingress"
                              "unmanaged"
                              "remote-node"
                              "health"
                              "none"
                              "kube-apiserver"
                            ]
                          )
                        )
                      );
                      default = null;
                      description = ''
                        FromEntities is a list of special entities which the endpoint subject
                        to the rule is allowed to receive connections from. Supported entities are
                        `world`, `cluster` and `host`
                      '';
                    };
                    fromGroups = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              aws = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      labels = mkOption {
                                        type = (types.nullOr (types.attrsOf types.str));
                                        default = null;
                                      };
                                      region = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                      };
                                      securityGroupsIds = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                      securityGroupsNames = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = "AWSGroup is an structure that can be used to whitelisting information from AWS integration";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        FromGroups is a directive that allows the integration with multiple outside
                        providers. Currently, only AWS is supported, and the rule can select by
                        multiple sub directives:

                        Example:
                        FromGroups:
                        - aws:
                            securityGroupsIds:
                            - 'sg-XXXXXXXXXXXXX'
                      '';
                    };
                    fromNodes = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromNodes is a list of nodes identified by an
                        EndpointSelector which are allowed to communicate with the endpoint
                        subject to the rule.
                      '';
                    };
                    fromRequires = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
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
                                          type = (
                                            types.enum [
                                              "In"
                                              "NotIn"
                                              "Exists"
                                              "DoesNotExist"
                                            ]
                                          );
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
                        )
                      );
                      default = null;
                      description = ''
                        FromRequires is a list of additional constraints which must be met
                        in order for the selected endpoints to be reachable. These
                        additional constraints do no by itself grant access privileges and
                        must always be accompanied with at least one matching FromEndpoints.

                        Example:
                        Any Endpoint with the label "team=A" requires consuming endpoint
                        to also carry the label "team=A".
                      '';
                    };
                    icmps = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              fields = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        family = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "IPv4"
                                                "IPv6"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Family is a IP address version.
                                            Currently, we support `IPv4` and `IPv6`.
                                            `IPv4` is set as default.
                                          '';
                                        };
                                        type = mkOption {
                                          type = types.anything;
                                          description = ''
                                            Type is a ICMP-type.
                                            It should be an 8bit code (0-255), or it's CamelCase name (for example, "EchoReply").
                                            Allowed ICMP types are:
                                                Ipv4: EchoReply | DestinationUnreachable | Redirect | Echo | EchoRequest |
                                            		     RouterAdvertisement | RouterSelection | TimeExceeded | ParameterProblem |
                                            			 Timestamp | TimestampReply | Photuris | ExtendedEcho Request | ExtendedEcho Reply
                                                Ipv6: DestinationUnreachable | PacketTooBig | TimeExceeded | ParameterProblem |
                                            			 EchoRequest | EchoReply | MulticastListenerQuery| MulticastListenerReport |
                                            			 MulticastListenerDone | RouterSolicitation | RouterAdvertisement | NeighborSolicitation |
                                            			 NeighborAdvertisement | RedirectMessage | RouterRenumbering | ICMPNodeInformationQuery |
                                            			 ICMPNodeInformationResponse | InverseNeighborDiscoverySolicitation | InverseNeighborDiscoveryAdvertisement |
                                            			 HomeAgentAddressDiscoveryRequest | HomeAgentAddressDiscoveryReply | MobilePrefixSolicitation |
                                            			 MobilePrefixAdvertisement | DuplicateAddressRequestCodeSuffix | DuplicateAddressConfirmationCodeSuffix |
                                            			 ExtendedEchoRequest | ExtendedEchoReply
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Fields is a list of ICMP fields.";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ICMPs is a list of ICMP rule identified by type number
                        which the endpoint subject to the rule is not allowed to
                        receive connections on.

                        Example:
                        Any endpoint with the label "app=httpd" can not accept incoming
                        type 8 ICMP connections.
                      '';
                    };
                    toPorts = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              ports = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        endPort = mkOption {
                                          type = (types.nullOr types.int);
                                          default = null;
                                          description = "EndPort can only be an L4 port number.";
                                        };
                                        port = mkOption {
                                          type = types.str;
                                          description = ''
                                            Port can be an L4 port number, or a name in the form of "http"
                                            or "http-8080".
                                          '';
                                        };
                                        protocol = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "TCP"
                                                "UDP"
                                                "SCTP"
                                                "ANY"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Protocol is the L4 protocol. If omitted or empty, any protocol
                                            matches. Accepted values: "TCP", "UDP", "SCTP", "ANY"

                                            Matching on ICMP is not supported.

                                            Named port specified for a container may narrow this down, but may not
                                            contradict this.
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = "Ports is a list of L4 port/protocol";
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        ToPorts is a list of destination ports identified by port number and
                        protocol which the endpoint subject to the rule is not allowed to
                        receive connections on.

                        Example:
                        Any endpoint with the label "app=httpd" can not accept incoming
                        connections on port 80/tcp.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              IngressDeny is a list of IngressDenyRule which are enforced at ingress.
              Any rule inserted here will be denied regardless of the allowed ingress
              rules in the 'ingress' field.
              If omitted or empty, this rule does not apply at ingress.
            '';
          };
          labels = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    key = mkOption {
                      type = types.str;
                    };
                    source = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "Source can be one of the above values (e.g.: LabelSourceContainer).";
                    };
                    value = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Labels is a list of optional strings which can be used to
              re-identify the rule or to store metadata. It is possible to lookup
              or delete strings based on labels. Labels are not required to be
              unique, multiple rules can have overlapping or identical labels.
            '';
          };
          nodeSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
              NodeSelector selects all nodes which should be subject to this rule.
              EndpointSelector and NodeSelector cannot be both empty and are mutually
              exclusive. Can only be used in CiliumClusterwideNetworkPolicies.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumNodeConfig = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumNodeConfig";
    specType = (
      mkTypedSubmodule {
        options = {
          defaults = mkOption {
            type = (types.attrsOf types.str);
            description = ''
              Defaults is treated the same as the cilium-config ConfigMap - a set
              of key-value pairs parsed by the agent and operator processes.
              Each key must be a valid config-map data field (i.e. a-z, A-Z, -, _, and .)
            '';
          };
          nodeSelector = mkOption {
            type = (
              mkTypedSubmodule {
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
              }
            );
            description = ''
              NodeSelector is a label selector that determines to which nodes
              this configuration applies.
              If not supplied, then this config applies to no nodes. If
              empty, then it applies to all nodes.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumNode = mkResource {
    apiVersion = "cilium.io/v2";
    kind = "CiliumNode";
    specType = (
      mkTypedSubmodule {
        options = {
          addresses = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    ip = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "IP is an IP of a node";
                    };
                    type = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "Type is the type of the node address";
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = "Addresses is the list of all node addresses.";
          };
          "alibaba-cloud" = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  "availability-zone" = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      AvailabilityZone is the availability zone to use when allocating
                      ENIs.
                    '';
                  };
                  "cidr-block" = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = "CIDRBlock is vpc ipv4 CIDR";
                  };
                  "instance-type" = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = "InstanceType is the ECS instance type, e.g. \"ecs.g6.2xlarge\"";
                  };
                  "security-group-tags" = mkOption {
                    type = (types.nullOr (types.attrsOf types.str));
                    default = null;
                    description = ''
                      SecurityGroupTags is the list of tags to use when evaluating which
                      security groups to use for the ENI.
                    '';
                  };
                  "security-groups" = mkOption {
                    type = (types.nullOr (types.listOf types.str));
                    default = null;
                    description = ''
                      SecurityGroups is the list of security groups to attach to any ENI
                      that is created and attached to the instance.
                    '';
                  };
                  "vpc-id" = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = "VPCID is the VPC ID to use when allocating ENIs.";
                  };
                  "vswitch-tags" = mkOption {
                    type = (types.nullOr (types.attrsOf types.str));
                    default = null;
                    description = ''
                      VSwitchTags is the list of tags to use when evaluating which
                      vSwitch to use for the ENI.
                    '';
                  };
                  vswitches = mkOption {
                    type = (types.nullOr (types.listOf types.str));
                    default = null;
                    description = "VSwitches is the ID of vSwitch available for ENI";
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = "AlibabaCloud is the AlibabaCloud IPAM specific configuration.";
          };
          azure = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  "interface-name" = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      InterfaceName is the name of the interface the cilium-operator
                      will use to allocate all the IPs on
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = "Azure is the Azure IPAM specific configuration.";
          };
          bootid = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = "BootID is a unique node identifier generated on boot";
          };
          encryption = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  key = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      Key is the index to the key to use for encryption or 0 if encryption is
                      disabled.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = "Encryption is the encryption configuration of the node.";
          };
          eni = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  "availability-zone" = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      AvailabilityZone is the availability zone to use when allocating
                      ENIs.
                    '';
                  };
                  "delete-on-termination" = mkOption {
                    type = (types.nullOr types.bool);
                    default = null;
                    description = ''
                      DeleteOnTermination defines that the ENI should be deleted when the
                      associated instance is terminated. If the parameter is not set the
                      default behavior is to delete the ENI on instance termination.
                    '';
                  };
                  "disable-prefix-delegation" = mkOption {
                    type = (types.nullOr types.bool);
                    default = null;
                    description = ''
                      DisablePrefixDelegation determines whether ENI prefix delegation should be
                      disabled on this node.
                    '';
                  };
                  "exclude-interface-tags" = mkOption {
                    type = (types.nullOr (types.attrsOf types.str));
                    default = null;
                    description = ''
                      ExcludeInterfaceTags is the list of tags to use when excluding ENIs for
                      Cilium IP allocation. Any interface matching this set of tags will not
                      be managed by Cilium.
                    '';
                  };
                  "first-interface-index" = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      FirstInterfaceIndex is the index of the first ENI to use for IP
                      allocation, e.g. if the node has eth0, eth1, eth2 and
                      FirstInterfaceIndex is set to 1, then only eth1 and eth2 will be
                      used for IP allocation, eth0 will be ignored for PodIP allocation.
                    '';
                  };
                  "instance-id" = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      InstanceID is the AWS InstanceId of the node. The InstanceID is used
                      to retrieve AWS metadata for the node.

                      OBSOLETE: This field is obsolete, please use Spec.InstanceID
                    '';
                  };
                  "instance-type" = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = "InstanceType is the AWS EC2 instance type, e.g. \"m5.large\"";
                  };
                  "max-above-watermark" = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      MaxAboveWatermark is the maximum number of addresses to allocate
                      beyond the addresses needed to reach the PreAllocate watermark.
                      Going above the watermark can help reduce the number of API calls to
                      allocate IPs, e.g. when a new ENI is allocated, as many secondary
                      IPs as possible are allocated. Limiting the amount can help reduce
                      waste of IPs.

                      OBSOLETE: This field is obsolete, please use Spec.IPAM.MaxAboveWatermark
                    '';
                  };
                  "min-allocate" = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      MinAllocate is the minimum number of IPs that must be allocated when
                      the node is first bootstrapped. It defines the minimum base socket
                      of addresses that must be available. After reaching this watermark,
                      the PreAllocate and MaxAboveWatermark logic takes over to continue
                      allocating IPs.

                      OBSOLETE: This field is obsolete, please use Spec.IPAM.MinAllocate
                    '';
                  };
                  "node-subnet-id" = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      NodeSubnetID is the subnet of the primary ENI the instance was brought up
                      with. It is used as a sensible default subnet to create ENIs in.
                    '';
                  };
                  "pre-allocate" = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      PreAllocate defines the number of IP addresses that must be
                      available for allocation in the IPAMspec. It defines the buffer of
                      addresses available immediately without requiring cilium-operator to
                      get involved.

                      OBSOLETE: This field is obsolete, please use Spec.IPAM.PreAllocate
                    '';
                  };
                  "security-group-tags" = mkOption {
                    type = (types.nullOr (types.attrsOf types.str));
                    default = null;
                    description = ''
                      SecurityGroupTags is the list of tags to use when evaliating what
                      AWS security groups to use for the ENI.
                    '';
                  };
                  "security-groups" = mkOption {
                    type = (types.nullOr (types.listOf types.str));
                    default = null;
                    description = ''
                      SecurityGroups is the list of security groups to attach to any ENI
                      that is created and attached to the instance.
                    '';
                  };
                  "subnet-ids" = mkOption {
                    type = (types.nullOr (types.listOf types.str));
                    default = null;
                    description = ''
                      SubnetIDs is the list of subnet ids to use when evaluating what AWS
                      subnets to use for ENI and IP allocation.
                    '';
                  };
                  "subnet-tags" = mkOption {
                    type = (types.nullOr (types.attrsOf types.str));
                    default = null;
                    description = ''
                      SubnetTags is the list of tags to use when evaluating what AWS
                      subnets to use for ENI and IP allocation.
                    '';
                  };
                  "use-primary-address" = mkOption {
                    type = (types.nullOr types.bool);
                    default = null;
                    description = ''
                      UsePrimaryAddress determines whether an ENI's primary address
                      should be available for allocations on the node
                    '';
                  };
                  "vpc-id" = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = "VpcID is the VPC ID to use when allocating ENIs.";
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = "ENI is the AWS ENI specific configuration.";
          };
          health = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  ipv4 = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = "IPv4 is the IPv4 address of the IPv4 health endpoint.";
                  };
                  ipv6 = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = "IPv6 is the IPv6 address of the IPv4 health endpoint.";
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              HealthAddressing is the addressing information for health connectivity
              checking.
            '';
          };
          ingress = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  ipv4 = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                  };
                  ipv6 = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = "IngressAddressing is the addressing information for Ingress listener.";
          };
          "instance-id" = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = ''
              InstanceID is the identifier of the node. This is different from the
              node name which is typically the FQDN of the node. The InstanceID
              typically refers to the identifier used by the cloud provider or
              some other means of identification.
            '';
          };
          ipam = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  "ipv6-pool" = mkOption {
                    type = (
                      types.nullOr (
                        types.attrsOf (mkTypedSubmodule {
                          options = {
                            owner = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Owner is the owner of the IP. This field is set if the IP has been
                                allocated. It will be set to the pod name or another identifier
                                representing the usage of the IP

                                The owner field is left blank for an entry in Spec.IPAM.Pool and
                                filled out as the IP is used and also added to Status.IPAM.Used.
                              '';
                            };
                            resource = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Resource is set for both available and allocated IPs, it represents
                                what resource the IP is associated with, e.g. in combination with
                                AWS ENI, this will refer to the ID of the ENI
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = ''
                      IPv6Pool is the list of IPv6 addresses available to the node for allocation.
                      When an IPv6 address is used, it will remain on this list but will be added to
                      Status.IPAM.IPv6Used
                    '';
                  };
                  "max-above-watermark" = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      MaxAboveWatermark is the maximum number of addresses to allocate
                      beyond the addresses needed to reach the PreAllocate watermark.
                      Going above the watermark can help reduce the number of API calls to
                      allocate IPs, e.g. when a new ENI is allocated, as many secondary
                      IPs as possible are allocated. Limiting the amount can help reduce
                      waste of IPs.
                    '';
                  };
                  "max-allocate" = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      MaxAllocate is the maximum number of IPs that can be allocated to the
                      node. When the current amount of allocated IPs will approach this value,
                      the considered value for PreAllocate will decrease down to 0 in order to
                      not attempt to allocate more addresses than defined.
                    '';
                  };
                  "min-allocate" = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      MinAllocate is the minimum number of IPs that must be allocated when
                      the node is first bootstrapped. It defines the minimum base socket
                      of addresses that must be available. After reaching this watermark,
                      the PreAllocate and MaxAboveWatermark logic takes over to continue
                      allocating IPs.
                    '';
                  };
                  podCIDRs = mkOption {
                    type = (types.nullOr (types.listOf types.str));
                    default = null;
                    description = ''
                      PodCIDRs is the list of CIDRs available to the node for allocation.
                      When an IP is used, the IP will be added to Status.IPAM.Used
                    '';
                  };
                  pool = mkOption {
                    type = (
                      types.nullOr (
                        types.attrsOf (mkTypedSubmodule {
                          options = {
                            owner = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Owner is the owner of the IP. This field is set if the IP has been
                                allocated. It will be set to the pod name or another identifier
                                representing the usage of the IP

                                The owner field is left blank for an entry in Spec.IPAM.Pool and
                                filled out as the IP is used and also added to Status.IPAM.Used.
                              '';
                            };
                            resource = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Resource is set for both available and allocated IPs, it represents
                                what resource the IP is associated with, e.g. in combination with
                                AWS ENI, this will refer to the ID of the ENI
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = ''
                      Pool is the list of IPv4 addresses available to the node for allocation.
                      When an IPv4 address is used, it will remain on this list but will be added to
                      Status.IPAM.Used
                    '';
                  };
                  pools = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          allocated = mkOption {
                            type = (
                              types.nullOr (
                                types.listOf (mkTypedSubmodule {
                                  options = {
                                    cidrs = mkOption {
                                      type = (types.nullOr (types.listOf types.str));
                                      default = null;
                                      description = "CIDRs contains a list of pod CIDRs currently allocated from this pool";
                                    };
                                    pool = mkOption {
                                      type = types.str;
                                      description = "Pool is the name of the IPAM pool backing this allocation";
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              )
                            );
                            default = null;
                            description = ''
                              Allocated contains the list of pooled CIDR assigned to this node. The
                              operator will add new pod CIDRs to this field, whereas the agent will
                              remove CIDRs it has released.
                            '';
                          };
                          requested = mkOption {
                            type = (
                              types.nullOr (
                                types.listOf (mkTypedSubmodule {
                                  options = {
                                    needed = mkOption {
                                      type = (
                                        types.nullOr (mkTypedSubmodule {
                                          options = {
                                            "ipv4-addrs" = mkOption {
                                              type = (types.nullOr types.int);
                                              default = null;
                                              description = ''
                                                IPv4Addrs contains the number of requested IPv4 addresses out of a given
                                                pool
                                              '';
                                            };
                                            "ipv6-addrs" = mkOption {
                                              type = (types.nullOr types.int);
                                              default = null;
                                              description = ''
                                                IPv6Addrs contains the number of requested IPv6 addresses out of a given
                                                pool
                                              '';
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      );
                                      default = null;
                                      description = ''
                                        Needed indicates how many IPs out of the above Pool this node requests
                                        from the operator. The operator runs a reconciliation loop to ensure each
                                        node always has enough PodCIDRs allocated in each pool to fulfill the
                                        requested number of IPs here.
                                      '';
                                    };
                                    pool = mkOption {
                                      type = types.str;
                                      description = "Pool is the name of the IPAM pool backing this request";
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              )
                            );
                            default = null;
                            description = ''
                              Requested contains a list of IPAM pool requests, i.e. indicates how many
                              addresses this node requests out of each pool listed here. This field
                              is owned and written to by cilium-agent and read by the operator.
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = "Pools contains the list of assigned IPAM pools for this node.";
                  };
                  "pre-allocate" = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      PreAllocate defines the number of IP addresses that must be
                      available for allocation in the IPAMspec. It defines the buffer of
                      addresses available immediately without requiring cilium-operator to
                      get involved.
                    '';
                  };
                  "static-ip-tags" = mkOption {
                    type = (types.nullOr (types.attrsOf types.str));
                    default = null;
                    description = ''
                      StaticIPTags are used to determine the pool of IPs from which to
                      attribute a static IP to the node. For example in AWS this is used to
                      filter Elastic IP Addresses.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              IPAM is the address management specification. This section can be
              populated by a user or it can be automatically populated by an IPAM
              operator.
            '';
          };
          nodeidentity = mkOption {
            type = (types.nullOr types.int);
            default = null;
            description = "NodeIdentity is the Cilium numeric identity allocated for the node, if any.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumBGPAdvertisement = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumBGPAdvertisement";
    specType = (
      mkTypedSubmodule {
        options = {
          advertisements = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  advertisementType = mkOption {
                    type = (
                      types.enum [
                        "PodCIDR"
                        "CiliumPodIPPool"
                        "Service"
                      ]
                    );
                    description = "AdvertisementType defines type of advertisement which has to be advertised.";
                  };
                  attributes = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          communities = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  large = mkOption {
                                    type = (types.nullOr (types.listOf types.str));
                                    default = null;
                                    description = "Large holds a list of the BGP Large Communities Attribute (RFC 8092) values.";
                                  };
                                  standard = mkOption {
                                    type = (types.nullOr (types.listOf types.str));
                                    default = null;
                                    description = "Standard holds a list of \"standard\" 32-bit BGP Communities Attribute (RFC 1997) values defined as numeric values.";
                                  };
                                  wellKnown = mkOption {
                                    type = (
                                      types.nullOr (
                                        types.listOf (
                                          types.enum [
                                            "internet"
                                            "planned-shut"
                                            "accept-own"
                                            "route-filter-translated-v4"
                                            "route-filter-v4"
                                            "route-filter-translated-v6"
                                            "route-filter-v6"
                                            "llgr-stale"
                                            "no-llgr"
                                            "blackhole"
                                            "no-export"
                                            "no-advertise"
                                            "no-export-subconfed"
                                            "no-peer"
                                          ]
                                        )
                                      )
                                    );
                                    default = null;
                                    description = ''
                                      WellKnown holds a list "standard" 32-bit BGP Communities Attribute (RFC 1997) values defined as
                                      well-known string aliases to their numeric values.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              Communities sets the community attributes in the route.
                              If not specified, no community attribute is set.
                            '';
                          };
                          localPreference = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              LocalPreference sets the local preference attribute in the route.
                              If not specified, no local preference attribute is set.
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      Attributes defines additional attributes to set to the advertised routes.
                      If not specified, no additional attributes are set.
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
                                      type = (
                                        types.enum [
                                          "In"
                                          "NotIn"
                                          "Exists"
                                          "DoesNotExist"
                                        ]
                                      );
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
                      Selector is a label selector to select objects of the type specified by AdvertisementType.
                      If not specified, no objects of the type specified by AdvertisementType are selected for advertisement.
                    '';
                  };
                  service = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          addresses = mkOption {
                            type = (
                              types.listOf (
                                types.enum [
                                  "LoadBalancerIP"
                                  "ClusterIP"
                                  "ExternalIP"
                                ]
                              )
                            );
                            description = "Addresses is a list of service address types which needs to be advertised via BGP.";
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = "Service defines configuration options for advertisementType service.";
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = "Advertisements is a list of BGP advertisements.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumBGPClusterConfig = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumBGPClusterConfig";
    specType = (
      mkTypedSubmodule {
        options = {
          bgpInstances = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  localASN = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      LocalASN is the ASN of this BGP instance.
                      Supports extended 32bit ASNs.
                    '';
                  };
                  name = mkOption {
                    type = types.str;
                    description = ''
                      Name is the name of the BGP instance. It is a unique identifier for the BGP instance
                      within the cluster configuration.
                    '';
                  };
                  peers = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (mkTypedSubmodule {
                          options = {
                            name = mkOption {
                              type = types.str;
                              description = "Name is the name of the BGP peer. It is a unique identifier for the peer within the BGP instance.";
                            };
                            peerASN = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                PeerASN is the ASN of the peer BGP router.
                                Supports extended 32bit ASNs.

                                If peerASN is 0, the BGP OPEN message validation of ASN will be disabled and
                                ASN will be determined based on peer's OPEN message.
                              '';
                            };
                            peerAddress = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                PeerAddress is the IP address of the neighbor.
                                Supports IPv4 and IPv6 addresses.
                              '';
                            };
                            peerConfigRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    group = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Group is the group of the peer config resource.
                                        If not specified, the default of "cilium.io" is used.
                                      '';
                                    };
                                    kind = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Kind is the kind of the peer config resource.
                                        If not specified, the default of "CiliumBGPPeerConfig" is used.
                                      '';
                                    };
                                    name = mkOption {
                                      type = types.str;
                                      description = ''
                                        Name is the name of the peer config resource.
                                        Name refers to the name of a Kubernetes object (typically a CiliumBGPPeerConfig).
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                PeerConfigRef is a reference to a peer configuration resource.
                                If not specified, the default BGP configuration is used for this peer.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = "Peers is a list of neighboring BGP peers for this virtual router";
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              A list of CiliumBGPInstance(s) which instructs
              the BGP control plane how to instantiate virtual BGP routers.
            '';
          };
          nodeSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
              NodeSelector selects a group of nodes where this BGP Cluster
              config applies.
              If empty / nil this config applies to all nodes.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumBGPNodeConfigOverride = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumBGPNodeConfigOverride";
    specType = (
      mkTypedSubmodule {
        options = {
          bgpInstances = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  localPort = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = "LocalPort is port to use for this BGP instance.";
                  };
                  name = mkOption {
                    type = types.str;
                    description = "Name is the name of the BGP instance for which the configuration is overridden.";
                  };
                  peers = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (mkTypedSubmodule {
                          options = {
                            localAddress = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = "LocalAddress is the IP address to use for connecting to this peer.";
                            };
                            localPort = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = "LocalPort is source port to use for connecting to this peer.";
                            };
                            name = mkOption {
                              type = types.str;
                              description = "Name is the name of the peer for which the configuration is overridden.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = "Peers is a list of peer configurations to override.";
                  };
                  routerID = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = "RouterID is BGP router id to use for this instance. It must be unique across all BGP instances.";
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = "BGPInstances is a list of BGP instances to override.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumBGPNodeConfig = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumBGPNodeConfig";
    specType = (
      mkTypedSubmodule {
        options = {
          bgpInstances = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  localASN = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      LocalASN is the ASN of this virtual router.
                      Supports extended 32bit ASNs.
                    '';
                  };
                  localPort = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      LocalPort is the port on which the BGP daemon listens for incoming connections.

                      If not specified, BGP instance will not listen for incoming connections.
                    '';
                  };
                  name = mkOption {
                    type = types.str;
                    description = "Name is the name of the BGP instance. This name is used to identify the BGP instance on the node.";
                  };
                  peers = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (mkTypedSubmodule {
                          options = {
                            localAddress = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                LocalAddress is the IP address of the local interface to use for the peering session.
                                This configuration is derived from CiliumBGPNodeConfigOverride resource. If not specified, the local address will be used for setting up peering.
                              '';
                            };
                            name = mkOption {
                              type = types.str;
                              description = "Name is the name of the BGP peer. This name is used to identify the BGP peer for the BGP instance.";
                            };
                            peerASN = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                PeerASN is the ASN of the peer BGP router.
                                Supports extended 32bit ASNs
                              '';
                            };
                            peerAddress = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                PeerAddress is the IP address of the neighbor.
                                Supports IPv4 and IPv6 addresses.
                              '';
                            };
                            peerConfigRef = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    group = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Group is the group of the peer config resource.
                                        If not specified, the default of "cilium.io" is used.
                                      '';
                                    };
                                    kind = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Kind is the kind of the peer config resource.
                                        If not specified, the default of "CiliumBGPPeerConfig" is used.
                                      '';
                                    };
                                    name = mkOption {
                                      type = types.str;
                                      description = ''
                                        Name is the name of the peer config resource.
                                        Name refers to the name of a Kubernetes object (typically a CiliumBGPPeerConfig).
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                PeerConfigRef is a reference to a peer configuration resource.
                                If not specified, the default BGP configuration is used for this peer.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = "Peers is a list of neighboring BGP peers for this virtual router";
                  };
                  routerID = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      RouterID is the BGP router ID of this virtual router.
                      This configuration is derived from CiliumBGPNodeConfigOverride resource.

                      If not specified, the router ID will be derived from the node local address.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = "BGPInstances is a list of BGP router instances on the node.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumBGPPeerConfig = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumBGPPeerConfig";
    specType = (
      mkTypedSubmodule {
        options = {
          authSecretRef = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = ''
              AuthSecretRef is the name of the secret to use to fetch a TCP
              authentication password for this peer.

              If not specified, no authentication is used.
            '';
          };
          ebgpMultihop = mkOption {
            type = (types.nullOr types.int);
            default = null;
            description = ''
              EBGPMultihopTTL controls the multi-hop feature for eBGP peers.
              Its value defines the Time To Live (TTL) value used in BGP
              packets sent to the peer.

              If not specified, EBGP multihop is disabled. This field is ignored for iBGP neighbors.
            '';
          };
          families = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    advertisements = mkOption {
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
                                        type = (
                                          types.enum [
                                            "In"
                                            "NotIn"
                                            "Exists"
                                            "DoesNotExist"
                                          ]
                                        );
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
                        Advertisements selects group of BGP Advertisement(s) to advertise for this family.

                        If not specified, no advertisements are sent for this family.

                        This field is ignored in CiliumBGPNeighbor which is used in CiliumBGPPeeringPolicy.
                        Use CiliumBGPPeeringPolicy advertisement options instead.
                      '';
                    };
                    afi = mkOption {
                      type = (
                        types.enum [
                          "ipv4"
                          "ipv6"
                          "l2vpn"
                          "ls"
                          "opaque"
                        ]
                      );
                      description = "Afi is the Address Family Identifier (AFI) of the family.";
                    };
                    safi = mkOption {
                      type = (
                        types.enum [
                          "unicast"
                          "multicast"
                          "mpls_label"
                          "encapsulation"
                          "vpls"
                          "evpn"
                          "ls"
                          "sr_policy"
                          "mup"
                          "mpls_vpn"
                          "mpls_vpn_multicast"
                          "route_target_constraints"
                          "flowspec_unicast"
                          "flowspec_vpn"
                          "key_value"
                        ]
                      );
                      description = "Safi is the Subsequent Address Family Identifier (SAFI) of the family.";
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Families, if provided, defines a set of AFI/SAFIs the speaker will
              negotiate with it's peer.

              If not specified, the default families of IPv6/unicast and IPv4/unicast will be created.
            '';
          };
          gracefulRestart = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  enabled = mkOption {
                    type = types.bool;
                    description = "Enabled flag, when set enables graceful restart capability.";
                  };
                  restartTimeSeconds = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      RestartTimeSeconds is the estimated time it will take for the BGP
                      session to be re-established with peer after a restart.
                      After this period, peer will remove stale routes. This is
                      described RFC 4724 section 4.2.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              GracefulRestart defines graceful restart parameters which are negotiated
              with this peer.

              If not specified, the graceful restart capability is disabled.
            '';
          };
          timers = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  connectRetryTimeSeconds = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      ConnectRetryTimeSeconds defines the initial value for the BGP ConnectRetryTimer (RFC 4271, Section 8).

                      If not specified, defaults to 120 seconds.
                    '';
                  };
                  holdTimeSeconds = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      HoldTimeSeconds defines the initial value for the BGP HoldTimer (RFC 4271, Section 4.2).
                      Updating this value will cause a session reset.

                      If not specified, defaults to 90 seconds.
                    '';
                  };
                  keepAliveTimeSeconds = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      KeepaliveTimeSeconds defines the initial value for the BGP KeepaliveTimer (RFC 4271, Section 8).
                      It can not be larger than HoldTimeSeconds. Updating this value will cause a session reset.

                      If not specified, defaults to 30 seconds.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              Timers defines the BGP timers for the peer.

              If not specified, the default timers are used.
            '';
          };
          transport = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  localPort = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      Deprecated
                      LocalPort is the local port to be used for the BGP session.

                      If not specified, ephemeral port will be picked to initiate a connection.

                      This field is deprecated and will be removed in a future release.
                      Local port configuration is unnecessary and is not recommended.
                    '';
                  };
                  peerPort = mkOption {
                    type = (types.nullOr types.int);
                    default = null;
                    description = ''
                      PeerPort is the peer port to be used for the BGP session.

                      If not specified, defaults to TCP port 179.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              Transport defines the BGP transport parameters for the peer.

              If not specified, the default transport parameters are used.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumBGPPeeringPolicy = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumBGPPeeringPolicy";
    specType = (
      mkTypedSubmodule {
        options = {
          nodeSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
              NodeSelector selects a group of nodes where this BGP Peering
              Policy applies.

              If empty / nil this policy applies to all nodes.
            '';
          };
          virtualRouters = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  exportPodCIDR = mkOption {
                    type = (types.nullOr types.bool);
                    default = null;
                    description = ''
                      ExportPodCIDR determines whether to export the Node's private CIDR block
                      to the configured neighbors.
                    '';
                  };
                  localASN = mkOption {
                    type = types.int;
                    description = ''
                      LocalASN is the ASN of this virtual router.
                      Supports extended 32bit ASNs
                    '';
                  };
                  neighbors = mkOption {
                    type = (
                      types.listOf (mkTypedSubmodule {
                        options = {
                          advertisedPathAttributes = mkOption {
                            type = (
                              types.nullOr (
                                types.listOf (mkTypedSubmodule {
                                  options = {
                                    communities = mkOption {
                                      type = (
                                        types.nullOr (mkTypedSubmodule {
                                          options = {
                                            large = mkOption {
                                              type = (types.nullOr (types.listOf types.str));
                                              default = null;
                                              description = "Large holds a list of the BGP Large Communities Attribute (RFC 8092) values.";
                                            };
                                            standard = mkOption {
                                              type = (types.nullOr (types.listOf types.str));
                                              default = null;
                                              description = "Standard holds a list of \"standard\" 32-bit BGP Communities Attribute (RFC 1997) values defined as numeric values.";
                                            };
                                            wellKnown = mkOption {
                                              type = (
                                                types.nullOr (
                                                  types.listOf (
                                                    types.enum [
                                                      "internet"
                                                      "planned-shut"
                                                      "accept-own"
                                                      "route-filter-translated-v4"
                                                      "route-filter-v4"
                                                      "route-filter-translated-v6"
                                                      "route-filter-v6"
                                                      "llgr-stale"
                                                      "no-llgr"
                                                      "blackhole"
                                                      "no-export"
                                                      "no-advertise"
                                                      "no-export-subconfed"
                                                      "no-peer"
                                                    ]
                                                  )
                                                )
                                              );
                                              default = null;
                                              description = ''
                                                WellKnown holds a list "standard" 32-bit BGP Communities Attribute (RFC 1997) values defined as
                                                well-known string aliases to their numeric values.
                                              '';
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      );
                                      default = null;
                                      description = ''
                                        Communities defines a set of community values advertised in the supported BGP Communities path attributes.
                                        If nil / not set, no BGP Communities path attribute will be advertised.
                                      '';
                                    };
                                    localPreference = mkOption {
                                      type = (types.nullOr types.int);
                                      default = null;
                                      description = ''
                                        LocalPreference defines the preference value advertised in the BGP Local Preference path attribute.
                                        As Local Preference is only valid for iBGP peers, this value will be ignored for eBGP peers
                                        (no Local Preference path attribute will be advertised).
                                        If nil / not set, the default Local Preference of 100 will be advertised in
                                        the Local Preference path attribute for iBGP peers.
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
                                                        type = (
                                                          types.enum [
                                                            "In"
                                                            "NotIn"
                                                            "Exists"
                                                            "DoesNotExist"
                                                          ]
                                                        );
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
                                        Selector selects a group of objects of the SelectorType
                                        resulting into routes that will be announced with the configured Attributes.
                                        If nil / not set, all objects of the SelectorType are selected.
                                      '';
                                    };
                                    selectorType = mkOption {
                                      type = (
                                        types.enum [
                                          "PodCIDR"
                                          "CiliumLoadBalancerIPPool"
                                          "CiliumPodIPPool"
                                        ]
                                      );
                                      description = ''
                                        SelectorType defines the object type on which the Selector applies:
                                        - For "PodCIDR" the Selector matches k8s CiliumNode resources
                                          (path attributes apply to routes announced for PodCIDRs of selected CiliumNodes.
                                          Only affects routes of cluster scope / Kubernetes IPAM CIDRs, not Multi-Pool IPAM CIDRs.
                                        - For "CiliumLoadBalancerIPPool" the Selector matches CiliumLoadBalancerIPPool custom resources
                                          (path attributes apply to routes announced for selected CiliumLoadBalancerIPPools).
                                        - For "CiliumPodIPPool" the Selector matches CiliumPodIPPool custom resources
                                          (path attributes apply to routes announced for allocated CIDRs of selected CiliumPodIPPools).
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              )
                            );
                            default = null;
                            description = ''
                              AdvertisedPathAttributes can be used to apply additional path attributes
                              to selected routes when advertising them to the peer.
                              If empty / nil, no additional path attributes are advertised.
                            '';
                          };
                          authSecretRef = mkOption {
                            type = (types.nullOr types.str);
                            default = null;
                            description = ''
                              AuthSecretRef is the name of the secret to use to fetch a TCP
                              authentication password for this peer.
                            '';
                          };
                          connectRetryTimeSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = "ConnectRetryTimeSeconds defines the initial value for the BGP ConnectRetryTimer (RFC 4271, Section 8).";
                          };
                          eBGPMultihopTTL = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              EBGPMultihopTTL controls the multi-hop feature for eBGP peers.
                              Its value defines the Time To Live (TTL) value used in BGP packets sent to the neighbor.
                              The value 1 implies that eBGP multi-hop feature is disabled (only a single hop is allowed).
                              This field is ignored for iBGP peers.
                            '';
                          };
                          families = mkOption {
                            type = (
                              types.nullOr (
                                types.listOf (mkTypedSubmodule {
                                  options = {
                                    afi = mkOption {
                                      type = (
                                        types.enum [
                                          "ipv4"
                                          "ipv6"
                                          "l2vpn"
                                          "ls"
                                          "opaque"
                                        ]
                                      );
                                      description = "Afi is the Address Family Identifier (AFI) of the family.";
                                    };
                                    safi = mkOption {
                                      type = (
                                        types.enum [
                                          "unicast"
                                          "multicast"
                                          "mpls_label"
                                          "encapsulation"
                                          "vpls"
                                          "evpn"
                                          "ls"
                                          "sr_policy"
                                          "mup"
                                          "mpls_vpn"
                                          "mpls_vpn_multicast"
                                          "route_target_constraints"
                                          "flowspec_unicast"
                                          "flowspec_vpn"
                                          "key_value"
                                        ]
                                      );
                                      description = "Safi is the Subsequent Address Family Identifier (SAFI) of the family.";
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              )
                            );
                            default = null;
                            description = ''
                              Families, if provided, defines a set of AFI/SAFIs the speaker will
                              negotiate with it's peer.

                              If this slice is not provided the default families of IPv6 and IPv4 will
                              be provided.
                            '';
                          };
                          gracefulRestart = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  enabled = mkOption {
                                    type = types.bool;
                                    description = "Enabled flag, when set enables graceful restart capability.";
                                  };
                                  restartTimeSeconds = mkOption {
                                    type = (types.nullOr types.int);
                                    default = null;
                                    description = ''
                                      RestartTimeSeconds is the estimated time it will take for the BGP
                                      session to be re-established with peer after a restart.
                                      After this period, peer will remove stale routes. This is
                                      described RFC 4724 section 4.2.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              GracefulRestart defines graceful restart parameters which are negotiated
                              with this neighbor. If empty / nil, the graceful restart capability is disabled.
                            '';
                          };
                          holdTimeSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              HoldTimeSeconds defines the initial value for the BGP HoldTimer (RFC 4271, Section 4.2).
                              Updating this value will cause a session reset.
                            '';
                          };
                          keepAliveTimeSeconds = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              KeepaliveTimeSeconds defines the initial value for the BGP KeepaliveTimer (RFC 4271, Section 8).
                              It can not be larger than HoldTimeSeconds. Updating this value will cause a session reset.
                            '';
                          };
                          peerASN = mkOption {
                            type = types.int;
                            description = ''
                              PeerASN is the ASN of the peer BGP router.
                              Supports extended 32bit ASNs
                            '';
                          };
                          peerAddress = mkOption {
                            type = types.str;
                            description = ''
                              PeerAddress is the IP address of the peer.
                              This must be in CIDR notation and use a /32 to express
                              a single host.
                            '';
                          };
                          peerPort = mkOption {
                            type = (types.nullOr types.int);
                            default = null;
                            description = ''
                              PeerPort is the TCP port of the peer. 1-65535 is the range of
                              valid port numbers that can be specified. If unset, defaults to 179.
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    description = "Neighbors is a list of neighboring BGP peers for this virtual router";
                  };
                  podIPPoolSelector = mkOption {
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
                                      type = (
                                        types.enum [
                                          "In"
                                          "NotIn"
                                          "Exists"
                                          "DoesNotExist"
                                        ]
                                      );
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
                      PodIPPoolSelector selects CiliumPodIPPools based on labels. The virtual
                      router will announce allocated CIDRs of matching CiliumPodIPPools.

                      If empty / nil no CiliumPodIPPools will be announced.
                    '';
                  };
                  serviceAdvertisements = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (
                          types.enum [
                            "LoadBalancerIP"
                            "ClusterIP"
                            "ExternalIP"
                          ]
                        )
                      )
                    );
                    default = null;
                    description = ''
                      ServiceAdvertisements selects a group of BGP Advertisement(s) to advertise
                      for the selected services.
                    '';
                  };
                  serviceSelector = mkOption {
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
                                      type = (
                                        types.enum [
                                          "In"
                                          "NotIn"
                                          "Exists"
                                          "DoesNotExist"
                                        ]
                                      );
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
                      ServiceSelector selects a group of load balancer services which this
                      virtual router will announce. The loadBalancerClass for a service must
                      be nil or specify a class supported by Cilium, e.g. "io.cilium/bgp-control-plane".
                      Refer to the following document for additional details regarding load balancer
                      classes:

                        https://kubernetes.io/docs/concepts/services-networking/service/#load-balancer-class

                      If empty / nil no services will be announced.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              A list of CiliumBGPVirtualRouter(s) which instructs
              the BGP control plane how to instantiate virtual BGP routers.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumCIDRGroup = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumCIDRGroup";
    specType = (
      mkTypedSubmodule {
        options = {
          externalCIDRs = mkOption {
            type = (types.listOf types.str);
            description = "ExternalCIDRs is a list of CIDRs selecting peers outside the clusters.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumEndpointSlice = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumEndpointSlice";
    specType = types.attrs;
  };

  CiliumL2AnnouncementPolicy = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumL2AnnouncementPolicy";
    specType = (
      mkTypedSubmodule {
        options = {
          externalIPs = mkOption {
            type = (types.nullOr types.bool);
            default = null;
            description = "If true, the external IPs of the services are announced";
          };
          interfaces = mkOption {
            type = (types.nullOr (types.listOf types.str));
            default = null;
            description = ''
              A list of regular expressions that express which network interface(s) should be used
              to announce the services over. If nil, all network interfaces are used.
            '';
          };
          loadBalancerIPs = mkOption {
            type = (types.nullOr types.bool);
            default = null;
            description = ''
              If true, the loadbalancer IPs of the services are announced

              If nil this policy applies to all services.
            '';
          };
          nodeSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
              NodeSelector selects a group of nodes which will announce the IPs for
              the services selected by the service selector.

              If nil this policy applies to all nodes.
            '';
          };
          serviceSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
              ServiceSelector selects a set of services which will be announced over L2 networks.
              The loadBalancerClass for a service must be nil or specify a supported class, e.g.
              "io.cilium/l2-announcer". Refer to the following document for additional details
              regarding load balancer classes:

                https://kubernetes.io/docs/concepts/services-networking/service/#load-balancer-class

              If nil this policy applies to all services.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumLoadBalancerIPPool = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumLoadBalancerIPPool";
    specType = (
      mkTypedSubmodule {
        options = {
          allowFirstLastIPs = mkOption {
            type = (
              types.nullOr (
                types.enum [
                  "Yes"
                  "No"
                ]
              )
            );
            default = null;
            description = ''
              AllowFirstLastIPs, if set to `Yes` or undefined means that the first and last IPs of each CIDR will be allocatable.
              If `No`, these IPs will be reserved. This field is ignored for /{31,32} and /{127,128} CIDRs since
              reserving the first and last IPs would make the CIDRs unusable.
            '';
          };
          blocks = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    cidr = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                    };
                    start = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                    };
                    stop = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = "Blocks is a list of CIDRs comprising this IP Pool";
          };
          disabled = mkOption {
            type = (types.nullOr types.bool);
            default = null;
            description = ''
              Disabled, if set to true means that no new IPs will be allocated from this pool.
              Existing allocations will not be removed from services.
            '';
          };
          serviceSelector = mkOption {
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
                              type = (
                                types.enum [
                                  "In"
                                  "NotIn"
                                  "Exists"
                                  "DoesNotExist"
                                ]
                              );
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
            description = "ServiceSelector selects a set of services which are eligible to receive IPs from this";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  CiliumPodIPPool = mkResource {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumPodIPPool";
    specType = (
      mkTypedSubmodule {
        options = {
          ipv4 = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  cidrs = mkOption {
                    type = (types.listOf types.str);
                    description = "CIDRs is a list of IPv4 CIDRs that are part of the pool.";
                  };
                  maskSize = mkOption {
                    type = types.int;
                    description = "MaskSize is the mask size of the pool.";
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = "IPv4 specifies the IPv4 CIDRs and mask sizes of the pool";
          };
          ipv6 = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  cidrs = mkOption {
                    type = (types.listOf types.str);
                    description = "CIDRs is a list of IPv6 CIDRs that are part of the pool.";
                  };
                  maskSize = mkOption {
                    type = types.int;
                    description = "MaskSize is the mask size of the pool.";
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = "IPv6 specifies the IPv6 CIDRs and mask sizes of the pool";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

}
