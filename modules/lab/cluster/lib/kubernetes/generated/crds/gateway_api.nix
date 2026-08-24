{ lib, k8sTypes }:

let
  inherit (lib) mkOption types;
  inherit (k8sTypes) mkTypedSubmodule mkResource;
in
{
  BackendLBPolicy = mkResource {
    apiVersion = "gateway.networking.k8s.io/v1alpha2";
    kind = "BackendLBPolicy";
    specType = (
      mkTypedSubmodule {
        options = {
          sessionPersistence = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  absoluteTimeout = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      AbsoluteTimeout defines the absolute timeout of the persistent
                      session. Once the AbsoluteTimeout duration has elapsed, the
                      session becomes invalid.

                      Support: Extended
                    '';
                  };
                  cookieConfig = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          lifetimeType = mkOption {
                            type = (
                              types.nullOr (
                                types.enum [
                                  "Permanent"
                                  "Session"
                                ]
                              )
                            );
                            default = null;
                            description = ''
                              LifetimeType specifies whether the cookie has a permanent or
                              session-based lifetime. A permanent cookie persists until its
                              specified expiry time, defined by the Expires or Max-Age cookie
                              attributes, while a session cookie is deleted when the current
                              session ends.

                              When set to "Permanent", AbsoluteTimeout indicates the
                              cookie's lifetime via the Expires or Max-Age cookie attributes
                              and is required.

                              When set to "Session", AbsoluteTimeout indicates the
                              absolute lifetime of the cookie tracked by the gateway and
                              is optional.

                              Support: Core for "Session" type

                              Support: Extended for "Permanent" type
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      CookieConfig provides configuration settings that are specific
                      to cookie-based session persistence.

                      Support: Core
                    '';
                  };
                  idleTimeout = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      IdleTimeout defines the idle timeout of the persistent session.
                      Once the session has been idle for more than the specified
                      IdleTimeout duration, the session becomes invalid.

                      Support: Extended
                    '';
                  };
                  sessionName = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      SessionName defines the name of the persistent session token
                      which may be reflected in the cookie or the header. Users
                      should avoid reusing session names to prevent unintended
                      consequences, such as rejection or unpredictable behavior.

                      Support: Implementation-specific
                    '';
                  };
                  type = mkOption {
                    type = (
                      types.nullOr (
                        types.enum [
                          "Cookie"
                          "Header"
                        ]
                      )
                    );
                    default = null;
                    description = ''
                      Type defines the type of session persistence such as through
                      the use a header or cookie. Defaults to cookie based session
                      persistence.

                      Support: Core for "Cookie" type

                      Support: Extended for "Header" type
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              SessionPersistence defines and configures session persistence
              for the backend.

              Support: Extended
            '';
          };
          targetRefs = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  group = mkOption {
                    type = types.str;
                    description = "Group is the group of the target resource.";
                  };
                  kind = mkOption {
                    type = types.str;
                    description = "Kind is kind of the target resource.";
                  };
                  name = mkOption {
                    type = types.str;
                    description = "Name is the name of the target resource.";
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              TargetRef identifies an API object to apply policy to.
              Currently, Backends (i.e. Service, ServiceImport, or any
              implementation-specific backendRef) are the only valid API
              target references.
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  BackendTLSPolicy = mkResource {
    apiVersion = "gateway.networking.k8s.io/v1alpha3";
    kind = "BackendTLSPolicy";
    specType = (
      mkTypedSubmodule {
        options = {
          options = mkOption {
            type = (types.nullOr (types.attrsOf types.str));
            default = null;
            description = ''
              Options are a list of key/value pairs to enable extended TLS
              configuration for each implementation. For example, configuring the
              minimum TLS version or supported cipher suites.

              A set of common keys MAY be defined by the API in the future. To avoid
              any ambiguity, implementation-specific definitions MUST use
              domain-prefixed names, such as `example.com/my-custom-option`.
              Un-prefixed names are reserved for key names defined by Gateway API.

              Support: Implementation-specific
            '';
          };
          targetRefs = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  group = mkOption {
                    type = types.str;
                    description = "Group is the group of the target resource.";
                  };
                  kind = mkOption {
                    type = types.str;
                    description = "Kind is kind of the target resource.";
                  };
                  name = mkOption {
                    type = types.str;
                    description = "Name is the name of the target resource.";
                  };
                  sectionName = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      SectionName is the name of a section within the target resource. When
                      unspecified, this targetRef targets the entire resource. In the following
                      resources, SectionName is interpreted as the following:

                      * Gateway: Listener name
                      * HTTPRoute: HTTPRouteRule name
                      * Service: Port name

                      If a SectionName is specified, but does not exist on the targeted object,
                      the Policy must fail to attach, and the policy implementation should record
                      a `ResolvedRefs` or similar Condition in the Policy's status.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              TargetRefs identifies an API object to apply the policy to.
              Only Services have Extended support. Implementations MAY support
              additional objects, with Implementation Specific support.
              Note that this config applies to the entire referenced resource
              by default, but this default may change in the future to provide
              a more granular application of the policy.

              Support: Extended for Kubernetes Service

              Support: Implementation-specific for any other resource
            '';
          };
          validation = mkOption {
            type = (
              mkTypedSubmodule {
                options = {
                  caCertificateRefs = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (mkTypedSubmodule {
                          options = {
                            group = mkOption {
                              type = types.str;
                              description = ''
                                Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                When unspecified or empty string, core API group is inferred.
                              '';
                            };
                            kind = mkOption {
                              type = types.str;
                              description = "Kind is kind of the referent. For example \"HTTPRoute\" or \"Service\".";
                            };
                            name = mkOption {
                              type = types.str;
                              description = "Name is the name of the referent.";
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = ''
                      CACertificateRefs contains one or more references to Kubernetes objects that
                      contain a PEM-encoded TLS CA certificate bundle, which is used to
                      validate a TLS handshake between the Gateway and backend Pod.

                      If CACertificateRefs is empty or unspecified, then WellKnownCACertificates must be
                      specified. Only one of CACertificateRefs or WellKnownCACertificates may be specified,
                      not both. If CACertifcateRefs is empty or unspecified, the configuration for
                      WellKnownCACertificates MUST be honored instead if supported by the implementation.

                      References to a resource in a different namespace are invalid for the
                      moment, although we will revisit this in the future.

                      A single CACertificateRef to a Kubernetes ConfigMap kind has "Core" support.
                      Implementations MAY choose to support attaching multiple certificates to
                      a backend, but this behavior is implementation-specific.

                      Support: Core - An optional single reference to a Kubernetes ConfigMap,
                      with the CA certificate in a key named `ca.crt`.

                      Support: Implementation-specific (More than one reference, or other kinds
                      of resources).
                    '';
                  };
                  hostname = mkOption {
                    type = types.str;
                    description = ''
                      Hostname is used for two purposes in the connection between Gateways and
                      backends:

                      1. Hostname MUST be used as the SNI to connect to the backend (RFC 6066).
                      2. If SubjectAltNames is not specified, Hostname MUST be used for
                         authentication and MUST match the certificate served by the matching
                         backend.

                      Support: Core
                    '';
                  };
                  subjectAltNames = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (mkTypedSubmodule {
                          options = {
                            hostname = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Hostname contains Subject Alternative Name specified in DNS name format.
                                Required when Type is set to Hostname, ignored otherwise.

                                Support: Core
                              '';
                            };
                            type = mkOption {
                              type = (
                                types.enum [
                                  "Hostname"
                                  "URI"
                                ]
                              );
                              description = ''
                                Type determines the format of the Subject Alternative Name. Always required.

                                Support: Core
                              '';
                            };
                            uri = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                URI contains Subject Alternative Name specified in a full URI format.
                                It MUST include both a scheme (e.g., "http" or "ftp") and a scheme-specific-part.
                                Common values include SPIFFE IDs like "spiffe://mycluster.example.com/ns/myns/sa/svc1sa".
                                Required when Type is set to URI, ignored otherwise.

                                Support: Core
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = ''
                      SubjectAltNames contains one or more Subject Alternative Names.
                      When specified, the certificate served from the backend MUST have at least one
                      Subject Alternate Name matching one of the specified SubjectAltNames.

                      Support: Core
                    '';
                  };
                  wellKnownCACertificates = mkOption {
                    type = (types.nullOr (types.enum [ "System" ]));
                    default = null;
                    description = ''
                      WellKnownCACertificates specifies whether system CA certificates may be used in
                      the TLS handshake between the gateway and backend pod.

                      If WellKnownCACertificates is unspecified or empty (""), then CACertificateRefs
                      must be specified with at least one entry for a valid configuration. Only one of
                      CACertificateRefs or WellKnownCACertificates may be specified, not both. If an
                      implementation does not support the WellKnownCACertificates field or the value
                      supplied is not supported, the Status Conditions on the Policy MUST be
                      updated to include an Accepted: False Condition with Reason: Invalid.

                      Support: Implementation-specific
                    '';
                  };
                };
                freeformType = types.attrs;
              }
            );
            description = "Validation contains backend TLS validation configuration.";
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  GatewayClass = mkResource {
    apiVersion = "gateway.networking.k8s.io/v1";
    kind = "GatewayClass";
    specType = (
      mkTypedSubmodule {
        options = {
          controllerName = mkOption {
            type = types.str;
            description = ''
              ControllerName is the name of the controller that is managing Gateways of
              this class. The value of this field MUST be a domain prefixed path.

              Example: "example.net/gateway-controller".

              This field is not mutable and cannot be empty.

              Support: Core
            '';
          };
          description = mkOption {
            type = (types.nullOr types.str);
            default = null;
            description = "Description helps describe a GatewayClass with more details.";
          };
          parametersRef = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  group = mkOption {
                    type = types.str;
                    description = "Group is the group of the referent.";
                  };
                  kind = mkOption {
                    type = types.str;
                    description = "Kind is kind of the referent.";
                  };
                  name = mkOption {
                    type = types.str;
                    description = "Name is the name of the referent.";
                  };
                  namespace = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      Namespace is the namespace of the referent.
                      This field is required when referring to a Namespace-scoped resource and
                      MUST be unset when referring to a Cluster-scoped resource.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              ParametersRef is a reference to a resource that contains the configuration
              parameters corresponding to the GatewayClass. This is optional if the
              controller does not require any additional configuration.

              ParametersRef can reference a standard Kubernetes resource, i.e. ConfigMap,
              or an implementation-specific custom resource. The resource can be
              cluster-scoped or namespace-scoped.

              If the referent cannot be found, refers to an unsupported kind, or when
              the data within that resource is malformed, the GatewayClass SHOULD be
              rejected with the "Accepted" status condition set to "False" and an
              "InvalidParameters" reason.

              A Gateway for this GatewayClass may provide its own `parametersRef`. When both are specified,
              the merging behavior is implementation specific.
              It is generally recommended that GatewayClass provides defaults that can be overridden by a Gateway.

              Support: Implementation-specific
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  Gateway = mkResource {
    apiVersion = "gateway.networking.k8s.io/v1";
    kind = "Gateway";
    specType = (
      mkTypedSubmodule {
        options = {
          addresses = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    type = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = "Type of the address.";
                    };
                    value = mkOption {
                      type = types.str;
                      description = ''
                        Value of the address. The validity of the values will depend
                        on the type and support by the controller.

                        Examples: `1.2.3.4`, `128::1`, `my-ip-address`.
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Addresses requested for this Gateway. This is optional and behavior can
              depend on the implementation. If a value is set in the spec and the
              requested address is invalid or unavailable, the implementation MUST
              indicate this in the associated entry in GatewayStatus.Addresses.

              The Addresses field represents a request for the address(es) on the
              "outside of the Gateway", that traffic bound for this Gateway will use.
              This could be the IP address or hostname of an external load balancer or
              other networking infrastructure, or some other address that traffic will
              be sent to.

              If no Addresses are specified, the implementation MAY schedule the
              Gateway in an implementation-specific manner, assigning an appropriate
              set of Addresses.

              The implementation MUST bind all Listeners to every GatewayAddress that
              it assigns to the Gateway and add a corresponding entry in
              GatewayStatus.Addresses.

              Support: Extended

            '';
          };
          backendTLS = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  clientCertificateRef = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          group = mkOption {
                            type = (types.nullOr types.str);
                            default = null;
                            description = ''
                              Group is the group of the referent. For example, "gateway.networking.k8s.io".
                              When unspecified or empty string, core API group is inferred.
                            '';
                          };
                          kind = mkOption {
                            type = (types.nullOr types.str);
                            default = null;
                            description = "Kind is kind of the referent. For example \"Secret\".";
                          };
                          name = mkOption {
                            type = types.str;
                            description = "Name is the name of the referent.";
                          };
                          namespace = mkOption {
                            type = (types.nullOr types.str);
                            default = null;
                            description = ''
                              Namespace is the namespace of the referenced object. When unspecified, the local
                              namespace is inferred.

                              Note that when a namespace different than the local namespace is specified,
                              a ReferenceGrant object is required in the referent namespace to allow that
                              namespace's owner to accept the reference. See the ReferenceGrant
                              documentation for details.

                              Support: Core
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      ClientCertificateRef is a reference to an object that contains a Client
                      Certificate and the associated private key.

                      References to a resource in different namespace are invalid UNLESS there
                      is a ReferenceGrant in the target namespace that allows the certificate
                      to be attached. If a ReferenceGrant does not allow this reference, the
                      "ResolvedRefs" condition MUST be set to False for this listener with the
                      "RefNotPermitted" reason.

                      ClientCertificateRef can reference to standard Kubernetes resources, i.e.
                      Secret, or implementation-specific custom resources.

                      This setting can be overridden on the service level by use of BackendTLSPolicy.

                      Support: Core

                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              BackendTLS configures TLS settings for when this Gateway is connecting to
              backends with TLS.

              Support: Core

            '';
          };
          gatewayClassName = mkOption {
            type = types.str;
            description = ''
              GatewayClassName used for this Gateway. This is the name of a
              GatewayClass resource.
            '';
          };
          infrastructure = mkOption {
            type = (
              types.nullOr (mkTypedSubmodule {
                options = {
                  annotations = mkOption {
                    type = (types.nullOr (types.attrsOf types.str));
                    default = null;
                    description = ''
                      Annotations that SHOULD be applied to any resources created in response to this Gateway.

                      For implementations creating other Kubernetes objects, this should be the `metadata.annotations` field on resources.
                      For other implementations, this refers to any relevant (implementation specific) "annotations" concepts.

                      An implementation may chose to add additional implementation-specific annotations as they see fit.

                      Support: Extended
                    '';
                  };
                  labels = mkOption {
                    type = (types.nullOr (types.attrsOf types.str));
                    default = null;
                    description = ''
                      Labels that SHOULD be applied to any resources created in response to this Gateway.

                      For implementations creating other Kubernetes objects, this should be the `metadata.labels` field on resources.
                      For other implementations, this refers to any relevant (implementation specific) "labels" concepts.

                      An implementation may chose to add additional implementation-specific labels as they see fit.

                      If an implementation maps these labels to Pods, or any other resource that would need to be recreated when labels
                      change, it SHOULD clearly warn about this behavior in documentation.

                      Support: Extended
                    '';
                  };
                  parametersRef = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          group = mkOption {
                            type = types.str;
                            description = "Group is the group of the referent.";
                          };
                          kind = mkOption {
                            type = types.str;
                            description = "Kind is kind of the referent.";
                          };
                          name = mkOption {
                            type = types.str;
                            description = "Name is the name of the referent.";
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      ParametersRef is a reference to a resource that contains the configuration
                      parameters corresponding to the Gateway. This is optional if the
                      controller does not require any additional configuration.

                      This follows the same semantics as GatewayClass's `parametersRef`, but on a per-Gateway basis

                      The Gateway's GatewayClass may provide its own `parametersRef`. When both are specified,
                      the merging behavior is implementation specific.
                      It is generally recommended that GatewayClass provides defaults that can be overridden by a Gateway.

                      Support: Implementation-specific
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            default = null;
            description = ''
              Infrastructure defines infrastructure level attributes about this Gateway instance.

              Support: Extended
            '';
          };
          listeners = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  allowedRoutes = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          kinds = mkOption {
                            type = (
                              types.nullOr (
                                types.listOf (mkTypedSubmodule {
                                  options = {
                                    group = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = "Group is the group of the Route.";
                                    };
                                    kind = mkOption {
                                      type = types.str;
                                      description = "Kind is the kind of the Route.";
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              )
                            );
                            default = null;
                            description = ''
                              Kinds specifies the groups and kinds of Routes that are allowed to bind
                              to this Gateway Listener. When unspecified or empty, the kinds of Routes
                              selected are determined using the Listener protocol.

                              A RouteGroupKind MUST correspond to kinds of Routes that are compatible
                              with the application protocol specified in the Listener's Protocol field.
                              If an implementation does not support or recognize this resource type, it
                              MUST set the "ResolvedRefs" condition to False for this Listener with the
                              "InvalidRouteKinds" reason.

                              Support: Core
                            '';
                          };
                          namespaces = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  from = mkOption {
                                    type = (
                                      types.nullOr (
                                        types.enum [
                                          "All"
                                          "Selector"
                                          "Same"
                                        ]
                                      )
                                    );
                                    default = null;
                                    description = ''
                                      From indicates where Routes will be selected for this Gateway. Possible
                                      values are:

                                      * All: Routes in all namespaces may be used by this Gateway.
                                      * Selector: Routes in namespaces selected by the selector may be used by
                                        this Gateway.
                                      * Same: Only Routes in the same namespace may be used by this Gateway.

                                      Support: Core
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
                                      Selector must be specified when From is set to "Selector". In that case,
                                      only Routes in Namespaces matching this Selector will be selected by this
                                      Gateway. This field is ignored for other values of "From".

                                      Support: Core
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              Namespaces indicates namespaces from which Routes may be attached to this
                              Listener. This is restricted to the namespace of this Gateway by default.

                              Support: Core
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      AllowedRoutes defines the types of routes that MAY be attached to a
                      Listener and the trusted namespaces where those Route resources MAY be
                      present.

                      Although a client request may match multiple route rules, only one rule
                      may ultimately receive the request. Matching precedence MUST be
                      determined in order of the following criteria:

                      * The most specific match as defined by the Route type.
                      * The oldest Route based on creation timestamp. For example, a Route with
                        a creation timestamp of "2020-09-08 01:02:03" is given precedence over
                        a Route with a creation timestamp of "2020-09-08 01:02:04".
                      * If everything else is equivalent, the Route appearing first in
                        alphabetical order (namespace/name) should be given precedence. For
                        example, foo/bar is given precedence over foo/baz.

                      All valid rules within a Route attached to this Listener should be
                      implemented. Invalid Route rules can be ignored (sometimes that will mean
                      the full Route). If a Route rule transitions from valid to invalid,
                      support for that Route rule should be dropped to ensure consistency. For
                      example, even if a filter specified by a Route rule is invalid, the rest
                      of the rules within that Route should still be supported.

                      Support: Core
                    '';
                  };
                  hostname = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      Hostname specifies the virtual hostname to match for protocol types that
                      define this concept. When unspecified, all hostnames are matched. This
                      field is ignored for protocols that don't require hostname based
                      matching.

                      Implementations MUST apply Hostname matching appropriately for each of
                      the following protocols:

                      * TLS: The Listener Hostname MUST match the SNI.
                      * HTTP: The Listener Hostname MUST match the Host header of the request.
                      * HTTPS: The Listener Hostname SHOULD match at both the TLS and HTTP
                        protocol layers as described above. If an implementation does not
                        ensure that both the SNI and Host header match the Listener hostname,
                        it MUST clearly document that.

                      For HTTPRoute and TLSRoute resources, there is an interaction with the
                      `spec.hostnames` array. When both listener and route specify hostnames,
                      there MUST be an intersection between the values for a Route to be
                      accepted. For more information, refer to the Route specific Hostnames
                      documentation.

                      Hostnames that are prefixed with a wildcard label (`*.`) are interpreted
                      as a suffix match. That means that a match for `*.example.com` would match
                      both `test.example.com`, and `foo.test.example.com`, but not `example.com`.

                      Support: Core
                    '';
                  };
                  name = mkOption {
                    type = types.str;
                    description = ''
                      Name is the name of the Listener. This name MUST be unique within a
                      Gateway.

                      Support: Core
                    '';
                  };
                  port = mkOption {
                    type = types.int;
                    description = ''
                      Port is the network port. Multiple listeners may use the
                      same port, subject to the Listener compatibility rules.

                      Support: Core
                    '';
                  };
                  protocol = mkOption {
                    type = types.str;
                    description = ''
                      Protocol specifies the network protocol this listener expects to receive.

                      Support: Core
                    '';
                  };
                  tls = mkOption {
                    type = (
                      types.nullOr (mkTypedSubmodule {
                        options = {
                          certificateRefs = mkOption {
                            type = (
                              types.nullOr (
                                types.listOf (mkTypedSubmodule {
                                  options = {
                                    group = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                        When unspecified or empty string, core API group is inferred.
                                      '';
                                    };
                                    kind = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = "Kind is kind of the referent. For example \"Secret\".";
                                    };
                                    name = mkOption {
                                      type = types.str;
                                      description = "Name is the name of the referent.";
                                    };
                                    namespace = mkOption {
                                      type = (types.nullOr types.str);
                                      default = null;
                                      description = ''
                                        Namespace is the namespace of the referenced object. When unspecified, the local
                                        namespace is inferred.

                                        Note that when a namespace different than the local namespace is specified,
                                        a ReferenceGrant object is required in the referent namespace to allow that
                                        namespace's owner to accept the reference. See the ReferenceGrant
                                        documentation for details.

                                        Support: Core
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              )
                            );
                            default = null;
                            description = ''
                              CertificateRefs contains a series of references to Kubernetes objects that
                              contains TLS certificates and private keys. These certificates are used to
                              establish a TLS handshake for requests that match the hostname of the
                              associated listener.

                              A single CertificateRef to a Kubernetes Secret has "Core" support.
                              Implementations MAY choose to support attaching multiple certificates to
                              a Listener, but this behavior is implementation-specific.

                              References to a resource in different namespace are invalid UNLESS there
                              is a ReferenceGrant in the target namespace that allows the certificate
                              to be attached. If a ReferenceGrant does not allow this reference, the
                              "ResolvedRefs" condition MUST be set to False for this listener with the
                              "RefNotPermitted" reason.

                              This field is required to have at least one element when the mode is set
                              to "Terminate" (default) and is optional otherwise.

                              CertificateRefs can reference to standard Kubernetes resources, i.e.
                              Secret, or implementation-specific custom resources.

                              Support: Core - A single reference to a Kubernetes Secret of type kubernetes.io/tls

                              Support: Implementation-specific (More than one reference or other resource types)
                            '';
                          };
                          frontendValidation = mkOption {
                            type = (
                              types.nullOr (mkTypedSubmodule {
                                options = {
                                  caCertificateRefs = mkOption {
                                    type = (
                                      types.nullOr (
                                        types.listOf (mkTypedSubmodule {
                                          options = {
                                            group = mkOption {
                                              type = types.str;
                                              description = ''
                                                Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                                When unspecified or empty string, core API group is inferred.
                                              '';
                                            };
                                            kind = mkOption {
                                              type = types.str;
                                              description = "Kind is kind of the referent. For example \"ConfigMap\" or \"Service\".";
                                            };
                                            name = mkOption {
                                              type = types.str;
                                              description = "Name is the name of the referent.";
                                            };
                                            namespace = mkOption {
                                              type = (types.nullOr types.str);
                                              default = null;
                                              description = ''
                                                Namespace is the namespace of the referenced object. When unspecified, the local
                                                namespace is inferred.

                                                Note that when a namespace different than the local namespace is specified,
                                                a ReferenceGrant object is required in the referent namespace to allow that
                                                namespace's owner to accept the reference. See the ReferenceGrant
                                                documentation for details.

                                                Support: Core
                                              '';
                                            };
                                          };
                                          freeformType = types.attrs;
                                        })
                                      )
                                    );
                                    default = null;
                                    description = ''
                                      CACertificateRefs contains one or more references to
                                      Kubernetes objects that contain TLS certificates of
                                      the Certificate Authorities that can be used
                                      as a trust anchor to validate the certificates presented by the client.

                                      A single CA certificate reference to a Kubernetes ConfigMap
                                      has "Core" support.
                                      Implementations MAY choose to support attaching multiple CA certificates to
                                      a Listener, but this behavior is implementation-specific.

                                      Support: Core - A single reference to a Kubernetes ConfigMap
                                      with the CA certificate in a key named `ca.crt`.

                                      Support: Implementation-specific (More than one reference, or other kinds
                                      of resources).

                                      References to a resource in a different namespace are invalid UNLESS there
                                      is a ReferenceGrant in the target namespace that allows the certificate
                                      to be attached. If a ReferenceGrant does not allow this reference, the
                                      "ResolvedRefs" condition MUST be set to False for this listener with the
                                      "RefNotPermitted" reason.
                                    '';
                                  };
                                };
                                freeformType = types.attrs;
                              })
                            );
                            default = null;
                            description = ''
                              FrontendValidation holds configuration information for validating the frontend (client).
                              Setting this field will require clients to send a client certificate
                              required for validation during the TLS handshake. In browsers this may result in a dialog appearing
                              that requests a user to specify the client certificate.
                              The maximum depth of a certificate chain accepted in verification is Implementation specific.

                              Support: Extended

                            '';
                          };
                          mode = mkOption {
                            type = (
                              types.nullOr (
                                types.enum [
                                  "Terminate"
                                  "Passthrough"
                                ]
                              )
                            );
                            default = null;
                            description = ''
                              Mode defines the TLS behavior for the TLS session initiated by the client.
                              There are two possible modes:

                              - Terminate: The TLS session between the downstream client and the
                                Gateway is terminated at the Gateway. This mode requires certificates
                                to be specified in some way, such as populating the certificateRefs
                                field.
                              - Passthrough: The TLS session is NOT terminated by the Gateway. This
                                implies that the Gateway can't decipher the TLS stream except for
                                the ClientHello message of the TLS protocol. The certificateRefs field
                                is ignored in this mode.

                              Support: Core
                            '';
                          };
                          options = mkOption {
                            type = (types.nullOr (types.attrsOf types.str));
                            default = null;
                            description = ''
                              Options are a list of key/value pairs to enable extended TLS
                              configuration for each implementation. For example, configuring the
                              minimum TLS version or supported cipher suites.

                              A set of common keys MAY be defined by the API in the future. To avoid
                              any ambiguity, implementation-specific definitions MUST use
                              domain-prefixed names, such as `example.com/my-custom-option`.
                              Un-prefixed names are reserved for key names defined by Gateway API.

                              Support: Implementation-specific
                            '';
                          };
                        };
                        freeformType = types.attrs;
                      })
                    );
                    default = null;
                    description = ''
                      TLS is the TLS configuration for the Listener. This field is required if
                      the Protocol field is "HTTPS" or "TLS". It is invalid to set this field
                      if the Protocol field is "HTTP", "TCP", or "UDP".

                      The association of SNIs to Certificate defined in GatewayTLSConfig is
                      defined based on the Hostname field for this listener.

                      The GatewayClass MUST use the longest matching SNI out of all
                      available certificates for any TLS handshake.

                      Support: Core
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              Listeners associated with this Gateway. Listeners define
              logical endpoints that are bound on this Gateway's addresses.
              At least one Listener MUST be specified.

              Each Listener in a set of Listeners (for example, in a single Gateway)
              MUST be _distinct_, in that a traffic flow MUST be able to be assigned to
              exactly one listener. (This section uses "set of Listeners" rather than
              "Listeners in a single Gateway" because implementations MAY merge configuration
              from multiple Gateways onto a single data plane, and these rules _also_
              apply in that case).

              Practically, this means that each listener in a set MUST have a unique
              combination of Port, Protocol, and, if supported by the protocol, Hostname.

              Some combinations of port, protocol, and TLS settings are considered
              Core support and MUST be supported by implementations based on their
              targeted conformance profile:

              HTTP Profile

              1. HTTPRoute, Port: 80, Protocol: HTTP
              2. HTTPRoute, Port: 443, Protocol: HTTPS, TLS Mode: Terminate, TLS keypair provided

              TLS Profile

              1. TLSRoute, Port: 443, Protocol: TLS, TLS Mode: Passthrough

              "Distinct" Listeners have the following property:

              The implementation can match inbound requests to a single distinct
              Listener. When multiple Listeners share values for fields (for
              example, two Listeners with the same Port value), the implementation
              can match requests to only one of the Listeners using other
              Listener fields.

              For example, the following Listener scenarios are distinct:

              1. Multiple Listeners with the same Port that all use the "HTTP"
                 Protocol that all have unique Hostname values.
              2. Multiple Listeners with the same Port that use either the "HTTPS" or
                 "TLS" Protocol that all have unique Hostname values.
              3. A mixture of "TCP" and "UDP" Protocol Listeners, where no Listener
                 with the same Protocol has the same Port value.

              Some fields in the Listener struct have possible values that affect
              whether the Listener is distinct. Hostname is particularly relevant
              for HTTP or HTTPS protocols.

              When using the Hostname value to select between same-Port, same-Protocol
              Listeners, the Hostname value must be different on each Listener for the
              Listener to be distinct.

              When the Listeners are distinct based on Hostname, inbound request
              hostnames MUST match from the most specific to least specific Hostname
              values to choose the correct Listener and its associated set of Routes.

              Exact matches must be processed before wildcard matches, and wildcard
              matches must be processed before fallback (empty Hostname value)
              matches. For example, `"foo.example.com"` takes precedence over
              `"*.example.com"`, and `"*.example.com"` takes precedence over `""`.

              Additionally, if there are multiple wildcard entries, more specific
              wildcard entries must be processed before less specific wildcard entries.
              For example, `"*.foo.example.com"` takes precedence over `"*.example.com"`.
              The precise definition here is that the higher the number of dots in the
              hostname to the right of the wildcard character, the higher the precedence.

              The wildcard character will match any number of characters _and dots_ to
              the left, however, so `"*.example.com"` will match both
              `"foo.bar.example.com"` _and_ `"bar.example.com"`.

              If a set of Listeners contains Listeners that are not distinct, then those
              Listeners are Conflicted, and the implementation MUST set the "Conflicted"
              condition in the Listener Status to "True".

              Implementations MAY choose to accept a Gateway with some Conflicted
              Listeners only if they only accept the partial Listener set that contains
              no Conflicted Listeners. To put this another way, implementations may
              accept a partial Listener set only if they throw out *all* the conflicting
              Listeners. No picking one of the conflicting listeners as the winner.
              This also means that the Gateway must have at least one non-conflicting
              Listener in this case, otherwise it violates the requirement that at
              least one Listener must be present.

              The implementation MUST set a "ListenersNotValid" condition on the
              Gateway Status when the Gateway contains Conflicted Listeners whether or
              not they accept the Gateway. That Condition SHOULD clearly
              indicate in the Message which Listeners are conflicted, and which are
              Accepted. Additionally, the Listener status for those listeners SHOULD
              indicate which Listeners are conflicted and not Accepted.

              A Gateway's Listeners are considered "compatible" if:

              1. They are distinct.
              2. The implementation can serve them in compliance with the Addresses
                 requirement that all Listeners are available on all assigned
                 addresses.

              Compatible combinations in Extended support are expected to vary across
              implementations. A combination that is compatible for one implementation
              may not be compatible for another.

              For example, an implementation that cannot serve both TCP and UDP listeners
              on the same address, or cannot mix HTTPS and generic TLS listens on the same port
              would not consider those cases compatible, even though they are distinct.

              Note that requests SHOULD match at most one Listener. For example, if
              Listeners are defined for "foo.example.com" and "*.example.com", a
              request to "foo.example.com" SHOULD only be routed using routes attached
              to the "foo.example.com" Listener (and not the "*.example.com" Listener).
              This concept is known as "Listener Isolation". Implementations that do
              not support Listener Isolation MUST clearly document this.

              Implementations MAY merge separate Gateways onto a single set of
              Addresses if all Listeners across all Gateways are compatible.

              Support: Core
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  GRPCRoute = mkResource {
    apiVersion = "gateway.networking.k8s.io/v1";
    kind = "GRPCRoute";
    specType = (
      mkTypedSubmodule {
        options = {
          hostnames = mkOption {
            type = (types.nullOr (types.listOf types.str));
            default = null;
            description = ''
              Hostnames defines a set of hostnames to match against the GRPC
              Host header to select a GRPCRoute to process the request. This matches
              the RFC 1123 definition of a hostname with 2 notable exceptions:

              1. IPs are not allowed.
              2. A hostname may be prefixed with a wildcard label (`*.`). The wildcard
                 label MUST appear by itself as the first label.

              If a hostname is specified by both the Listener and GRPCRoute, there
              MUST be at least one intersecting hostname for the GRPCRoute to be
              attached to the Listener. For example:

              * A Listener with `test.example.com` as the hostname matches GRPCRoutes
                that have either not specified any hostnames, or have specified at
                least one of `test.example.com` or `*.example.com`.
              * A Listener with `*.example.com` as the hostname matches GRPCRoutes
                that have either not specified any hostnames or have specified at least
                one hostname that matches the Listener hostname. For example,
                `test.example.com` and `*.example.com` would both match. On the other
                hand, `example.com` and `test.example.net` would not match.

              Hostnames that are prefixed with a wildcard label (`*.`) are interpreted
              as a suffix match. That means that a match for `*.example.com` would match
              both `test.example.com`, and `foo.test.example.com`, but not `example.com`.

              If both the Listener and GRPCRoute have specified hostnames, any
              GRPCRoute hostnames that do not match the Listener hostname MUST be
              ignored. For example, if a Listener specified `*.example.com`, and the
              GRPCRoute specified `test.example.com` and `test.example.net`,
              `test.example.net` MUST NOT be considered for a match.

              If both the Listener and GRPCRoute have specified hostnames, and none
              match with the criteria above, then the GRPCRoute MUST NOT be accepted by
              the implementation. The implementation MUST raise an 'Accepted' Condition
              with a status of `False` in the corresponding RouteParentStatus.

              If a Route (A) of type HTTPRoute or GRPCRoute is attached to a
              Listener and that listener already has another Route (B) of the other
              type attached and the intersection of the hostnames of A and B is
              non-empty, then the implementation MUST accept exactly one of these two
              routes, determined by the following criteria, in order:

              * The oldest Route based on creation timestamp.
              * The Route appearing first in alphabetical order by
                "{namespace}/{name}".

              The rejected Route MUST raise an 'Accepted' condition with a status of
              'False' in the corresponding RouteParentStatus.

              Support: Core
            '';
          };
          parentRefs = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    group = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Group is the group of the referent.
                        When unspecified, "gateway.networking.k8s.io" is inferred.
                        To set the core API group (such as for a "Service" kind referent),
                        Group must be explicitly set to "" (empty string).

                        Support: Core
                      '';
                    };
                    kind = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Kind is kind of the referent.

                        There are two kinds of parent resources with "Core" support:

                        * Gateway (Gateway conformance profile)
                        * Service (Mesh conformance profile, ClusterIP Services only)

                        Support for other resources is Implementation-Specific.
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = ''
                        Name is the name of the referent.

                        Support: Core
                      '';
                    };
                    namespace = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Namespace is the namespace of the referent. When unspecified, this refers
                        to the local namespace of the Route.

                        Note that there are specific rules for ParentRefs which cross namespace
                        boundaries. Cross-namespace references are only valid if they are explicitly
                        allowed by something in the namespace they are referring to. For example:
                        Gateway has the AllowedRoutes field, and ReferenceGrant provides a
                        generic way to enable any other kind of cross-namespace reference.


                        ParentRefs from a Route to a Service in the same namespace are "producer"
                        routes, which apply default routing rules to inbound connections from
                        any namespace to the Service.

                        ParentRefs from a Route to a Service in a different namespace are
                        "consumer" routes, and these routing rules are only applied to outbound
                        connections originating from the same namespace as the Route, for which
                        the intended destination of the connections are a Service targeted as a
                        ParentRef of the Route.


                        Support: Core
                      '';
                    };
                    port = mkOption {
                      type = (types.nullOr types.int);
                      default = null;
                      description = ''
                        Port is the network port this Route targets. It can be interpreted
                        differently based on the type of parent resource.

                        When the parent resource is a Gateway, this targets all listeners
                        listening on the specified port that also support this kind of Route(and
                        select this Route). It's not recommended to set `Port` unless the
                        networking behaviors specified in a Route must apply to a specific port
                        as opposed to a listener(s) whose port(s) may be changed. When both Port
                        and SectionName are specified, the name and port of the selected listener
                        must match both specified values.


                        When the parent resource is a Service, this targets a specific port in the
                        Service spec. When both Port (experimental) and SectionName are specified,
                        the name and port of the selected port must match both specified values.


                        Implementations MAY choose to support other parent resources.
                        Implementations supporting other types of parent resources MUST clearly
                        document how/if Port is interpreted.

                        For the purpose of status, an attachment is considered successful as
                        long as the parent resource accepts it partially. For example, Gateway
                        listeners can restrict which Routes can attach to them by Route kind,
                        namespace, or hostname. If 1 of 2 Gateway listeners accept attachment
                        from the referencing Route, the Route MUST be considered successfully
                        attached. If no Gateway listeners accept attachment from this Route,
                        the Route MUST be considered detached from the Gateway.

                        Support: Extended
                      '';
                    };
                    sectionName = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        SectionName is the name of a section within the target resource. In the
                        following resources, SectionName is interpreted as the following:

                        * Gateway: Listener name. When both Port (experimental) and SectionName
                        are specified, the name and port of the selected listener must match
                        both specified values.
                        * Service: Port name. When both Port (experimental) and SectionName
                        are specified, the name and port of the selected listener must match
                        both specified values.

                        Implementations MAY choose to support attaching Routes to other resources.
                        If that is the case, they MUST clearly document how SectionName is
                        interpreted.

                        When unspecified (empty string), this will reference the entire resource.
                        For the purpose of status, an attachment is considered successful if at
                        least one section in the parent resource accepts it. For example, Gateway
                        listeners can restrict which Routes can attach to them by Route kind,
                        namespace, or hostname. If 1 of 2 Gateway listeners accept attachment from
                        the referencing Route, the Route MUST be considered successfully
                        attached. If no Gateway listeners accept attachment from this Route, the
                        Route MUST be considered detached from the Gateway.

                        Support: Core
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              ParentRefs references the resources (usually Gateways) that a Route wants
              to be attached to. Note that the referenced parent resource needs to
              allow this for the attachment to be complete. For Gateways, that means
              the Gateway needs to allow attachment from Routes of this kind and
              namespace. For Services, that means the Service must either be in the same
              namespace for a "producer" route, or the mesh implementation must support
              and allow "consumer" routes for the referenced Service. ReferenceGrant is
              not applicable for governing ParentRefs to Services - it is not possible to
              create a "producer" route for a Service in a different namespace from the
              Route.

              There are two kinds of parent resources with "Core" support:

              * Gateway (Gateway conformance profile)
              * Service (Mesh conformance profile, ClusterIP Services only)

              This API may be extended in the future to support additional kinds of parent
              resources.

              ParentRefs must be _distinct_. This means either that:

              * They select different objects.  If this is the case, then parentRef
                entries are distinct. In terms of fields, this means that the
                multi-part key defined by `group`, `kind`, `namespace`, and `name` must
                be unique across all parentRef entries in the Route.
              * They do not select different objects, but for each optional field used,
                each ParentRef that selects the same object must set the same set of
                optional fields to different values. If one ParentRef sets a
                combination of optional fields, all must set the same combination.

              Some examples:

              * If one ParentRef sets `sectionName`, all ParentRefs referencing the
                same object must also set `sectionName`.
              * If one ParentRef sets `port`, all ParentRefs referencing the same
                object must also set `port`.
              * If one ParentRef sets `sectionName` and `port`, all ParentRefs
                referencing the same object must also set `sectionName` and `port`.

              It is possible to separately reference multiple distinct objects that may
              be collapsed by an implementation. For example, some implementations may
              choose to merge compatible Gateway Listeners together. If that is the
              case, the list of routes attached to those resources should also be
              merged.

              Note that for ParentRefs that cross namespace boundaries, there are specific
              rules. Cross-namespace references are only valid if they are explicitly
              allowed by something in the namespace they are referring to. For example,
              Gateway has the AllowedRoutes field, and ReferenceGrant provides a
              generic way to enable other kinds of cross-namespace reference.


              ParentRefs from a Route to a Service in the same namespace are "producer"
              routes, which apply default routing rules to inbound connections from
              any namespace to the Service.

              ParentRefs from a Route to a Service in a different namespace are
              "consumer" routes, and these routing rules are only applied to outbound
              connections originating from the same namespace as the Route, for which
              the intended destination of the connections are a Service targeted as a
              ParentRef of the Route.





            '';
          };
          rules = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    backendRefs = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              filters = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        extensionRef = mkOption {
                                          type = (
                                            types.nullOr (mkTypedSubmodule {
                                              options = {
                                                group = mkOption {
                                                  type = types.str;
                                                  description = ''
                                                    Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                                    When unspecified or empty string, core API group is inferred.
                                                  '';
                                                };
                                                kind = mkOption {
                                                  type = types.str;
                                                  description = "Kind is kind of the referent. For example \"HTTPRoute\" or \"Service\".";
                                                };
                                                name = mkOption {
                                                  type = types.str;
                                                  description = "Name is the name of the referent.";
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          );
                                          default = null;
                                          description = ''
                                            ExtensionRef is an optional, implementation-specific extension to the
                                            "filter" behavior.  For example, resource "myroutefilter" in group
                                            "networking.example.net"). ExtensionRef MUST NOT be used for core and
                                            extended filters.

                                            Support: Implementation-specific

                                            This filter can be used multiple times within the same rule.
                                          '';
                                        };
                                        requestHeaderModifier = mkOption {
                                          type = (
                                            types.nullOr (mkTypedSubmodule {
                                              options = {
                                                add = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = ''
                                                              Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                              case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                              If multiple entries specify equivalent header names, the first entry with
                                                              an equivalent name MUST be considered for a match. Subsequent entries
                                                              with an equivalent header name MUST be ignored. Due to the
                                                              case-insensitivity of header names, "foo" and "Foo" are considered
                                                              equivalent.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = types.str;
                                                            description = "Value is the value of HTTP Header to be matched.";
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Add adds the given header(s) (name, value) to the request
                                                    before the action. It appends to any existing values associated
                                                    with the header name.

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo

                                                    Config:
                                                      add:
                                                      - name: "my-header"
                                                        value: "bar,baz"

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo,bar,baz
                                                  '';
                                                };
                                                remove = mkOption {
                                                  type = (types.nullOr (types.listOf types.str));
                                                  default = null;
                                                  description = ''
                                                    Remove the given header(s) from the HTTP request before the action. The
                                                    value of Remove is a list of HTTP header names. Note that the header
                                                    names are case-insensitive (see
                                                    https://datatracker.ietf.org/doc/html/rfc2616#section-4.2).

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header1: foo
                                                      my-header2: bar
                                                      my-header3: baz

                                                    Config:
                                                      remove: ["my-header1", "my-header3"]

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header2: bar
                                                  '';
                                                };
                                                set = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = ''
                                                              Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                              case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                              If multiple entries specify equivalent header names, the first entry with
                                                              an equivalent name MUST be considered for a match. Subsequent entries
                                                              with an equivalent header name MUST be ignored. Due to the
                                                              case-insensitivity of header names, "foo" and "Foo" are considered
                                                              equivalent.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = types.str;
                                                            description = "Value is the value of HTTP Header to be matched.";
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Set overwrites the request with the given header (name, value)
                                                    before the action.

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo

                                                    Config:
                                                      set:
                                                      - name: "my-header"
                                                        value: "bar"

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header: bar
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          );
                                          default = null;
                                          description = ''
                                            RequestHeaderModifier defines a schema for a filter that modifies request
                                            headers.

                                            Support: Core
                                          '';
                                        };
                                        requestMirror = mkOption {
                                          type = (
                                            types.nullOr (mkTypedSubmodule {
                                              options = {
                                                backendRef = mkOption {
                                                  type = (
                                                    mkTypedSubmodule {
                                                      options = {
                                                        group = mkOption {
                                                          type = (types.nullOr types.str);
                                                          default = null;
                                                          description = ''
                                                            Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                                            When unspecified or empty string, core API group is inferred.
                                                          '';
                                                        };
                                                        kind = mkOption {
                                                          type = (types.nullOr types.str);
                                                          default = null;
                                                          description = ''
                                                            Kind is the Kubernetes resource kind of the referent. For example
                                                            "Service".

                                                            Defaults to "Service" when not specified.

                                                            ExternalName services can refer to CNAME DNS records that may live
                                                            outside of the cluster and as such are difficult to reason about in
                                                            terms of conformance. They also may not be safe to forward to (see
                                                            CVE-2021-25740 for more information). Implementations SHOULD NOT
                                                            support ExternalName Services.

                                                            Support: Core (Services with a type other than ExternalName)

                                                            Support: Implementation-specific (Services with type ExternalName)
                                                          '';
                                                        };
                                                        name = mkOption {
                                                          type = types.str;
                                                          description = "Name is the name of the referent.";
                                                        };
                                                        namespace = mkOption {
                                                          type = (types.nullOr types.str);
                                                          default = null;
                                                          description = ''
                                                            Namespace is the namespace of the backend. When unspecified, the local
                                                            namespace is inferred.

                                                            Note that when a namespace different than the local namespace is specified,
                                                            a ReferenceGrant object is required in the referent namespace to allow that
                                                            namespace's owner to accept the reference. See the ReferenceGrant
                                                            documentation for details.

                                                            Support: Core
                                                          '';
                                                        };
                                                        port = mkOption {
                                                          type = (types.nullOr types.int);
                                                          default = null;
                                                          description = ''
                                                            Port specifies the destination port number to use for this resource.
                                                            Port is required when the referent is a Kubernetes Service. In this
                                                            case, the port number is the service port number, not the target port.
                                                            For other resources, destination port might be derived from the referent
                                                            resource or this field.
                                                          '';
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    }
                                                  );
                                                  description = ''
                                                    BackendRef references a resource where mirrored requests are sent.

                                                    Mirrored requests must be sent only to a single destination endpoint
                                                    within this BackendRef, irrespective of how many endpoints are present
                                                    within this BackendRef.

                                                    If the referent cannot be found, this BackendRef is invalid and must be
                                                    dropped from the Gateway. The controller must ensure the "ResolvedRefs"
                                                    condition on the Route status is set to `status: False` and not configure
                                                    this backend in the underlying implementation.

                                                    If there is a cross-namespace reference to an *existing* object
                                                    that is not allowed by a ReferenceGrant, the controller must ensure the
                                                    "ResolvedRefs"  condition on the Route is set to `status: False`,
                                                    with the "RefNotPermitted" reason and not configure this backend in the
                                                    underlying implementation.

                                                    In either error case, the Message of the `ResolvedRefs` Condition
                                                    should be used to provide more detail about the problem.

                                                    Support: Extended for Kubernetes Service

                                                    Support: Implementation-specific for any other resource
                                                  '';
                                                };
                                                fraction = mkOption {
                                                  type = (
                                                    types.nullOr (mkTypedSubmodule {
                                                      options = {
                                                        denominator = mkOption {
                                                          type = (types.nullOr types.int);
                                                          default = null;
                                                        };
                                                        numerator = mkOption {
                                                          type = types.int;
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    })
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Fraction represents the fraction of requests that should be
                                                    mirrored to BackendRef.

                                                    Only one of Fraction or Percent may be specified. If neither field
                                                    is specified, 100% of requests will be mirrored.

                                                  '';
                                                };
                                                percent = mkOption {
                                                  type = (types.nullOr types.int);
                                                  default = null;
                                                  description = ''
                                                    Percent represents the percentage of requests that should be
                                                    mirrored to BackendRef. Its minimum value is 0 (indicating 0% of
                                                    requests) and its maximum value is 100 (indicating 100% of requests).

                                                    Only one of Fraction or Percent may be specified. If neither field
                                                    is specified, 100% of requests will be mirrored.

                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          );
                                          default = null;
                                          description = ''
                                            RequestMirror defines a schema for a filter that mirrors requests.
                                            Requests are sent to the specified destination, but responses from
                                            that destination are ignored.

                                            This filter can be used multiple times within the same rule. Note that
                                            not all implementations will be able to support mirroring to multiple
                                            backends.

                                            Support: Extended

                                          '';
                                        };
                                        responseHeaderModifier = mkOption {
                                          type = (
                                            types.nullOr (mkTypedSubmodule {
                                              options = {
                                                add = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = ''
                                                              Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                              case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                              If multiple entries specify equivalent header names, the first entry with
                                                              an equivalent name MUST be considered for a match. Subsequent entries
                                                              with an equivalent header name MUST be ignored. Due to the
                                                              case-insensitivity of header names, "foo" and "Foo" are considered
                                                              equivalent.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = types.str;
                                                            description = "Value is the value of HTTP Header to be matched.";
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Add adds the given header(s) (name, value) to the request
                                                    before the action. It appends to any existing values associated
                                                    with the header name.

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo

                                                    Config:
                                                      add:
                                                      - name: "my-header"
                                                        value: "bar,baz"

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo,bar,baz
                                                  '';
                                                };
                                                remove = mkOption {
                                                  type = (types.nullOr (types.listOf types.str));
                                                  default = null;
                                                  description = ''
                                                    Remove the given header(s) from the HTTP request before the action. The
                                                    value of Remove is a list of HTTP header names. Note that the header
                                                    names are case-insensitive (see
                                                    https://datatracker.ietf.org/doc/html/rfc2616#section-4.2).

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header1: foo
                                                      my-header2: bar
                                                      my-header3: baz

                                                    Config:
                                                      remove: ["my-header1", "my-header3"]

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header2: bar
                                                  '';
                                                };
                                                set = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = ''
                                                              Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                              case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                              If multiple entries specify equivalent header names, the first entry with
                                                              an equivalent name MUST be considered for a match. Subsequent entries
                                                              with an equivalent header name MUST be ignored. Due to the
                                                              case-insensitivity of header names, "foo" and "Foo" are considered
                                                              equivalent.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = types.str;
                                                            description = "Value is the value of HTTP Header to be matched.";
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Set overwrites the request with the given header (name, value)
                                                    before the action.

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo

                                                    Config:
                                                      set:
                                                      - name: "my-header"
                                                        value: "bar"

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header: bar
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          );
                                          default = null;
                                          description = ''
                                            ResponseHeaderModifier defines a schema for a filter that modifies response
                                            headers.

                                            Support: Extended
                                          '';
                                        };
                                        type = mkOption {
                                          type = (
                                            types.enum [
                                              "ResponseHeaderModifier"
                                              "RequestHeaderModifier"
                                              "RequestMirror"
                                              "ExtensionRef"
                                            ]
                                          );
                                          description = ''
                                            Type identifies the type of filter to apply. As with other API fields,
                                            types are classified into three conformance levels:

                                            - Core: Filter types and their corresponding configuration defined by
                                              "Support: Core" in this package, e.g. "RequestHeaderModifier". All
                                              implementations supporting GRPCRoute MUST support core filters.

                                            - Extended: Filter types and their corresponding configuration defined by
                                              "Support: Extended" in this package, e.g. "RequestMirror". Implementers
                                              are encouraged to support extended filters.

                                            - Implementation-specific: Filters that are defined and supported by specific vendors.
                                              In the future, filters showing convergence in behavior across multiple
                                              implementations will be considered for inclusion in extended or core
                                              conformance levels. Filter-specific configuration for such filters
                                              is specified using the ExtensionRef field. `Type` MUST be set to
                                              "ExtensionRef" for custom filters.

                                            Implementers are encouraged to define custom implementation types to
                                            extend the core API with implementation-specific behavior.

                                            If a reference to a custom filter type cannot be resolved, the filter
                                            MUST NOT be skipped. Instead, requests that would have been processed by
                                            that filter MUST receive a HTTP error response.

                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = ''
                                  Filters defined at this level MUST be executed if and only if the
                                  request is being forwarded to the backend defined here.

                                  Support: Implementation-specific (For broader support of filters, use the
                                  Filters field in GRPCRouteRule.)
                                '';
                              };
                              group = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                  When unspecified or empty string, core API group is inferred.
                                '';
                              };
                              kind = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  Kind is the Kubernetes resource kind of the referent. For example
                                  "Service".

                                  Defaults to "Service" when not specified.

                                  ExternalName services can refer to CNAME DNS records that may live
                                  outside of the cluster and as such are difficult to reason about in
                                  terms of conformance. They also may not be safe to forward to (see
                                  CVE-2021-25740 for more information). Implementations SHOULD NOT
                                  support ExternalName Services.

                                  Support: Core (Services with a type other than ExternalName)

                                  Support: Implementation-specific (Services with type ExternalName)
                                '';
                              };
                              name = mkOption {
                                type = types.str;
                                description = "Name is the name of the referent.";
                              };
                              namespace = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  Namespace is the namespace of the backend. When unspecified, the local
                                  namespace is inferred.

                                  Note that when a namespace different than the local namespace is specified,
                                  a ReferenceGrant object is required in the referent namespace to allow that
                                  namespace's owner to accept the reference. See the ReferenceGrant
                                  documentation for details.

                                  Support: Core
                                '';
                              };
                              port = mkOption {
                                type = (types.nullOr types.int);
                                default = null;
                                description = ''
                                  Port specifies the destination port number to use for this resource.
                                  Port is required when the referent is a Kubernetes Service. In this
                                  case, the port number is the service port number, not the target port.
                                  For other resources, destination port might be derived from the referent
                                  resource or this field.
                                '';
                              };
                              weight = mkOption {
                                type = (types.nullOr types.int);
                                default = null;
                                description = ''
                                  Weight specifies the proportion of requests forwarded to the referenced
                                  backend. This is computed as weight/(sum of all weights in this
                                  BackendRefs list). For non-zero values, there may be some epsilon from
                                  the exact proportion defined here depending on the precision an
                                  implementation supports. Weight is not a percentage and the sum of
                                  weights does not need to equal 100.

                                  If only one backend is specified and it has a weight greater than 0, 100%
                                  of the traffic is forwarded to that backend. If weight is set to 0, no
                                  traffic should be forwarded for this entry. If unspecified, weight
                                  defaults to 1.

                                  Support for this field varies based on the context where used.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        BackendRefs defines the backend(s) where matching requests should be
                        sent.

                        Failure behavior here depends on how many BackendRefs are specified and
                        how many are invalid.

                        If *all* entries in BackendRefs are invalid, and there are also no filters
                        specified in this route rule, *all* traffic which matches this rule MUST
                        receive an `UNAVAILABLE` status.

                        See the GRPCBackendRef definition for the rules about what makes a single
                        GRPCBackendRef invalid.

                        When a GRPCBackendRef is invalid, `UNAVAILABLE` statuses MUST be returned for
                        requests that would have otherwise been routed to an invalid backend. If
                        multiple backends are specified, and some are invalid, the proportion of
                        requests that would otherwise have been routed to an invalid backend
                        MUST receive an `UNAVAILABLE` status.

                        For example, if two backends are specified with equal weights, and one is
                        invalid, 50 percent of traffic MUST receive an `UNAVAILABLE` status.
                        Implementations may choose how that 50 percent is determined.

                        Support: Core for Kubernetes Service

                        Support: Implementation-specific for any other resource

                        Support for weight: Core
                      '';
                    };
                    filters = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              extensionRef = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      group = mkOption {
                                        type = types.str;
                                        description = ''
                                          Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                          When unspecified or empty string, core API group is inferred.
                                        '';
                                      };
                                      kind = mkOption {
                                        type = types.str;
                                        description = "Kind is kind of the referent. For example \"HTTPRoute\" or \"Service\".";
                                      };
                                      name = mkOption {
                                        type = types.str;
                                        description = "Name is the name of the referent.";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  ExtensionRef is an optional, implementation-specific extension to the
                                  "filter" behavior.  For example, resource "myroutefilter" in group
                                  "networking.example.net"). ExtensionRef MUST NOT be used for core and
                                  extended filters.

                                  Support: Implementation-specific

                                  This filter can be used multiple times within the same rule.
                                '';
                              };
                              requestHeaderModifier = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      add = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                name = mkOption {
                                                  type = types.str;
                                                  description = ''
                                                    Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                    case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                    If multiple entries specify equivalent header names, the first entry with
                                                    an equivalent name MUST be considered for a match. Subsequent entries
                                                    with an equivalent header name MUST be ignored. Due to the
                                                    case-insensitivity of header names, "foo" and "Foo" are considered
                                                    equivalent.
                                                  '';
                                                };
                                                value = mkOption {
                                                  type = types.str;
                                                  description = "Value is the value of HTTP Header to be matched.";
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Add adds the given header(s) (name, value) to the request
                                          before the action. It appends to any existing values associated
                                          with the header name.

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header: foo

                                          Config:
                                            add:
                                            - name: "my-header"
                                              value: "bar,baz"

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header: foo,bar,baz
                                        '';
                                      };
                                      remove = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                        description = ''
                                          Remove the given header(s) from the HTTP request before the action. The
                                          value of Remove is a list of HTTP header names. Note that the header
                                          names are case-insensitive (see
                                          https://datatracker.ietf.org/doc/html/rfc2616#section-4.2).

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header1: foo
                                            my-header2: bar
                                            my-header3: baz

                                          Config:
                                            remove: ["my-header1", "my-header3"]

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header2: bar
                                        '';
                                      };
                                      set = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                name = mkOption {
                                                  type = types.str;
                                                  description = ''
                                                    Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                    case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                    If multiple entries specify equivalent header names, the first entry with
                                                    an equivalent name MUST be considered for a match. Subsequent entries
                                                    with an equivalent header name MUST be ignored. Due to the
                                                    case-insensitivity of header names, "foo" and "Foo" are considered
                                                    equivalent.
                                                  '';
                                                };
                                                value = mkOption {
                                                  type = types.str;
                                                  description = "Value is the value of HTTP Header to be matched.";
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Set overwrites the request with the given header (name, value)
                                          before the action.

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header: foo

                                          Config:
                                            set:
                                            - name: "my-header"
                                              value: "bar"

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header: bar
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  RequestHeaderModifier defines a schema for a filter that modifies request
                                  headers.

                                  Support: Core
                                '';
                              };
                              requestMirror = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      backendRef = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              group = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                                  When unspecified or empty string, core API group is inferred.
                                                '';
                                              };
                                              kind = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Kind is the Kubernetes resource kind of the referent. For example
                                                  "Service".

                                                  Defaults to "Service" when not specified.

                                                  ExternalName services can refer to CNAME DNS records that may live
                                                  outside of the cluster and as such are difficult to reason about in
                                                  terms of conformance. They also may not be safe to forward to (see
                                                  CVE-2021-25740 for more information). Implementations SHOULD NOT
                                                  support ExternalName Services.

                                                  Support: Core (Services with a type other than ExternalName)

                                                  Support: Implementation-specific (Services with type ExternalName)
                                                '';
                                              };
                                              name = mkOption {
                                                type = types.str;
                                                description = "Name is the name of the referent.";
                                              };
                                              namespace = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Namespace is the namespace of the backend. When unspecified, the local
                                                  namespace is inferred.

                                                  Note that when a namespace different than the local namespace is specified,
                                                  a ReferenceGrant object is required in the referent namespace to allow that
                                                  namespace's owner to accept the reference. See the ReferenceGrant
                                                  documentation for details.

                                                  Support: Core
                                                '';
                                              };
                                              port = mkOption {
                                                type = (types.nullOr types.int);
                                                default = null;
                                                description = ''
                                                  Port specifies the destination port number to use for this resource.
                                                  Port is required when the referent is a Kubernetes Service. In this
                                                  case, the port number is the service port number, not the target port.
                                                  For other resources, destination port might be derived from the referent
                                                  resource or this field.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          BackendRef references a resource where mirrored requests are sent.

                                          Mirrored requests must be sent only to a single destination endpoint
                                          within this BackendRef, irrespective of how many endpoints are present
                                          within this BackendRef.

                                          If the referent cannot be found, this BackendRef is invalid and must be
                                          dropped from the Gateway. The controller must ensure the "ResolvedRefs"
                                          condition on the Route status is set to `status: False` and not configure
                                          this backend in the underlying implementation.

                                          If there is a cross-namespace reference to an *existing* object
                                          that is not allowed by a ReferenceGrant, the controller must ensure the
                                          "ResolvedRefs"  condition on the Route is set to `status: False`,
                                          with the "RefNotPermitted" reason and not configure this backend in the
                                          underlying implementation.

                                          In either error case, the Message of the `ResolvedRefs` Condition
                                          should be used to provide more detail about the problem.

                                          Support: Extended for Kubernetes Service

                                          Support: Implementation-specific for any other resource
                                        '';
                                      };
                                      fraction = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              denominator = mkOption {
                                                type = (types.nullOr types.int);
                                                default = null;
                                              };
                                              numerator = mkOption {
                                                type = types.int;
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = ''
                                          Fraction represents the fraction of requests that should be
                                          mirrored to BackendRef.

                                          Only one of Fraction or Percent may be specified. If neither field
                                          is specified, 100% of requests will be mirrored.

                                        '';
                                      };
                                      percent = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          Percent represents the percentage of requests that should be
                                          mirrored to BackendRef. Its minimum value is 0 (indicating 0% of
                                          requests) and its maximum value is 100 (indicating 100% of requests).

                                          Only one of Fraction or Percent may be specified. If neither field
                                          is specified, 100% of requests will be mirrored.

                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  RequestMirror defines a schema for a filter that mirrors requests.
                                  Requests are sent to the specified destination, but responses from
                                  that destination are ignored.

                                  This filter can be used multiple times within the same rule. Note that
                                  not all implementations will be able to support mirroring to multiple
                                  backends.

                                  Support: Extended

                                '';
                              };
                              responseHeaderModifier = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      add = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                name = mkOption {
                                                  type = types.str;
                                                  description = ''
                                                    Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                    case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                    If multiple entries specify equivalent header names, the first entry with
                                                    an equivalent name MUST be considered for a match. Subsequent entries
                                                    with an equivalent header name MUST be ignored. Due to the
                                                    case-insensitivity of header names, "foo" and "Foo" are considered
                                                    equivalent.
                                                  '';
                                                };
                                                value = mkOption {
                                                  type = types.str;
                                                  description = "Value is the value of HTTP Header to be matched.";
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Add adds the given header(s) (name, value) to the request
                                          before the action. It appends to any existing values associated
                                          with the header name.

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header: foo

                                          Config:
                                            add:
                                            - name: "my-header"
                                              value: "bar,baz"

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header: foo,bar,baz
                                        '';
                                      };
                                      remove = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                        description = ''
                                          Remove the given header(s) from the HTTP request before the action. The
                                          value of Remove is a list of HTTP header names. Note that the header
                                          names are case-insensitive (see
                                          https://datatracker.ietf.org/doc/html/rfc2616#section-4.2).

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header1: foo
                                            my-header2: bar
                                            my-header3: baz

                                          Config:
                                            remove: ["my-header1", "my-header3"]

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header2: bar
                                        '';
                                      };
                                      set = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                name = mkOption {
                                                  type = types.str;
                                                  description = ''
                                                    Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                    case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                    If multiple entries specify equivalent header names, the first entry with
                                                    an equivalent name MUST be considered for a match. Subsequent entries
                                                    with an equivalent header name MUST be ignored. Due to the
                                                    case-insensitivity of header names, "foo" and "Foo" are considered
                                                    equivalent.
                                                  '';
                                                };
                                                value = mkOption {
                                                  type = types.str;
                                                  description = "Value is the value of HTTP Header to be matched.";
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Set overwrites the request with the given header (name, value)
                                          before the action.

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header: foo

                                          Config:
                                            set:
                                            - name: "my-header"
                                              value: "bar"

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header: bar
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  ResponseHeaderModifier defines a schema for a filter that modifies response
                                  headers.

                                  Support: Extended
                                '';
                              };
                              type = mkOption {
                                type = (
                                  types.enum [
                                    "ResponseHeaderModifier"
                                    "RequestHeaderModifier"
                                    "RequestMirror"
                                    "ExtensionRef"
                                  ]
                                );
                                description = ''
                                  Type identifies the type of filter to apply. As with other API fields,
                                  types are classified into three conformance levels:

                                  - Core: Filter types and their corresponding configuration defined by
                                    "Support: Core" in this package, e.g. "RequestHeaderModifier". All
                                    implementations supporting GRPCRoute MUST support core filters.

                                  - Extended: Filter types and their corresponding configuration defined by
                                    "Support: Extended" in this package, e.g. "RequestMirror". Implementers
                                    are encouraged to support extended filters.

                                  - Implementation-specific: Filters that are defined and supported by specific vendors.
                                    In the future, filters showing convergence in behavior across multiple
                                    implementations will be considered for inclusion in extended or core
                                    conformance levels. Filter-specific configuration for such filters
                                    is specified using the ExtensionRef field. `Type` MUST be set to
                                    "ExtensionRef" for custom filters.

                                  Implementers are encouraged to define custom implementation types to
                                  extend the core API with implementation-specific behavior.

                                  If a reference to a custom filter type cannot be resolved, the filter
                                  MUST NOT be skipped. Instead, requests that would have been processed by
                                  that filter MUST receive a HTTP error response.

                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        Filters define the filters that are applied to requests that match
                        this rule.

                        The effects of ordering of multiple behaviors are currently unspecified.
                        This can change in the future based on feedback during the alpha stage.

                        Conformance-levels at this level are defined based on the type of filter:

                        - ALL core filters MUST be supported by all implementations that support
                          GRPCRoute.
                        - Implementers are encouraged to support extended filters.
                        - Implementation-specific custom filters have no API guarantees across
                          implementations.

                        Specifying the same filter multiple times is not supported unless explicitly
                        indicated in the filter.

                        If an implementation can not support a combination of filters, it must clearly
                        document that limitation. In cases where incompatible or unsupported
                        filters are specified and cause the `Accepted` condition to be set to status
                        `False`, implementations may use the `IncompatibleFilters` reason to specify
                        this configuration error.

                        Support: Core
                      '';
                    };
                    matches = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              headers = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        name = mkOption {
                                          type = types.str;
                                          description = ''
                                            Name is the name of the gRPC Header to be matched.

                                            If multiple entries specify equivalent header names, only the first
                                            entry with an equivalent name MUST be considered for a match. Subsequent
                                            entries with an equivalent header name MUST be ignored. Due to the
                                            case-insensitivity of header names, "foo" and "Foo" are considered
                                            equivalent.
                                          '';
                                        };
                                        type = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "Exact"
                                                "RegularExpression"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = "Type specifies how to match against the value of the header.";
                                        };
                                        value = mkOption {
                                          type = types.str;
                                          description = "Value is the value of the gRPC Header to be matched.";
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = ''
                                  Headers specifies gRPC request header matchers. Multiple match values are
                                  ANDed together, meaning, a request MUST match all the specified headers
                                  to select the route.
                                '';
                              };
                              method = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      method = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Value of the method to match against. If left empty or omitted, will
                                          match all services.

                                          At least one of Service and Method MUST be a non-empty string.
                                        '';
                                      };
                                      service = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Value of the service to match against. If left empty or omitted, will
                                          match any service.

                                          At least one of Service and Method MUST be a non-empty string.
                                        '';
                                      };
                                      type = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.enum [
                                              "Exact"
                                              "RegularExpression"
                                            ]
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Type specifies how to match against the service and/or method.
                                          Support: Core (Exact with service and method specified)

                                          Support: Implementation-specific (Exact with method specified but no service specified)

                                          Support: Implementation-specific (RegularExpression)
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  Method specifies a gRPC request service/method matcher. If this field is
                                  not specified, all services and methods will match.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        Matches define conditions used for matching the rule against incoming
                        gRPC requests. Each match is independent, i.e. this rule will be matched
                        if **any** one of the matches is satisfied.

                        For example, take the following matches configuration:

                        ```
                        matches:
                        - method:
                            service: foo.bar
                          headers:
                            values:
                              version: 2
                        - method:
                            service: foo.bar.v2
                        ```

                        For a request to match against this rule, it MUST satisfy
                        EITHER of the two conditions:

                        - service of foo.bar AND contains the header `version: 2`
                        - service of foo.bar.v2

                        See the documentation for GRPCRouteMatch on how to specify multiple
                        match conditions to be ANDed together.

                        If no matches are specified, the implementation MUST match every gRPC request.

                        Proxy or Load Balancer routing configuration generated from GRPCRoutes
                        MUST prioritize rules based on the following criteria, continuing on
                        ties. Merging MUST not be done between GRPCRoutes and HTTPRoutes.
                        Precedence MUST be given to the rule with the largest number of:

                        * Characters in a matching non-wildcard hostname.
                        * Characters in a matching hostname.
                        * Characters in a matching service.
                        * Characters in a matching method.
                        * Header matches.

                        If ties still exist across multiple Routes, matching precedence MUST be
                        determined in order of the following criteria, continuing on ties:

                        * The oldest Route based on creation timestamp.
                        * The Route appearing first in alphabetical order by
                          "{namespace}/{name}".

                        If ties still exist within the Route that has been given precedence,
                        matching precedence MUST be granted to the first matching rule meeting
                        the above criteria.
                      '';
                    };
                    name = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Name is the name of the route rule. This name MUST be unique within a Route if it is set.

                        Support: Extended
                      '';
                    };
                    sessionPersistence = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            absoluteTimeout = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                AbsoluteTimeout defines the absolute timeout of the persistent
                                session. Once the AbsoluteTimeout duration has elapsed, the
                                session becomes invalid.

                                Support: Extended
                              '';
                            };
                            cookieConfig = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    lifetimeType = mkOption {
                                      type = (
                                        types.nullOr (
                                          types.enum [
                                            "Permanent"
                                            "Session"
                                          ]
                                        )
                                      );
                                      default = null;
                                      description = ''
                                        LifetimeType specifies whether the cookie has a permanent or
                                        session-based lifetime. A permanent cookie persists until its
                                        specified expiry time, defined by the Expires or Max-Age cookie
                                        attributes, while a session cookie is deleted when the current
                                        session ends.

                                        When set to "Permanent", AbsoluteTimeout indicates the
                                        cookie's lifetime via the Expires or Max-Age cookie attributes
                                        and is required.

                                        When set to "Session", AbsoluteTimeout indicates the
                                        absolute lifetime of the cookie tracked by the gateway and
                                        is optional.

                                        Support: Core for "Session" type

                                        Support: Extended for "Permanent" type
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                CookieConfig provides configuration settings that are specific
                                to cookie-based session persistence.

                                Support: Core
                              '';
                            };
                            idleTimeout = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                IdleTimeout defines the idle timeout of the persistent session.
                                Once the session has been idle for more than the specified
                                IdleTimeout duration, the session becomes invalid.

                                Support: Extended
                              '';
                            };
                            sessionName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                SessionName defines the name of the persistent session token
                                which may be reflected in the cookie or the header. Users
                                should avoid reusing session names to prevent unintended
                                consequences, such as rejection or unpredictable behavior.

                                Support: Implementation-specific
                              '';
                            };
                            type = mkOption {
                              type = (
                                types.nullOr (
                                  types.enum [
                                    "Cookie"
                                    "Header"
                                  ]
                                )
                              );
                              default = null;
                              description = ''
                                Type defines the type of session persistence such as through
                                the use a header or cookie. Defaults to cookie based session
                                persistence.

                                Support: Core for "Cookie" type

                                Support: Extended for "Header" type
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        SessionPersistence defines and configures session persistence
                        for the route rule.

                        Support: Extended

                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Rules are a list of GRPC matchers, filters and actions.

            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  HTTPRoute = mkResource {
    apiVersion = "gateway.networking.k8s.io/v1";
    kind = "HTTPRoute";
    specType = (
      mkTypedSubmodule {
        options = {
          hostnames = mkOption {
            type = (types.nullOr (types.listOf types.str));
            default = null;
            description = ''
              Hostnames defines a set of hostnames that should match against the HTTP Host
              header to select a HTTPRoute used to process the request. Implementations
              MUST ignore any port value specified in the HTTP Host header while
              performing a match and (absent of any applicable header modification
              configuration) MUST forward this header unmodified to the backend.

              Valid values for Hostnames are determined by RFC 1123 definition of a
              hostname with 2 notable exceptions:

              1. IPs are not allowed.
              2. A hostname may be prefixed with a wildcard label (`*.`). The wildcard
                 label must appear by itself as the first label.

              If a hostname is specified by both the Listener and HTTPRoute, there
              must be at least one intersecting hostname for the HTTPRoute to be
              attached to the Listener. For example:

              * A Listener with `test.example.com` as the hostname matches HTTPRoutes
                that have either not specified any hostnames, or have specified at
                least one of `test.example.com` or `*.example.com`.
              * A Listener with `*.example.com` as the hostname matches HTTPRoutes
                that have either not specified any hostnames or have specified at least
                one hostname that matches the Listener hostname. For example,
                `*.example.com`, `test.example.com`, and `foo.test.example.com` would
                all match. On the other hand, `example.com` and `test.example.net` would
                not match.

              Hostnames that are prefixed with a wildcard label (`*.`) are interpreted
              as a suffix match. That means that a match for `*.example.com` would match
              both `test.example.com`, and `foo.test.example.com`, but not `example.com`.

              If both the Listener and HTTPRoute have specified hostnames, any
              HTTPRoute hostnames that do not match the Listener hostname MUST be
              ignored. For example, if a Listener specified `*.example.com`, and the
              HTTPRoute specified `test.example.com` and `test.example.net`,
              `test.example.net` must not be considered for a match.

              If both the Listener and HTTPRoute have specified hostnames, and none
              match with the criteria above, then the HTTPRoute is not accepted. The
              implementation must raise an 'Accepted' Condition with a status of
              `False` in the corresponding RouteParentStatus.

              In the event that multiple HTTPRoutes specify intersecting hostnames (e.g.
              overlapping wildcard matching and exact matching hostnames), precedence must
              be given to rules from the HTTPRoute with the largest number of:

              * Characters in a matching non-wildcard hostname.
              * Characters in a matching hostname.

              If ties exist across multiple Routes, the matching precedence rules for
              HTTPRouteMatches takes over.

              Support: Core
            '';
          };
          parentRefs = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    group = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Group is the group of the referent.
                        When unspecified, "gateway.networking.k8s.io" is inferred.
                        To set the core API group (such as for a "Service" kind referent),
                        Group must be explicitly set to "" (empty string).

                        Support: Core
                      '';
                    };
                    kind = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Kind is kind of the referent.

                        There are two kinds of parent resources with "Core" support:

                        * Gateway (Gateway conformance profile)
                        * Service (Mesh conformance profile, ClusterIP Services only)

                        Support for other resources is Implementation-Specific.
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = ''
                        Name is the name of the referent.

                        Support: Core
                      '';
                    };
                    namespace = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Namespace is the namespace of the referent. When unspecified, this refers
                        to the local namespace of the Route.

                        Note that there are specific rules for ParentRefs which cross namespace
                        boundaries. Cross-namespace references are only valid if they are explicitly
                        allowed by something in the namespace they are referring to. For example:
                        Gateway has the AllowedRoutes field, and ReferenceGrant provides a
                        generic way to enable any other kind of cross-namespace reference.


                        ParentRefs from a Route to a Service in the same namespace are "producer"
                        routes, which apply default routing rules to inbound connections from
                        any namespace to the Service.

                        ParentRefs from a Route to a Service in a different namespace are
                        "consumer" routes, and these routing rules are only applied to outbound
                        connections originating from the same namespace as the Route, for which
                        the intended destination of the connections are a Service targeted as a
                        ParentRef of the Route.


                        Support: Core
                      '';
                    };
                    port = mkOption {
                      type = (types.nullOr types.int);
                      default = null;
                      description = ''
                        Port is the network port this Route targets. It can be interpreted
                        differently based on the type of parent resource.

                        When the parent resource is a Gateway, this targets all listeners
                        listening on the specified port that also support this kind of Route(and
                        select this Route). It's not recommended to set `Port` unless the
                        networking behaviors specified in a Route must apply to a specific port
                        as opposed to a listener(s) whose port(s) may be changed. When both Port
                        and SectionName are specified, the name and port of the selected listener
                        must match both specified values.


                        When the parent resource is a Service, this targets a specific port in the
                        Service spec. When both Port (experimental) and SectionName are specified,
                        the name and port of the selected port must match both specified values.


                        Implementations MAY choose to support other parent resources.
                        Implementations supporting other types of parent resources MUST clearly
                        document how/if Port is interpreted.

                        For the purpose of status, an attachment is considered successful as
                        long as the parent resource accepts it partially. For example, Gateway
                        listeners can restrict which Routes can attach to them by Route kind,
                        namespace, or hostname. If 1 of 2 Gateway listeners accept attachment
                        from the referencing Route, the Route MUST be considered successfully
                        attached. If no Gateway listeners accept attachment from this Route,
                        the Route MUST be considered detached from the Gateway.

                        Support: Extended
                      '';
                    };
                    sectionName = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        SectionName is the name of a section within the target resource. In the
                        following resources, SectionName is interpreted as the following:

                        * Gateway: Listener name. When both Port (experimental) and SectionName
                        are specified, the name and port of the selected listener must match
                        both specified values.
                        * Service: Port name. When both Port (experimental) and SectionName
                        are specified, the name and port of the selected listener must match
                        both specified values.

                        Implementations MAY choose to support attaching Routes to other resources.
                        If that is the case, they MUST clearly document how SectionName is
                        interpreted.

                        When unspecified (empty string), this will reference the entire resource.
                        For the purpose of status, an attachment is considered successful if at
                        least one section in the parent resource accepts it. For example, Gateway
                        listeners can restrict which Routes can attach to them by Route kind,
                        namespace, or hostname. If 1 of 2 Gateway listeners accept attachment from
                        the referencing Route, the Route MUST be considered successfully
                        attached. If no Gateway listeners accept attachment from this Route, the
                        Route MUST be considered detached from the Gateway.

                        Support: Core
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              ParentRefs references the resources (usually Gateways) that a Route wants
              to be attached to. Note that the referenced parent resource needs to
              allow this for the attachment to be complete. For Gateways, that means
              the Gateway needs to allow attachment from Routes of this kind and
              namespace. For Services, that means the Service must either be in the same
              namespace for a "producer" route, or the mesh implementation must support
              and allow "consumer" routes for the referenced Service. ReferenceGrant is
              not applicable for governing ParentRefs to Services - it is not possible to
              create a "producer" route for a Service in a different namespace from the
              Route.

              There are two kinds of parent resources with "Core" support:

              * Gateway (Gateway conformance profile)
              * Service (Mesh conformance profile, ClusterIP Services only)

              This API may be extended in the future to support additional kinds of parent
              resources.

              ParentRefs must be _distinct_. This means either that:

              * They select different objects.  If this is the case, then parentRef
                entries are distinct. In terms of fields, this means that the
                multi-part key defined by `group`, `kind`, `namespace`, and `name` must
                be unique across all parentRef entries in the Route.
              * They do not select different objects, but for each optional field used,
                each ParentRef that selects the same object must set the same set of
                optional fields to different values. If one ParentRef sets a
                combination of optional fields, all must set the same combination.

              Some examples:

              * If one ParentRef sets `sectionName`, all ParentRefs referencing the
                same object must also set `sectionName`.
              * If one ParentRef sets `port`, all ParentRefs referencing the same
                object must also set `port`.
              * If one ParentRef sets `sectionName` and `port`, all ParentRefs
                referencing the same object must also set `sectionName` and `port`.

              It is possible to separately reference multiple distinct objects that may
              be collapsed by an implementation. For example, some implementations may
              choose to merge compatible Gateway Listeners together. If that is the
              case, the list of routes attached to those resources should also be
              merged.

              Note that for ParentRefs that cross namespace boundaries, there are specific
              rules. Cross-namespace references are only valid if they are explicitly
              allowed by something in the namespace they are referring to. For example,
              Gateway has the AllowedRoutes field, and ReferenceGrant provides a
              generic way to enable other kinds of cross-namespace reference.


              ParentRefs from a Route to a Service in the same namespace are "producer"
              routes, which apply default routing rules to inbound connections from
              any namespace to the Service.

              ParentRefs from a Route to a Service in a different namespace are
              "consumer" routes, and these routing rules are only applied to outbound
              connections originating from the same namespace as the Route, for which
              the intended destination of the connections are a Service targeted as a
              ParentRef of the Route.





            '';
          };
          rules = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    backendRefs = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              filters = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        extensionRef = mkOption {
                                          type = (
                                            types.nullOr (mkTypedSubmodule {
                                              options = {
                                                group = mkOption {
                                                  type = types.str;
                                                  description = ''
                                                    Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                                    When unspecified or empty string, core API group is inferred.
                                                  '';
                                                };
                                                kind = mkOption {
                                                  type = types.str;
                                                  description = "Kind is kind of the referent. For example \"HTTPRoute\" or \"Service\".";
                                                };
                                                name = mkOption {
                                                  type = types.str;
                                                  description = "Name is the name of the referent.";
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          );
                                          default = null;
                                          description = ''
                                            ExtensionRef is an optional, implementation-specific extension to the
                                            "filter" behavior.  For example, resource "myroutefilter" in group
                                            "networking.example.net"). ExtensionRef MUST NOT be used for core and
                                            extended filters.

                                            This filter can be used multiple times within the same rule.

                                            Support: Implementation-specific
                                          '';
                                        };
                                        requestHeaderModifier = mkOption {
                                          type = (
                                            types.nullOr (mkTypedSubmodule {
                                              options = {
                                                add = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = ''
                                                              Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                              case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                              If multiple entries specify equivalent header names, the first entry with
                                                              an equivalent name MUST be considered for a match. Subsequent entries
                                                              with an equivalent header name MUST be ignored. Due to the
                                                              case-insensitivity of header names, "foo" and "Foo" are considered
                                                              equivalent.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = types.str;
                                                            description = "Value is the value of HTTP Header to be matched.";
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Add adds the given header(s) (name, value) to the request
                                                    before the action. It appends to any existing values associated
                                                    with the header name.

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo

                                                    Config:
                                                      add:
                                                      - name: "my-header"
                                                        value: "bar,baz"

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo,bar,baz
                                                  '';
                                                };
                                                remove = mkOption {
                                                  type = (types.nullOr (types.listOf types.str));
                                                  default = null;
                                                  description = ''
                                                    Remove the given header(s) from the HTTP request before the action. The
                                                    value of Remove is a list of HTTP header names. Note that the header
                                                    names are case-insensitive (see
                                                    https://datatracker.ietf.org/doc/html/rfc2616#section-4.2).

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header1: foo
                                                      my-header2: bar
                                                      my-header3: baz

                                                    Config:
                                                      remove: ["my-header1", "my-header3"]

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header2: bar
                                                  '';
                                                };
                                                set = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = ''
                                                              Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                              case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                              If multiple entries specify equivalent header names, the first entry with
                                                              an equivalent name MUST be considered for a match. Subsequent entries
                                                              with an equivalent header name MUST be ignored. Due to the
                                                              case-insensitivity of header names, "foo" and "Foo" are considered
                                                              equivalent.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = types.str;
                                                            description = "Value is the value of HTTP Header to be matched.";
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Set overwrites the request with the given header (name, value)
                                                    before the action.

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo

                                                    Config:
                                                      set:
                                                      - name: "my-header"
                                                        value: "bar"

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header: bar
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          );
                                          default = null;
                                          description = ''
                                            RequestHeaderModifier defines a schema for a filter that modifies request
                                            headers.

                                            Support: Core
                                          '';
                                        };
                                        requestMirror = mkOption {
                                          type = (
                                            types.nullOr (mkTypedSubmodule {
                                              options = {
                                                backendRef = mkOption {
                                                  type = (
                                                    mkTypedSubmodule {
                                                      options = {
                                                        group = mkOption {
                                                          type = (types.nullOr types.str);
                                                          default = null;
                                                          description = ''
                                                            Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                                            When unspecified or empty string, core API group is inferred.
                                                          '';
                                                        };
                                                        kind = mkOption {
                                                          type = (types.nullOr types.str);
                                                          default = null;
                                                          description = ''
                                                            Kind is the Kubernetes resource kind of the referent. For example
                                                            "Service".

                                                            Defaults to "Service" when not specified.

                                                            ExternalName services can refer to CNAME DNS records that may live
                                                            outside of the cluster and as such are difficult to reason about in
                                                            terms of conformance. They also may not be safe to forward to (see
                                                            CVE-2021-25740 for more information). Implementations SHOULD NOT
                                                            support ExternalName Services.

                                                            Support: Core (Services with a type other than ExternalName)

                                                            Support: Implementation-specific (Services with type ExternalName)
                                                          '';
                                                        };
                                                        name = mkOption {
                                                          type = types.str;
                                                          description = "Name is the name of the referent.";
                                                        };
                                                        namespace = mkOption {
                                                          type = (types.nullOr types.str);
                                                          default = null;
                                                          description = ''
                                                            Namespace is the namespace of the backend. When unspecified, the local
                                                            namespace is inferred.

                                                            Note that when a namespace different than the local namespace is specified,
                                                            a ReferenceGrant object is required in the referent namespace to allow that
                                                            namespace's owner to accept the reference. See the ReferenceGrant
                                                            documentation for details.

                                                            Support: Core
                                                          '';
                                                        };
                                                        port = mkOption {
                                                          type = (types.nullOr types.int);
                                                          default = null;
                                                          description = ''
                                                            Port specifies the destination port number to use for this resource.
                                                            Port is required when the referent is a Kubernetes Service. In this
                                                            case, the port number is the service port number, not the target port.
                                                            For other resources, destination port might be derived from the referent
                                                            resource or this field.
                                                          '';
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    }
                                                  );
                                                  description = ''
                                                    BackendRef references a resource where mirrored requests are sent.

                                                    Mirrored requests must be sent only to a single destination endpoint
                                                    within this BackendRef, irrespective of how many endpoints are present
                                                    within this BackendRef.

                                                    If the referent cannot be found, this BackendRef is invalid and must be
                                                    dropped from the Gateway. The controller must ensure the "ResolvedRefs"
                                                    condition on the Route status is set to `status: False` and not configure
                                                    this backend in the underlying implementation.

                                                    If there is a cross-namespace reference to an *existing* object
                                                    that is not allowed by a ReferenceGrant, the controller must ensure the
                                                    "ResolvedRefs"  condition on the Route is set to `status: False`,
                                                    with the "RefNotPermitted" reason and not configure this backend in the
                                                    underlying implementation.

                                                    In either error case, the Message of the `ResolvedRefs` Condition
                                                    should be used to provide more detail about the problem.

                                                    Support: Extended for Kubernetes Service

                                                    Support: Implementation-specific for any other resource
                                                  '';
                                                };
                                                fraction = mkOption {
                                                  type = (
                                                    types.nullOr (mkTypedSubmodule {
                                                      options = {
                                                        denominator = mkOption {
                                                          type = (types.nullOr types.int);
                                                          default = null;
                                                        };
                                                        numerator = mkOption {
                                                          type = types.int;
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    })
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Fraction represents the fraction of requests that should be
                                                    mirrored to BackendRef.

                                                    Only one of Fraction or Percent may be specified. If neither field
                                                    is specified, 100% of requests will be mirrored.

                                                  '';
                                                };
                                                percent = mkOption {
                                                  type = (types.nullOr types.int);
                                                  default = null;
                                                  description = ''
                                                    Percent represents the percentage of requests that should be
                                                    mirrored to BackendRef. Its minimum value is 0 (indicating 0% of
                                                    requests) and its maximum value is 100 (indicating 100% of requests).

                                                    Only one of Fraction or Percent may be specified. If neither field
                                                    is specified, 100% of requests will be mirrored.

                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          );
                                          default = null;
                                          description = ''
                                            RequestMirror defines a schema for a filter that mirrors requests.
                                            Requests are sent to the specified destination, but responses from
                                            that destination are ignored.

                                            This filter can be used multiple times within the same rule. Note that
                                            not all implementations will be able to support mirroring to multiple
                                            backends.

                                            Support: Extended

                                          '';
                                        };
                                        requestRedirect = mkOption {
                                          type = (
                                            types.nullOr (mkTypedSubmodule {
                                              options = {
                                                hostname = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Hostname is the hostname to be used in the value of the `Location`
                                                    header in the response.
                                                    When empty, the hostname in the `Host` header of the request is used.

                                                    Support: Core
                                                  '';
                                                };
                                                path = mkOption {
                                                  type = (
                                                    types.nullOr (mkTypedSubmodule {
                                                      options = {
                                                        replaceFullPath = mkOption {
                                                          type = (types.nullOr types.str);
                                                          default = null;
                                                          description = ''
                                                            ReplaceFullPath specifies the value with which to replace the full path
                                                            of a request during a rewrite or redirect.
                                                          '';
                                                        };
                                                        replacePrefixMatch = mkOption {
                                                          type = (types.nullOr types.str);
                                                          default = null;
                                                          description = ''
                                                            ReplacePrefixMatch specifies the value with which to replace the prefix
                                                            match of a request during a rewrite or redirect. For example, a request
                                                            to "/foo/bar" with a prefix match of "/foo" and a ReplacePrefixMatch
                                                            of "/xyz" would be modified to "/xyz/bar".

                                                            Note that this matches the behavior of the PathPrefix match type. This
                                                            matches full path elements. A path element refers to the list of labels
                                                            in the path split by the `/` separator. When specified, a trailing `/` is
                                                            ignored. For example, the paths `/abc`, `/abc/`, and `/abc/def` would all
                                                            match the prefix `/abc`, but the path `/abcd` would not.

                                                            ReplacePrefixMatch is only compatible with a `PathPrefix` HTTPRouteMatch.
                                                            Using any other HTTPRouteMatch type on the same HTTPRouteRule will result in
                                                            the implementation setting the Accepted Condition for the Route to `status: False`.

                                                            Request Path | Prefix Match | Replace Prefix | Modified Path
                                                          '';
                                                        };
                                                        type = mkOption {
                                                          type = (
                                                            types.enum [
                                                              "ReplaceFullPath"
                                                              "ReplacePrefixMatch"
                                                            ]
                                                          );
                                                          description = ''
                                                            Type defines the type of path modifier. Additional types may be
                                                            added in a future release of the API.

                                                            Note that values may be added to this enum, implementations
                                                            must ensure that unknown values will not cause a crash.

                                                            Unknown values here must result in the implementation setting the
                                                            Accepted Condition for the Route to `status: False`, with a
                                                            Reason of `UnsupportedValue`.
                                                          '';
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    })
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Path defines parameters used to modify the path of the incoming request.
                                                    The modified path is then used to construct the `Location` header. When
                                                    empty, the request path is used as-is.

                                                    Support: Extended
                                                  '';
                                                };
                                                port = mkOption {
                                                  type = (types.nullOr types.int);
                                                  default = null;
                                                  description = ''
                                                    Port is the port to be used in the value of the `Location`
                                                    header in the response.

                                                    If no port is specified, the redirect port MUST be derived using the
                                                    following rules:

                                                    * If redirect scheme is not-empty, the redirect port MUST be the well-known
                                                      port associated with the redirect scheme. Specifically "http" to port 80
                                                      and "https" to port 443. If the redirect scheme does not have a
                                                      well-known port, the listener port of the Gateway SHOULD be used.
                                                    * If redirect scheme is empty, the redirect port MUST be the Gateway
                                                      Listener port.

                                                    Implementations SHOULD NOT add the port number in the 'Location'
                                                    header in the following cases:

                                                    * A Location header that will use HTTP (whether that is determined via
                                                      the Listener protocol or the Scheme field) _and_ use port 80.
                                                    * A Location header that will use HTTPS (whether that is determined via
                                                      the Listener protocol or the Scheme field) _and_ use port 443.

                                                    Support: Extended
                                                  '';
                                                };
                                                scheme = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.enum [
                                                        "http"
                                                        "https"
                                                      ]
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Scheme is the scheme to be used in the value of the `Location` header in
                                                    the response. When empty, the scheme of the request is used.

                                                    Scheme redirects can affect the port of the redirect, for more information,
                                                    refer to the documentation for the port field of this filter.

                                                    Note that values may be added to this enum, implementations
                                                    must ensure that unknown values will not cause a crash.

                                                    Unknown values here must result in the implementation setting the
                                                    Accepted Condition for the Route to `status: False`, with a
                                                    Reason of `UnsupportedValue`.

                                                    Support: Extended
                                                  '';
                                                };
                                                statusCode = mkOption {
                                                  type = (types.nullOr types.int);
                                                  default = null;
                                                  description = ''
                                                    StatusCode is the HTTP status code to be used in response.

                                                    Note that values may be added to this enum, implementations
                                                    must ensure that unknown values will not cause a crash.

                                                    Unknown values here must result in the implementation setting the
                                                    Accepted Condition for the Route to `status: False`, with a
                                                    Reason of `UnsupportedValue`.

                                                    Support: Core
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          );
                                          default = null;
                                          description = ''
                                            RequestRedirect defines a schema for a filter that responds to the
                                            request with an HTTP redirection.

                                            Support: Core
                                          '';
                                        };
                                        responseHeaderModifier = mkOption {
                                          type = (
                                            types.nullOr (mkTypedSubmodule {
                                              options = {
                                                add = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = ''
                                                              Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                              case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                              If multiple entries specify equivalent header names, the first entry with
                                                              an equivalent name MUST be considered for a match. Subsequent entries
                                                              with an equivalent header name MUST be ignored. Due to the
                                                              case-insensitivity of header names, "foo" and "Foo" are considered
                                                              equivalent.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = types.str;
                                                            description = "Value is the value of HTTP Header to be matched.";
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Add adds the given header(s) (name, value) to the request
                                                    before the action. It appends to any existing values associated
                                                    with the header name.

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo

                                                    Config:
                                                      add:
                                                      - name: "my-header"
                                                        value: "bar,baz"

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo,bar,baz
                                                  '';
                                                };
                                                remove = mkOption {
                                                  type = (types.nullOr (types.listOf types.str));
                                                  default = null;
                                                  description = ''
                                                    Remove the given header(s) from the HTTP request before the action. The
                                                    value of Remove is a list of HTTP header names. Note that the header
                                                    names are case-insensitive (see
                                                    https://datatracker.ietf.org/doc/html/rfc2616#section-4.2).

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header1: foo
                                                      my-header2: bar
                                                      my-header3: baz

                                                    Config:
                                                      remove: ["my-header1", "my-header3"]

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header2: bar
                                                  '';
                                                };
                                                set = mkOption {
                                                  type = (
                                                    types.nullOr (
                                                      types.listOf (mkTypedSubmodule {
                                                        options = {
                                                          name = mkOption {
                                                            type = types.str;
                                                            description = ''
                                                              Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                              case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                              If multiple entries specify equivalent header names, the first entry with
                                                              an equivalent name MUST be considered for a match. Subsequent entries
                                                              with an equivalent header name MUST be ignored. Due to the
                                                              case-insensitivity of header names, "foo" and "Foo" are considered
                                                              equivalent.
                                                            '';
                                                          };
                                                          value = mkOption {
                                                            type = types.str;
                                                            description = "Value is the value of HTTP Header to be matched.";
                                                          };
                                                        };
                                                        freeformType = types.attrs;
                                                      })
                                                    )
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Set overwrites the request with the given header (name, value)
                                                    before the action.

                                                    Input:
                                                      GET /foo HTTP/1.1
                                                      my-header: foo

                                                    Config:
                                                      set:
                                                      - name: "my-header"
                                                        value: "bar"

                                                    Output:
                                                      GET /foo HTTP/1.1
                                                      my-header: bar
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          );
                                          default = null;
                                          description = ''
                                            ResponseHeaderModifier defines a schema for a filter that modifies response
                                            headers.

                                            Support: Extended
                                          '';
                                        };
                                        type = mkOption {
                                          type = (
                                            types.enum [
                                              "RequestHeaderModifier"
                                              "ResponseHeaderModifier"
                                              "RequestMirror"
                                              "RequestRedirect"
                                              "URLRewrite"
                                              "ExtensionRef"
                                            ]
                                          );
                                          description = ''
                                            Type identifies the type of filter to apply. As with other API fields,
                                            types are classified into three conformance levels:

                                            - Core: Filter types and their corresponding configuration defined by
                                              "Support: Core" in this package, e.g. "RequestHeaderModifier". All
                                              implementations must support core filters.

                                            - Extended: Filter types and their corresponding configuration defined by
                                              "Support: Extended" in this package, e.g. "RequestMirror". Implementers
                                              are encouraged to support extended filters.

                                            - Implementation-specific: Filters that are defined and supported by
                                              specific vendors.
                                              In the future, filters showing convergence in behavior across multiple
                                              implementations will be considered for inclusion in extended or core
                                              conformance levels. Filter-specific configuration for such filters
                                              is specified using the ExtensionRef field. `Type` should be set to
                                              "ExtensionRef" for custom filters.

                                            Implementers are encouraged to define custom implementation types to
                                            extend the core API with implementation-specific behavior.

                                            If a reference to a custom filter type cannot be resolved, the filter
                                            MUST NOT be skipped. Instead, requests that would have been processed by
                                            that filter MUST receive a HTTP error response.

                                            Note that values may be added to this enum, implementations
                                            must ensure that unknown values will not cause a crash.

                                            Unknown values here must result in the implementation setting the
                                            Accepted Condition for the Route to `status: False`, with a
                                            Reason of `UnsupportedValue`.
                                          '';
                                        };
                                        urlRewrite = mkOption {
                                          type = (
                                            types.nullOr (mkTypedSubmodule {
                                              options = {
                                                hostname = mkOption {
                                                  type = (types.nullOr types.str);
                                                  default = null;
                                                  description = ''
                                                    Hostname is the value to be used to replace the Host header value during
                                                    forwarding.

                                                    Support: Extended
                                                  '';
                                                };
                                                path = mkOption {
                                                  type = (
                                                    types.nullOr (mkTypedSubmodule {
                                                      options = {
                                                        replaceFullPath = mkOption {
                                                          type = (types.nullOr types.str);
                                                          default = null;
                                                          description = ''
                                                            ReplaceFullPath specifies the value with which to replace the full path
                                                            of a request during a rewrite or redirect.
                                                          '';
                                                        };
                                                        replacePrefixMatch = mkOption {
                                                          type = (types.nullOr types.str);
                                                          default = null;
                                                          description = ''
                                                            ReplacePrefixMatch specifies the value with which to replace the prefix
                                                            match of a request during a rewrite or redirect. For example, a request
                                                            to "/foo/bar" with a prefix match of "/foo" and a ReplacePrefixMatch
                                                            of "/xyz" would be modified to "/xyz/bar".

                                                            Note that this matches the behavior of the PathPrefix match type. This
                                                            matches full path elements. A path element refers to the list of labels
                                                            in the path split by the `/` separator. When specified, a trailing `/` is
                                                            ignored. For example, the paths `/abc`, `/abc/`, and `/abc/def` would all
                                                            match the prefix `/abc`, but the path `/abcd` would not.

                                                            ReplacePrefixMatch is only compatible with a `PathPrefix` HTTPRouteMatch.
                                                            Using any other HTTPRouteMatch type on the same HTTPRouteRule will result in
                                                            the implementation setting the Accepted Condition for the Route to `status: False`.

                                                            Request Path | Prefix Match | Replace Prefix | Modified Path
                                                          '';
                                                        };
                                                        type = mkOption {
                                                          type = (
                                                            types.enum [
                                                              "ReplaceFullPath"
                                                              "ReplacePrefixMatch"
                                                            ]
                                                          );
                                                          description = ''
                                                            Type defines the type of path modifier. Additional types may be
                                                            added in a future release of the API.

                                                            Note that values may be added to this enum, implementations
                                                            must ensure that unknown values will not cause a crash.

                                                            Unknown values here must result in the implementation setting the
                                                            Accepted Condition for the Route to `status: False`, with a
                                                            Reason of `UnsupportedValue`.
                                                          '';
                                                        };
                                                      };
                                                      freeformType = types.attrs;
                                                    })
                                                  );
                                                  default = null;
                                                  description = ''
                                                    Path defines a path rewrite.

                                                    Support: Extended
                                                  '';
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          );
                                          default = null;
                                          description = ''
                                            URLRewrite defines a schema for a filter that modifies a request during forwarding.

                                            Support: Extended
                                          '';
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = ''
                                  Filters defined at this level should be executed if and only if the
                                  request is being forwarded to the backend defined here.

                                  Support: Implementation-specific (For broader support of filters, use the
                                  Filters field in HTTPRouteRule.)
                                '';
                              };
                              group = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                  When unspecified or empty string, core API group is inferred.
                                '';
                              };
                              kind = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  Kind is the Kubernetes resource kind of the referent. For example
                                  "Service".

                                  Defaults to "Service" when not specified.

                                  ExternalName services can refer to CNAME DNS records that may live
                                  outside of the cluster and as such are difficult to reason about in
                                  terms of conformance. They also may not be safe to forward to (see
                                  CVE-2021-25740 for more information). Implementations SHOULD NOT
                                  support ExternalName Services.

                                  Support: Core (Services with a type other than ExternalName)

                                  Support: Implementation-specific (Services with type ExternalName)
                                '';
                              };
                              name = mkOption {
                                type = types.str;
                                description = "Name is the name of the referent.";
                              };
                              namespace = mkOption {
                                type = (types.nullOr types.str);
                                default = null;
                                description = ''
                                  Namespace is the namespace of the backend. When unspecified, the local
                                  namespace is inferred.

                                  Note that when a namespace different than the local namespace is specified,
                                  a ReferenceGrant object is required in the referent namespace to allow that
                                  namespace's owner to accept the reference. See the ReferenceGrant
                                  documentation for details.

                                  Support: Core
                                '';
                              };
                              port = mkOption {
                                type = (types.nullOr types.int);
                                default = null;
                                description = ''
                                  Port specifies the destination port number to use for this resource.
                                  Port is required when the referent is a Kubernetes Service. In this
                                  case, the port number is the service port number, not the target port.
                                  For other resources, destination port might be derived from the referent
                                  resource or this field.
                                '';
                              };
                              weight = mkOption {
                                type = (types.nullOr types.int);
                                default = null;
                                description = ''
                                  Weight specifies the proportion of requests forwarded to the referenced
                                  backend. This is computed as weight/(sum of all weights in this
                                  BackendRefs list). For non-zero values, there may be some epsilon from
                                  the exact proportion defined here depending on the precision an
                                  implementation supports. Weight is not a percentage and the sum of
                                  weights does not need to equal 100.

                                  If only one backend is specified and it has a weight greater than 0, 100%
                                  of the traffic is forwarded to that backend. If weight is set to 0, no
                                  traffic should be forwarded for this entry. If unspecified, weight
                                  defaults to 1.

                                  Support for this field varies based on the context where used.
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        BackendRefs defines the backend(s) where matching requests should be
                        sent.

                        Failure behavior here depends on how many BackendRefs are specified and
                        how many are invalid.

                        If *all* entries in BackendRefs are invalid, and there are also no filters
                        specified in this route rule, *all* traffic which matches this rule MUST
                        receive a 500 status code.

                        See the HTTPBackendRef definition for the rules about what makes a single
                        HTTPBackendRef invalid.

                        When a HTTPBackendRef is invalid, 500 status codes MUST be returned for
                        requests that would have otherwise been routed to an invalid backend. If
                        multiple backends are specified, and some are invalid, the proportion of
                        requests that would otherwise have been routed to an invalid backend
                        MUST receive a 500 status code.

                        For example, if two backends are specified with equal weights, and one is
                        invalid, 50 percent of traffic must receive a 500. Implementations may
                        choose how that 50 percent is determined.

                        When a HTTPBackendRef refers to a Service that has no ready endpoints,
                        implementations SHOULD return a 503 for requests to that backend instead.
                        If an implementation chooses to do this, all of the above rules for 500 responses
                        MUST also apply for responses that return a 503.

                        Support: Core for Kubernetes Service

                        Support: Extended for Kubernetes ServiceImport

                        Support: Implementation-specific for any other resource

                        Support for weight: Core
                      '';
                    };
                    filters = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              extensionRef = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      group = mkOption {
                                        type = types.str;
                                        description = ''
                                          Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                          When unspecified or empty string, core API group is inferred.
                                        '';
                                      };
                                      kind = mkOption {
                                        type = types.str;
                                        description = "Kind is kind of the referent. For example \"HTTPRoute\" or \"Service\".";
                                      };
                                      name = mkOption {
                                        type = types.str;
                                        description = "Name is the name of the referent.";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  ExtensionRef is an optional, implementation-specific extension to the
                                  "filter" behavior.  For example, resource "myroutefilter" in group
                                  "networking.example.net"). ExtensionRef MUST NOT be used for core and
                                  extended filters.

                                  This filter can be used multiple times within the same rule.

                                  Support: Implementation-specific
                                '';
                              };
                              requestHeaderModifier = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      add = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                name = mkOption {
                                                  type = types.str;
                                                  description = ''
                                                    Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                    case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                    If multiple entries specify equivalent header names, the first entry with
                                                    an equivalent name MUST be considered for a match. Subsequent entries
                                                    with an equivalent header name MUST be ignored. Due to the
                                                    case-insensitivity of header names, "foo" and "Foo" are considered
                                                    equivalent.
                                                  '';
                                                };
                                                value = mkOption {
                                                  type = types.str;
                                                  description = "Value is the value of HTTP Header to be matched.";
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Add adds the given header(s) (name, value) to the request
                                          before the action. It appends to any existing values associated
                                          with the header name.

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header: foo

                                          Config:
                                            add:
                                            - name: "my-header"
                                              value: "bar,baz"

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header: foo,bar,baz
                                        '';
                                      };
                                      remove = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                        description = ''
                                          Remove the given header(s) from the HTTP request before the action. The
                                          value of Remove is a list of HTTP header names. Note that the header
                                          names are case-insensitive (see
                                          https://datatracker.ietf.org/doc/html/rfc2616#section-4.2).

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header1: foo
                                            my-header2: bar
                                            my-header3: baz

                                          Config:
                                            remove: ["my-header1", "my-header3"]

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header2: bar
                                        '';
                                      };
                                      set = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                name = mkOption {
                                                  type = types.str;
                                                  description = ''
                                                    Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                    case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                    If multiple entries specify equivalent header names, the first entry with
                                                    an equivalent name MUST be considered for a match. Subsequent entries
                                                    with an equivalent header name MUST be ignored. Due to the
                                                    case-insensitivity of header names, "foo" and "Foo" are considered
                                                    equivalent.
                                                  '';
                                                };
                                                value = mkOption {
                                                  type = types.str;
                                                  description = "Value is the value of HTTP Header to be matched.";
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Set overwrites the request with the given header (name, value)
                                          before the action.

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header: foo

                                          Config:
                                            set:
                                            - name: "my-header"
                                              value: "bar"

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header: bar
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  RequestHeaderModifier defines a schema for a filter that modifies request
                                  headers.

                                  Support: Core
                                '';
                              };
                              requestMirror = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      backendRef = mkOption {
                                        type = (
                                          mkTypedSubmodule {
                                            options = {
                                              group = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                                  When unspecified or empty string, core API group is inferred.
                                                '';
                                              };
                                              kind = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Kind is the Kubernetes resource kind of the referent. For example
                                                  "Service".

                                                  Defaults to "Service" when not specified.

                                                  ExternalName services can refer to CNAME DNS records that may live
                                                  outside of the cluster and as such are difficult to reason about in
                                                  terms of conformance. They also may not be safe to forward to (see
                                                  CVE-2021-25740 for more information). Implementations SHOULD NOT
                                                  support ExternalName Services.

                                                  Support: Core (Services with a type other than ExternalName)

                                                  Support: Implementation-specific (Services with type ExternalName)
                                                '';
                                              };
                                              name = mkOption {
                                                type = types.str;
                                                description = "Name is the name of the referent.";
                                              };
                                              namespace = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  Namespace is the namespace of the backend. When unspecified, the local
                                                  namespace is inferred.

                                                  Note that when a namespace different than the local namespace is specified,
                                                  a ReferenceGrant object is required in the referent namespace to allow that
                                                  namespace's owner to accept the reference. See the ReferenceGrant
                                                  documentation for details.

                                                  Support: Core
                                                '';
                                              };
                                              port = mkOption {
                                                type = (types.nullOr types.int);
                                                default = null;
                                                description = ''
                                                  Port specifies the destination port number to use for this resource.
                                                  Port is required when the referent is a Kubernetes Service. In this
                                                  case, the port number is the service port number, not the target port.
                                                  For other resources, destination port might be derived from the referent
                                                  resource or this field.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          }
                                        );
                                        description = ''
                                          BackendRef references a resource where mirrored requests are sent.

                                          Mirrored requests must be sent only to a single destination endpoint
                                          within this BackendRef, irrespective of how many endpoints are present
                                          within this BackendRef.

                                          If the referent cannot be found, this BackendRef is invalid and must be
                                          dropped from the Gateway. The controller must ensure the "ResolvedRefs"
                                          condition on the Route status is set to `status: False` and not configure
                                          this backend in the underlying implementation.

                                          If there is a cross-namespace reference to an *existing* object
                                          that is not allowed by a ReferenceGrant, the controller must ensure the
                                          "ResolvedRefs"  condition on the Route is set to `status: False`,
                                          with the "RefNotPermitted" reason and not configure this backend in the
                                          underlying implementation.

                                          In either error case, the Message of the `ResolvedRefs` Condition
                                          should be used to provide more detail about the problem.

                                          Support: Extended for Kubernetes Service

                                          Support: Implementation-specific for any other resource
                                        '';
                                      };
                                      fraction = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              denominator = mkOption {
                                                type = (types.nullOr types.int);
                                                default = null;
                                              };
                                              numerator = mkOption {
                                                type = types.int;
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = ''
                                          Fraction represents the fraction of requests that should be
                                          mirrored to BackendRef.

                                          Only one of Fraction or Percent may be specified. If neither field
                                          is specified, 100% of requests will be mirrored.

                                        '';
                                      };
                                      percent = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          Percent represents the percentage of requests that should be
                                          mirrored to BackendRef. Its minimum value is 0 (indicating 0% of
                                          requests) and its maximum value is 100 (indicating 100% of requests).

                                          Only one of Fraction or Percent may be specified. If neither field
                                          is specified, 100% of requests will be mirrored.

                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  RequestMirror defines a schema for a filter that mirrors requests.
                                  Requests are sent to the specified destination, but responses from
                                  that destination are ignored.

                                  This filter can be used multiple times within the same rule. Note that
                                  not all implementations will be able to support mirroring to multiple
                                  backends.

                                  Support: Extended

                                '';
                              };
                              requestRedirect = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      hostname = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Hostname is the hostname to be used in the value of the `Location`
                                          header in the response.
                                          When empty, the hostname in the `Host` header of the request is used.

                                          Support: Core
                                        '';
                                      };
                                      path = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              replaceFullPath = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  ReplaceFullPath specifies the value with which to replace the full path
                                                  of a request during a rewrite or redirect.
                                                '';
                                              };
                                              replacePrefixMatch = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  ReplacePrefixMatch specifies the value with which to replace the prefix
                                                  match of a request during a rewrite or redirect. For example, a request
                                                  to "/foo/bar" with a prefix match of "/foo" and a ReplacePrefixMatch
                                                  of "/xyz" would be modified to "/xyz/bar".

                                                  Note that this matches the behavior of the PathPrefix match type. This
                                                  matches full path elements. A path element refers to the list of labels
                                                  in the path split by the `/` separator. When specified, a trailing `/` is
                                                  ignored. For example, the paths `/abc`, `/abc/`, and `/abc/def` would all
                                                  match the prefix `/abc`, but the path `/abcd` would not.

                                                  ReplacePrefixMatch is only compatible with a `PathPrefix` HTTPRouteMatch.
                                                  Using any other HTTPRouteMatch type on the same HTTPRouteRule will result in
                                                  the implementation setting the Accepted Condition for the Route to `status: False`.

                                                  Request Path | Prefix Match | Replace Prefix | Modified Path
                                                '';
                                              };
                                              type = mkOption {
                                                type = (
                                                  types.enum [
                                                    "ReplaceFullPath"
                                                    "ReplacePrefixMatch"
                                                  ]
                                                );
                                                description = ''
                                                  Type defines the type of path modifier. Additional types may be
                                                  added in a future release of the API.

                                                  Note that values may be added to this enum, implementations
                                                  must ensure that unknown values will not cause a crash.

                                                  Unknown values here must result in the implementation setting the
                                                  Accepted Condition for the Route to `status: False`, with a
                                                  Reason of `UnsupportedValue`.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = ''
                                          Path defines parameters used to modify the path of the incoming request.
                                          The modified path is then used to construct the `Location` header. When
                                          empty, the request path is used as-is.

                                          Support: Extended
                                        '';
                                      };
                                      port = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          Port is the port to be used in the value of the `Location`
                                          header in the response.

                                          If no port is specified, the redirect port MUST be derived using the
                                          following rules:

                                          * If redirect scheme is not-empty, the redirect port MUST be the well-known
                                            port associated with the redirect scheme. Specifically "http" to port 80
                                            and "https" to port 443. If the redirect scheme does not have a
                                            well-known port, the listener port of the Gateway SHOULD be used.
                                          * If redirect scheme is empty, the redirect port MUST be the Gateway
                                            Listener port.

                                          Implementations SHOULD NOT add the port number in the 'Location'
                                          header in the following cases:

                                          * A Location header that will use HTTP (whether that is determined via
                                            the Listener protocol or the Scheme field) _and_ use port 80.
                                          * A Location header that will use HTTPS (whether that is determined via
                                            the Listener protocol or the Scheme field) _and_ use port 443.

                                          Support: Extended
                                        '';
                                      };
                                      scheme = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.enum [
                                              "http"
                                              "https"
                                            ]
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Scheme is the scheme to be used in the value of the `Location` header in
                                          the response. When empty, the scheme of the request is used.

                                          Scheme redirects can affect the port of the redirect, for more information,
                                          refer to the documentation for the port field of this filter.

                                          Note that values may be added to this enum, implementations
                                          must ensure that unknown values will not cause a crash.

                                          Unknown values here must result in the implementation setting the
                                          Accepted Condition for the Route to `status: False`, with a
                                          Reason of `UnsupportedValue`.

                                          Support: Extended
                                        '';
                                      };
                                      statusCode = mkOption {
                                        type = (types.nullOr types.int);
                                        default = null;
                                        description = ''
                                          StatusCode is the HTTP status code to be used in response.

                                          Note that values may be added to this enum, implementations
                                          must ensure that unknown values will not cause a crash.

                                          Unknown values here must result in the implementation setting the
                                          Accepted Condition for the Route to `status: False`, with a
                                          Reason of `UnsupportedValue`.

                                          Support: Core
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  RequestRedirect defines a schema for a filter that responds to the
                                  request with an HTTP redirection.

                                  Support: Core
                                '';
                              };
                              responseHeaderModifier = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      add = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                name = mkOption {
                                                  type = types.str;
                                                  description = ''
                                                    Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                    case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                    If multiple entries specify equivalent header names, the first entry with
                                                    an equivalent name MUST be considered for a match. Subsequent entries
                                                    with an equivalent header name MUST be ignored. Due to the
                                                    case-insensitivity of header names, "foo" and "Foo" are considered
                                                    equivalent.
                                                  '';
                                                };
                                                value = mkOption {
                                                  type = types.str;
                                                  description = "Value is the value of HTTP Header to be matched.";
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Add adds the given header(s) (name, value) to the request
                                          before the action. It appends to any existing values associated
                                          with the header name.

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header: foo

                                          Config:
                                            add:
                                            - name: "my-header"
                                              value: "bar,baz"

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header: foo,bar,baz
                                        '';
                                      };
                                      remove = mkOption {
                                        type = (types.nullOr (types.listOf types.str));
                                        default = null;
                                        description = ''
                                          Remove the given header(s) from the HTTP request before the action. The
                                          value of Remove is a list of HTTP header names. Note that the header
                                          names are case-insensitive (see
                                          https://datatracker.ietf.org/doc/html/rfc2616#section-4.2).

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header1: foo
                                            my-header2: bar
                                            my-header3: baz

                                          Config:
                                            remove: ["my-header1", "my-header3"]

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header2: bar
                                        '';
                                      };
                                      set = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.listOf (mkTypedSubmodule {
                                              options = {
                                                name = mkOption {
                                                  type = types.str;
                                                  description = ''
                                                    Name is the name of the HTTP Header to be matched. Name matching MUST be
                                                    case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                                    If multiple entries specify equivalent header names, the first entry with
                                                    an equivalent name MUST be considered for a match. Subsequent entries
                                                    with an equivalent header name MUST be ignored. Due to the
                                                    case-insensitivity of header names, "foo" and "Foo" are considered
                                                    equivalent.
                                                  '';
                                                };
                                                value = mkOption {
                                                  type = types.str;
                                                  description = "Value is the value of HTTP Header to be matched.";
                                                };
                                              };
                                              freeformType = types.attrs;
                                            })
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Set overwrites the request with the given header (name, value)
                                          before the action.

                                          Input:
                                            GET /foo HTTP/1.1
                                            my-header: foo

                                          Config:
                                            set:
                                            - name: "my-header"
                                              value: "bar"

                                          Output:
                                            GET /foo HTTP/1.1
                                            my-header: bar
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  ResponseHeaderModifier defines a schema for a filter that modifies response
                                  headers.

                                  Support: Extended
                                '';
                              };
                              type = mkOption {
                                type = (
                                  types.enum [
                                    "RequestHeaderModifier"
                                    "ResponseHeaderModifier"
                                    "RequestMirror"
                                    "RequestRedirect"
                                    "URLRewrite"
                                    "ExtensionRef"
                                  ]
                                );
                                description = ''
                                  Type identifies the type of filter to apply. As with other API fields,
                                  types are classified into three conformance levels:

                                  - Core: Filter types and their corresponding configuration defined by
                                    "Support: Core" in this package, e.g. "RequestHeaderModifier". All
                                    implementations must support core filters.

                                  - Extended: Filter types and their corresponding configuration defined by
                                    "Support: Extended" in this package, e.g. "RequestMirror". Implementers
                                    are encouraged to support extended filters.

                                  - Implementation-specific: Filters that are defined and supported by
                                    specific vendors.
                                    In the future, filters showing convergence in behavior across multiple
                                    implementations will be considered for inclusion in extended or core
                                    conformance levels. Filter-specific configuration for such filters
                                    is specified using the ExtensionRef field. `Type` should be set to
                                    "ExtensionRef" for custom filters.

                                  Implementers are encouraged to define custom implementation types to
                                  extend the core API with implementation-specific behavior.

                                  If a reference to a custom filter type cannot be resolved, the filter
                                  MUST NOT be skipped. Instead, requests that would have been processed by
                                  that filter MUST receive a HTTP error response.

                                  Note that values may be added to this enum, implementations
                                  must ensure that unknown values will not cause a crash.

                                  Unknown values here must result in the implementation setting the
                                  Accepted Condition for the Route to `status: False`, with a
                                  Reason of `UnsupportedValue`.
                                '';
                              };
                              urlRewrite = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      hostname = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = ''
                                          Hostname is the value to be used to replace the Host header value during
                                          forwarding.

                                          Support: Extended
                                        '';
                                      };
                                      path = mkOption {
                                        type = (
                                          types.nullOr (mkTypedSubmodule {
                                            options = {
                                              replaceFullPath = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  ReplaceFullPath specifies the value with which to replace the full path
                                                  of a request during a rewrite or redirect.
                                                '';
                                              };
                                              replacePrefixMatch = mkOption {
                                                type = (types.nullOr types.str);
                                                default = null;
                                                description = ''
                                                  ReplacePrefixMatch specifies the value with which to replace the prefix
                                                  match of a request during a rewrite or redirect. For example, a request
                                                  to "/foo/bar" with a prefix match of "/foo" and a ReplacePrefixMatch
                                                  of "/xyz" would be modified to "/xyz/bar".

                                                  Note that this matches the behavior of the PathPrefix match type. This
                                                  matches full path elements. A path element refers to the list of labels
                                                  in the path split by the `/` separator. When specified, a trailing `/` is
                                                  ignored. For example, the paths `/abc`, `/abc/`, and `/abc/def` would all
                                                  match the prefix `/abc`, but the path `/abcd` would not.

                                                  ReplacePrefixMatch is only compatible with a `PathPrefix` HTTPRouteMatch.
                                                  Using any other HTTPRouteMatch type on the same HTTPRouteRule will result in
                                                  the implementation setting the Accepted Condition for the Route to `status: False`.

                                                  Request Path | Prefix Match | Replace Prefix | Modified Path
                                                '';
                                              };
                                              type = mkOption {
                                                type = (
                                                  types.enum [
                                                    "ReplaceFullPath"
                                                    "ReplacePrefixMatch"
                                                  ]
                                                );
                                                description = ''
                                                  Type defines the type of path modifier. Additional types may be
                                                  added in a future release of the API.

                                                  Note that values may be added to this enum, implementations
                                                  must ensure that unknown values will not cause a crash.

                                                  Unknown values here must result in the implementation setting the
                                                  Accepted Condition for the Route to `status: False`, with a
                                                  Reason of `UnsupportedValue`.
                                                '';
                                              };
                                            };
                                            freeformType = types.attrs;
                                          })
                                        );
                                        default = null;
                                        description = ''
                                          Path defines a path rewrite.

                                          Support: Extended
                                        '';
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  URLRewrite defines a schema for a filter that modifies a request during forwarding.

                                  Support: Extended
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        Filters define the filters that are applied to requests that match
                        this rule.

                        Wherever possible, implementations SHOULD implement filters in the order
                        they are specified.

                        Implementations MAY choose to implement this ordering strictly, rejecting
                        any combination or order of filters that can not be supported. If implementations
                        choose a strict interpretation of filter ordering, they MUST clearly document
                        that behavior.

                        To reject an invalid combination or order of filters, implementations SHOULD
                        consider the Route Rules with this configuration invalid. If all Route Rules
                        in a Route are invalid, the entire Route would be considered invalid. If only
                        a portion of Route Rules are invalid, implementations MUST set the
                        "PartiallyInvalid" condition for the Route.

                        Conformance-levels at this level are defined based on the type of filter:

                        - ALL core filters MUST be supported by all implementations.
                        - Implementers are encouraged to support extended filters.
                        - Implementation-specific custom filters have no API guarantees across
                          implementations.

                        Specifying the same filter multiple times is not supported unless explicitly
                        indicated in the filter.

                        All filters are expected to be compatible with each other except for the
                        URLRewrite and RequestRedirect filters, which may not be combined. If an
                        implementation can not support other combinations of filters, they must clearly
                        document that limitation. In cases where incompatible or unsupported
                        filters are specified and cause the `Accepted` condition to be set to status
                        `False`, implementations may use the `IncompatibleFilters` reason to specify
                        this configuration error.

                        Support: Core
                      '';
                    };
                    matches = mkOption {
                      type = (
                        types.nullOr (
                          types.listOf (mkTypedSubmodule {
                            options = {
                              headers = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        name = mkOption {
                                          type = types.str;
                                          description = ''
                                            Name is the name of the HTTP Header to be matched. Name matching MUST be
                                            case insensitive. (See https://tools.ietf.org/html/rfc7230#section-3.2).

                                            If multiple entries specify equivalent header names, only the first
                                            entry with an equivalent name MUST be considered for a match. Subsequent
                                            entries with an equivalent header name MUST be ignored. Due to the
                                            case-insensitivity of header names, "foo" and "Foo" are considered
                                            equivalent.

                                            When a header is repeated in an HTTP request, it is
                                            implementation-specific behavior as to how this is represented.
                                            Generally, proxies should follow the guidance from the RFC:
                                            https://www.rfc-editor.org/rfc/rfc7230.html#section-3.2.2 regarding
                                            processing a repeated header, with special handling for "Set-Cookie".
                                          '';
                                        };
                                        type = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "Exact"
                                                "RegularExpression"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Type specifies how to match against the value of the header.

                                            Support: Core (Exact)

                                            Support: Implementation-specific (RegularExpression)

                                            Since RegularExpression HeaderMatchType has implementation-specific
                                            conformance, implementations can support POSIX, PCRE or any other dialects
                                            of regular expressions. Please read the implementation's documentation to
                                            determine the supported dialect.
                                          '';
                                        };
                                        value = mkOption {
                                          type = types.str;
                                          description = "Value is the value of HTTP Header to be matched.";
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = ''
                                  Headers specifies HTTP request header matchers. Multiple match values are
                                  ANDed together, meaning, a request must match all the specified headers
                                  to select the route.
                                '';
                              };
                              method = mkOption {
                                type = (
                                  types.nullOr (
                                    types.enum [
                                      "GET"
                                      "HEAD"
                                      "POST"
                                      "PUT"
                                      "DELETE"
                                      "CONNECT"
                                      "OPTIONS"
                                      "TRACE"
                                      "PATCH"
                                    ]
                                  )
                                );
                                default = null;
                                description = ''
                                  Method specifies HTTP method matcher.
                                  When specified, this route will be matched only if the request has the
                                  specified method.

                                  Support: Extended
                                '';
                              };
                              path = mkOption {
                                type = (
                                  types.nullOr (mkTypedSubmodule {
                                    options = {
                                      type = mkOption {
                                        type = (
                                          types.nullOr (
                                            types.enum [
                                              "Exact"
                                              "PathPrefix"
                                              "RegularExpression"
                                            ]
                                          )
                                        );
                                        default = null;
                                        description = ''
                                          Type specifies how to match against the path Value.

                                          Support: Core (Exact, PathPrefix)

                                          Support: Implementation-specific (RegularExpression)
                                        '';
                                      };
                                      value = mkOption {
                                        type = (types.nullOr types.str);
                                        default = null;
                                        description = "Value of the HTTP path to match against.";
                                      };
                                    };
                                    freeformType = types.attrs;
                                  })
                                );
                                default = null;
                                description = ''
                                  Path specifies a HTTP request path matcher. If this field is not
                                  specified, a default prefix match on the "/" path is provided.
                                '';
                              };
                              queryParams = mkOption {
                                type = (
                                  types.nullOr (
                                    types.listOf (mkTypedSubmodule {
                                      options = {
                                        name = mkOption {
                                          type = types.str;
                                          description = ''
                                            Name is the name of the HTTP query param to be matched. This must be an
                                            exact string match. (See
                                            https://tools.ietf.org/html/rfc7230#section-2.7.3).

                                            If multiple entries specify equivalent query param names, only the first
                                            entry with an equivalent name MUST be considered for a match. Subsequent
                                            entries with an equivalent query param name MUST be ignored.

                                            If a query param is repeated in an HTTP request, the behavior is
                                            purposely left undefined, since different data planes have different
                                            capabilities. However, it is *recommended* that implementations should
                                            match against the first value of the param if the data plane supports it,
                                            as this behavior is expected in other load balancing contexts outside of
                                            the Gateway API.

                                            Users SHOULD NOT route traffic based on repeated query params to guard
                                            themselves against potential differences in the implementations.
                                          '';
                                        };
                                        type = mkOption {
                                          type = (
                                            types.nullOr (
                                              types.enum [
                                                "Exact"
                                                "RegularExpression"
                                              ]
                                            )
                                          );
                                          default = null;
                                          description = ''
                                            Type specifies how to match against the value of the query parameter.

                                            Support: Extended (Exact)

                                            Support: Implementation-specific (RegularExpression)

                                            Since RegularExpression QueryParamMatchType has Implementation-specific
                                            conformance, implementations can support POSIX, PCRE or any other
                                            dialects of regular expressions. Please read the implementation's
                                            documentation to determine the supported dialect.
                                          '';
                                        };
                                        value = mkOption {
                                          type = types.str;
                                          description = "Value is the value of HTTP query param to be matched.";
                                        };
                                      };
                                      freeformType = types.attrs;
                                    })
                                  )
                                );
                                default = null;
                                description = ''
                                  QueryParams specifies HTTP query parameter matchers. Multiple match
                                  values are ANDed together, meaning, a request must match all the
                                  specified query parameters to select the route.

                                  Support: Extended
                                '';
                              };
                            };
                            freeformType = types.attrs;
                          })
                        )
                      );
                      default = null;
                      description = ''
                        Matches define conditions used for matching the rule against incoming
                        HTTP requests. Each match is independent, i.e. this rule will be matched
                        if **any** one of the matches is satisfied.

                        For example, take the following matches configuration:

                        ```
                        matches:
                        - path:
                            value: "/foo"
                          headers:
                          - name: "version"
                            value: "v2"
                        - path:
                            value: "/v2/foo"
                        ```

                        For a request to match against this rule, a request must satisfy
                        EITHER of the two conditions:

                        - path prefixed with `/foo` AND contains the header `version: v2`
                        - path prefix of `/v2/foo`

                        See the documentation for HTTPRouteMatch on how to specify multiple
                        match conditions that should be ANDed together.

                        If no matches are specified, the default is a prefix
                        path match on "/", which has the effect of matching every
                        HTTP request.

                        Proxy or Load Balancer routing configuration generated from HTTPRoutes
                        MUST prioritize matches based on the following criteria, continuing on
                        ties. Across all rules specified on applicable Routes, precedence must be
                        given to the match having:

                        * "Exact" path match.
                        * "Prefix" path match with largest number of characters.
                        * Method match.
                        * Largest number of header matches.
                        * Largest number of query param matches.

                        Note: The precedence of RegularExpression path matches are implementation-specific.

                        If ties still exist across multiple Routes, matching precedence MUST be
                        determined in order of the following criteria, continuing on ties:

                        * The oldest Route based on creation timestamp.
                        * The Route appearing first in alphabetical order by
                          "{namespace}/{name}".

                        If ties still exist within an HTTPRoute, matching precedence MUST be granted
                        to the FIRST matching rule (in list order) with a match meeting the above
                        criteria.

                        When no rules matching a request have been successfully attached to the
                        parent a request is coming from, a HTTP 404 status code MUST be returned.
                      '';
                    };
                    name = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Name is the name of the route rule. This name MUST be unique within a Route if it is set.

                        Support: Extended
                      '';
                    };
                    retry = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            attempts = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                Attempts specifies the maxmimum number of times an individual request
                                from the gateway to a backend should be retried.

                                If the maximum number of retries has been attempted without a successful
                                response from the backend, the Gateway MUST return an error.

                                When this field is unspecified, the number of times to attempt to retry
                                a backend request is implementation-specific.

                                Support: Extended
                              '';
                            };
                            backoff = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Backoff specifies the minimum duration a Gateway should wait between
                                retry attempts and is represented in Gateway API Duration formatting.

                                For example, setting the `rules[].retry.backoff` field to the value
                                `100ms` will cause a backend request to first be retried approximately
                                100 milliseconds after timing out or receiving a response code configured
                                to be retryable.

                                An implementation MAY use an exponential or alternative backoff strategy
                                for subsequent retry attempts, MAY cap the maximum backoff duration to
                                some amount greater than the specified minimum, and MAY add arbitrary
                                jitter to stagger requests, as long as unsuccessful backend requests are
                                not retried before the configured minimum duration.

                                If a Request timeout (`rules[].timeouts.request`) is configured on the
                                route, the entire duration of the initial request and any retry attempts
                                MUST not exceed the Request timeout duration. If any retry attempts are
                                still in progress when the Request timeout duration has been reached,
                                these SHOULD be canceled if possible and the Gateway MUST immediately
                                return a timeout error.

                                If a BackendRequest timeout (`rules[].timeouts.backendRequest`) is
                                configured on the route, any retry attempts which reach the configured
                                BackendRequest timeout duration without a response SHOULD be canceled if
                                possible and the Gateway should wait for at least the specified backoff
                                duration before attempting to retry the backend request again.

                                If a BackendRequest timeout is _not_ configured on the route, retry
                                attempts MAY time out after an implementation default duration, or MAY
                                remain pending until a configured Request timeout or implementation
                                default duration for total request time is reached.

                                When this field is unspecified, the time to wait between retry attempts
                                is implementation-specific.

                                Support: Extended
                              '';
                            };
                            codes = mkOption {
                              type = (types.nullOr (types.listOf types.int));
                              default = null;
                              description = ''
                                Codes defines the HTTP response status codes for which a backend request
                                should be retried.

                                Support: Extended
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        Retry defines the configuration for when to retry an HTTP request.

                        Support: Extended

                      '';
                    };
                    sessionPersistence = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            absoluteTimeout = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                AbsoluteTimeout defines the absolute timeout of the persistent
                                session. Once the AbsoluteTimeout duration has elapsed, the
                                session becomes invalid.

                                Support: Extended
                              '';
                            };
                            cookieConfig = mkOption {
                              type = (
                                types.nullOr (mkTypedSubmodule {
                                  options = {
                                    lifetimeType = mkOption {
                                      type = (
                                        types.nullOr (
                                          types.enum [
                                            "Permanent"
                                            "Session"
                                          ]
                                        )
                                      );
                                      default = null;
                                      description = ''
                                        LifetimeType specifies whether the cookie has a permanent or
                                        session-based lifetime. A permanent cookie persists until its
                                        specified expiry time, defined by the Expires or Max-Age cookie
                                        attributes, while a session cookie is deleted when the current
                                        session ends.

                                        When set to "Permanent", AbsoluteTimeout indicates the
                                        cookie's lifetime via the Expires or Max-Age cookie attributes
                                        and is required.

                                        When set to "Session", AbsoluteTimeout indicates the
                                        absolute lifetime of the cookie tracked by the gateway and
                                        is optional.

                                        Support: Core for "Session" type

                                        Support: Extended for "Permanent" type
                                      '';
                                    };
                                  };
                                  freeformType = types.attrs;
                                })
                              );
                              default = null;
                              description = ''
                                CookieConfig provides configuration settings that are specific
                                to cookie-based session persistence.

                                Support: Core
                              '';
                            };
                            idleTimeout = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                IdleTimeout defines the idle timeout of the persistent session.
                                Once the session has been idle for more than the specified
                                IdleTimeout duration, the session becomes invalid.

                                Support: Extended
                              '';
                            };
                            sessionName = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                SessionName defines the name of the persistent session token
                                which may be reflected in the cookie or the header. Users
                                should avoid reusing session names to prevent unintended
                                consequences, such as rejection or unpredictable behavior.

                                Support: Implementation-specific
                              '';
                            };
                            type = mkOption {
                              type = (
                                types.nullOr (
                                  types.enum [
                                    "Cookie"
                                    "Header"
                                  ]
                                )
                              );
                              default = null;
                              description = ''
                                Type defines the type of session persistence such as through
                                the use a header or cookie. Defaults to cookie based session
                                persistence.

                                Support: Core for "Cookie" type

                                Support: Extended for "Header" type
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        SessionPersistence defines and configures session persistence
                        for the route rule.

                        Support: Extended

                      '';
                    };
                    timeouts = mkOption {
                      type = (
                        types.nullOr (mkTypedSubmodule {
                          options = {
                            backendRequest = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                BackendRequest specifies a timeout for an individual request from the gateway
                                to a backend. This covers the time from when the request first starts being
                                sent from the gateway to when the full response has been received from the backend.

                                Setting a timeout to the zero duration (e.g. "0s") SHOULD disable the timeout
                                completely. Implementations that cannot completely disable the timeout MUST
                                instead interpret the zero duration as the longest possible value to which
                                the timeout can be set.

                                An entire client HTTP transaction with a gateway, covered by the Request timeout,
                                may result in more than one call from the gateway to the destination backend,
                                for example, if automatic retries are supported.

                                The value of BackendRequest must be a Gateway API Duration string as defined by
                                GEP-2257.  When this field is unspecified, its behavior is implementation-specific;
                                when specified, the value of BackendRequest must be no more than the value of the
                                Request timeout (since the Request timeout encompasses the BackendRequest timeout).

                                Support: Extended
                              '';
                            };
                            request = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Request specifies the maximum duration for a gateway to respond to an HTTP request.
                                If the gateway has not been able to respond before this deadline is met, the gateway
                                MUST return a timeout error.

                                For example, setting the `rules.timeouts.request` field to the value `10s` in an
                                `HTTPRoute` will cause a timeout if a client request is taking longer than 10 seconds
                                to complete.

                                Setting a timeout to the zero duration (e.g. "0s") SHOULD disable the timeout
                                completely. Implementations that cannot completely disable the timeout MUST
                                instead interpret the zero duration as the longest possible value to which
                                the timeout can be set.

                                This timeout is intended to cover as close to the whole request-response transaction
                                as possible although an implementation MAY choose to start the timeout after the entire
                                request stream has been received instead of immediately after the transaction is
                                initiated by the client.

                                The value of Request is a Gateway API Duration string as defined by GEP-2257. When this
                                field is unspecified, request timeout behavior is implementation-specific.

                                Support: Extended
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      );
                      default = null;
                      description = ''
                        Timeouts defines the timeouts that can be configured for an HTTP request.

                        Support: Extended
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              Rules are a list of HTTP matchers, filters and actions.

            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  ReferenceGrant = mkResource {
    apiVersion = "gateway.networking.k8s.io/v1beta1";
    kind = "ReferenceGrant";
    specType = (
      mkTypedSubmodule {
        options = {
          from = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  group = mkOption {
                    type = types.str;
                    description = ''
                      Group is the group of the referent.
                      When empty, the Kubernetes core API group is inferred.

                      Support: Core
                    '';
                  };
                  kind = mkOption {
                    type = types.str;
                    description = ''
                      Kind is the kind of the referent. Although implementations may support
                      additional resources, the following types are part of the "Core"
                      support level for this field.

                      When used to permit a SecretObjectReference:

                      * Gateway

                      When used to permit a BackendObjectReference:

                      * GRPCRoute
                      * HTTPRoute
                      * TCPRoute
                      * TLSRoute
                      * UDPRoute
                    '';
                  };
                  namespace = mkOption {
                    type = types.str;
                    description = ''
                      Namespace is the namespace of the referent.

                      Support: Core
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              From describes the trusted namespaces and kinds that can reference the
              resources described in "To". Each entry in this list MUST be considered
              to be an additional place that references can be valid from, or to put
              this another way, entries MUST be combined using OR.

              Support: Core
            '';
          };
          to = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  group = mkOption {
                    type = types.str;
                    description = ''
                      Group is the group of the referent.
                      When empty, the Kubernetes core API group is inferred.

                      Support: Core
                    '';
                  };
                  kind = mkOption {
                    type = types.str;
                    description = ''
                      Kind is the kind of the referent. Although implementations may support
                      additional resources, the following types are part of the "Core"
                      support level for this field:

                      * Secret when used to permit a SecretObjectReference
                      * Service when used to permit a BackendObjectReference
                    '';
                  };
                  name = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      Name is the name of the referent. When unspecified, this policy
                      refers to all resources of the specified Group and Kind in the local
                      namespace.
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              To describes the resources that may be referenced by the resources
              described in "From". Each entry in this list MUST be considered to be an
              additional place that references can be valid to, or to put this another
              way, entries MUST be combined using OR.

              Support: Core
            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  TCPRoute = mkResource {
    apiVersion = "gateway.networking.k8s.io/v1alpha2";
    kind = "TCPRoute";
    specType = (
      mkTypedSubmodule {
        options = {
          parentRefs = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    group = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Group is the group of the referent.
                        When unspecified, "gateway.networking.k8s.io" is inferred.
                        To set the core API group (such as for a "Service" kind referent),
                        Group must be explicitly set to "" (empty string).

                        Support: Core
                      '';
                    };
                    kind = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Kind is kind of the referent.

                        There are two kinds of parent resources with "Core" support:

                        * Gateway (Gateway conformance profile)
                        * Service (Mesh conformance profile, ClusterIP Services only)

                        Support for other resources is Implementation-Specific.
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = ''
                        Name is the name of the referent.

                        Support: Core
                      '';
                    };
                    namespace = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Namespace is the namespace of the referent. When unspecified, this refers
                        to the local namespace of the Route.

                        Note that there are specific rules for ParentRefs which cross namespace
                        boundaries. Cross-namespace references are only valid if they are explicitly
                        allowed by something in the namespace they are referring to. For example:
                        Gateway has the AllowedRoutes field, and ReferenceGrant provides a
                        generic way to enable any other kind of cross-namespace reference.


                        ParentRefs from a Route to a Service in the same namespace are "producer"
                        routes, which apply default routing rules to inbound connections from
                        any namespace to the Service.

                        ParentRefs from a Route to a Service in a different namespace are
                        "consumer" routes, and these routing rules are only applied to outbound
                        connections originating from the same namespace as the Route, for which
                        the intended destination of the connections are a Service targeted as a
                        ParentRef of the Route.


                        Support: Core
                      '';
                    };
                    port = mkOption {
                      type = (types.nullOr types.int);
                      default = null;
                      description = ''
                        Port is the network port this Route targets. It can be interpreted
                        differently based on the type of parent resource.

                        When the parent resource is a Gateway, this targets all listeners
                        listening on the specified port that also support this kind of Route(and
                        select this Route). It's not recommended to set `Port` unless the
                        networking behaviors specified in a Route must apply to a specific port
                        as opposed to a listener(s) whose port(s) may be changed. When both Port
                        and SectionName are specified, the name and port of the selected listener
                        must match both specified values.


                        When the parent resource is a Service, this targets a specific port in the
                        Service spec. When both Port (experimental) and SectionName are specified,
                        the name and port of the selected port must match both specified values.


                        Implementations MAY choose to support other parent resources.
                        Implementations supporting other types of parent resources MUST clearly
                        document how/if Port is interpreted.

                        For the purpose of status, an attachment is considered successful as
                        long as the parent resource accepts it partially. For example, Gateway
                        listeners can restrict which Routes can attach to them by Route kind,
                        namespace, or hostname. If 1 of 2 Gateway listeners accept attachment
                        from the referencing Route, the Route MUST be considered successfully
                        attached. If no Gateway listeners accept attachment from this Route,
                        the Route MUST be considered detached from the Gateway.

                        Support: Extended
                      '';
                    };
                    sectionName = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        SectionName is the name of a section within the target resource. In the
                        following resources, SectionName is interpreted as the following:

                        * Gateway: Listener name. When both Port (experimental) and SectionName
                        are specified, the name and port of the selected listener must match
                        both specified values.
                        * Service: Port name. When both Port (experimental) and SectionName
                        are specified, the name and port of the selected listener must match
                        both specified values.

                        Implementations MAY choose to support attaching Routes to other resources.
                        If that is the case, they MUST clearly document how SectionName is
                        interpreted.

                        When unspecified (empty string), this will reference the entire resource.
                        For the purpose of status, an attachment is considered successful if at
                        least one section in the parent resource accepts it. For example, Gateway
                        listeners can restrict which Routes can attach to them by Route kind,
                        namespace, or hostname. If 1 of 2 Gateway listeners accept attachment from
                        the referencing Route, the Route MUST be considered successfully
                        attached. If no Gateway listeners accept attachment from this Route, the
                        Route MUST be considered detached from the Gateway.

                        Support: Core
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              ParentRefs references the resources (usually Gateways) that a Route wants
              to be attached to. Note that the referenced parent resource needs to
              allow this for the attachment to be complete. For Gateways, that means
              the Gateway needs to allow attachment from Routes of this kind and
              namespace. For Services, that means the Service must either be in the same
              namespace for a "producer" route, or the mesh implementation must support
              and allow "consumer" routes for the referenced Service. ReferenceGrant is
              not applicable for governing ParentRefs to Services - it is not possible to
              create a "producer" route for a Service in a different namespace from the
              Route.

              There are two kinds of parent resources with "Core" support:

              * Gateway (Gateway conformance profile)
              * Service (Mesh conformance profile, ClusterIP Services only)

              This API may be extended in the future to support additional kinds of parent
              resources.

              ParentRefs must be _distinct_. This means either that:

              * They select different objects.  If this is the case, then parentRef
                entries are distinct. In terms of fields, this means that the
                multi-part key defined by `group`, `kind`, `namespace`, and `name` must
                be unique across all parentRef entries in the Route.
              * They do not select different objects, but for each optional field used,
                each ParentRef that selects the same object must set the same set of
                optional fields to different values. If one ParentRef sets a
                combination of optional fields, all must set the same combination.

              Some examples:

              * If one ParentRef sets `sectionName`, all ParentRefs referencing the
                same object must also set `sectionName`.
              * If one ParentRef sets `port`, all ParentRefs referencing the same
                object must also set `port`.
              * If one ParentRef sets `sectionName` and `port`, all ParentRefs
                referencing the same object must also set `sectionName` and `port`.

              It is possible to separately reference multiple distinct objects that may
              be collapsed by an implementation. For example, some implementations may
              choose to merge compatible Gateway Listeners together. If that is the
              case, the list of routes attached to those resources should also be
              merged.

              Note that for ParentRefs that cross namespace boundaries, there are specific
              rules. Cross-namespace references are only valid if they are explicitly
              allowed by something in the namespace they are referring to. For example,
              Gateway has the AllowedRoutes field, and ReferenceGrant provides a
              generic way to enable other kinds of cross-namespace reference.


              ParentRefs from a Route to a Service in the same namespace are "producer"
              routes, which apply default routing rules to inbound connections from
              any namespace to the Service.

              ParentRefs from a Route to a Service in a different namespace are
              "consumer" routes, and these routing rules are only applied to outbound
              connections originating from the same namespace as the Route, for which
              the intended destination of the connections are a Service targeted as a
              ParentRef of the Route.





            '';
          };
          rules = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  backendRefs = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (mkTypedSubmodule {
                          options = {
                            group = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                When unspecified or empty string, core API group is inferred.
                              '';
                            };
                            kind = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Kind is the Kubernetes resource kind of the referent. For example
                                "Service".

                                Defaults to "Service" when not specified.

                                ExternalName services can refer to CNAME DNS records that may live
                                outside of the cluster and as such are difficult to reason about in
                                terms of conformance. They also may not be safe to forward to (see
                                CVE-2021-25740 for more information). Implementations SHOULD NOT
                                support ExternalName Services.

                                Support: Core (Services with a type other than ExternalName)

                                Support: Implementation-specific (Services with type ExternalName)
                              '';
                            };
                            name = mkOption {
                              type = types.str;
                              description = "Name is the name of the referent.";
                            };
                            namespace = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Namespace is the namespace of the backend. When unspecified, the local
                                namespace is inferred.

                                Note that when a namespace different than the local namespace is specified,
                                a ReferenceGrant object is required in the referent namespace to allow that
                                namespace's owner to accept the reference. See the ReferenceGrant
                                documentation for details.

                                Support: Core
                              '';
                            };
                            port = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                Port specifies the destination port number to use for this resource.
                                Port is required when the referent is a Kubernetes Service. In this
                                case, the port number is the service port number, not the target port.
                                For other resources, destination port might be derived from the referent
                                resource or this field.
                              '';
                            };
                            weight = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                Weight specifies the proportion of requests forwarded to the referenced
                                backend. This is computed as weight/(sum of all weights in this
                                BackendRefs list). For non-zero values, there may be some epsilon from
                                the exact proportion defined here depending on the precision an
                                implementation supports. Weight is not a percentage and the sum of
                                weights does not need to equal 100.

                                If only one backend is specified and it has a weight greater than 0, 100%
                                of the traffic is forwarded to that backend. If weight is set to 0, no
                                traffic should be forwarded for this entry. If unspecified, weight
                                defaults to 1.

                                Support for this field varies based on the context where used.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = ''
                      BackendRefs defines the backend(s) where matching requests should be
                      sent. If unspecified or invalid (refers to a non-existent resource or a
                      Service with no endpoints), the underlying implementation MUST actively
                      reject connection attempts to this backend. Connection rejections must
                      respect weight; if an invalid backend is requested to have 80% of
                      connections, then 80% of connections must be rejected instead.

                      Support: Core for Kubernetes Service

                      Support: Extended for Kubernetes ServiceImport

                      Support: Implementation-specific for any other resource

                      Support for weight: Extended
                    '';
                  };
                  name = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      Name is the name of the route rule. This name MUST be unique within a Route if it is set.

                      Support: Extended
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              Rules are a list of TCP matchers and actions.

            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  TLSRoute = mkResource {
    apiVersion = "gateway.networking.k8s.io/v1alpha2";
    kind = "TLSRoute";
    specType = (
      mkTypedSubmodule {
        options = {
          hostnames = mkOption {
            type = (types.nullOr (types.listOf types.str));
            default = null;
            description = ''
              Hostnames defines a set of SNI names that should match against the
              SNI attribute of TLS ClientHello message in TLS handshake. This matches
              the RFC 1123 definition of a hostname with 2 notable exceptions:

              1. IPs are not allowed in SNI names per RFC 6066.
              2. A hostname may be prefixed with a wildcard label (`*.`). The wildcard
                 label must appear by itself as the first label.

              If a hostname is specified by both the Listener and TLSRoute, there
              must be at least one intersecting hostname for the TLSRoute to be
              attached to the Listener. For example:

              * A Listener with `test.example.com` as the hostname matches TLSRoutes
                that have either not specified any hostnames, or have specified at
                least one of `test.example.com` or `*.example.com`.
              * A Listener with `*.example.com` as the hostname matches TLSRoutes
                that have either not specified any hostnames or have specified at least
                one hostname that matches the Listener hostname. For example,
                `test.example.com` and `*.example.com` would both match. On the other
                hand, `example.com` and `test.example.net` would not match.

              If both the Listener and TLSRoute have specified hostnames, any
              TLSRoute hostnames that do not match the Listener hostname MUST be
              ignored. For example, if a Listener specified `*.example.com`, and the
              TLSRoute specified `test.example.com` and `test.example.net`,
              `test.example.net` must not be considered for a match.

              If both the Listener and TLSRoute have specified hostnames, and none
              match with the criteria above, then the TLSRoute is not accepted. The
              implementation must raise an 'Accepted' Condition with a status of
              `False` in the corresponding RouteParentStatus.

              Support: Core
            '';
          };
          parentRefs = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    group = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Group is the group of the referent.
                        When unspecified, "gateway.networking.k8s.io" is inferred.
                        To set the core API group (such as for a "Service" kind referent),
                        Group must be explicitly set to "" (empty string).

                        Support: Core
                      '';
                    };
                    kind = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Kind is kind of the referent.

                        There are two kinds of parent resources with "Core" support:

                        * Gateway (Gateway conformance profile)
                        * Service (Mesh conformance profile, ClusterIP Services only)

                        Support for other resources is Implementation-Specific.
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = ''
                        Name is the name of the referent.

                        Support: Core
                      '';
                    };
                    namespace = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Namespace is the namespace of the referent. When unspecified, this refers
                        to the local namespace of the Route.

                        Note that there are specific rules for ParentRefs which cross namespace
                        boundaries. Cross-namespace references are only valid if they are explicitly
                        allowed by something in the namespace they are referring to. For example:
                        Gateway has the AllowedRoutes field, and ReferenceGrant provides a
                        generic way to enable any other kind of cross-namespace reference.


                        ParentRefs from a Route to a Service in the same namespace are "producer"
                        routes, which apply default routing rules to inbound connections from
                        any namespace to the Service.

                        ParentRefs from a Route to a Service in a different namespace are
                        "consumer" routes, and these routing rules are only applied to outbound
                        connections originating from the same namespace as the Route, for which
                        the intended destination of the connections are a Service targeted as a
                        ParentRef of the Route.


                        Support: Core
                      '';
                    };
                    port = mkOption {
                      type = (types.nullOr types.int);
                      default = null;
                      description = ''
                        Port is the network port this Route targets. It can be interpreted
                        differently based on the type of parent resource.

                        When the parent resource is a Gateway, this targets all listeners
                        listening on the specified port that also support this kind of Route(and
                        select this Route). It's not recommended to set `Port` unless the
                        networking behaviors specified in a Route must apply to a specific port
                        as opposed to a listener(s) whose port(s) may be changed. When both Port
                        and SectionName are specified, the name and port of the selected listener
                        must match both specified values.


                        When the parent resource is a Service, this targets a specific port in the
                        Service spec. When both Port (experimental) and SectionName are specified,
                        the name and port of the selected port must match both specified values.


                        Implementations MAY choose to support other parent resources.
                        Implementations supporting other types of parent resources MUST clearly
                        document how/if Port is interpreted.

                        For the purpose of status, an attachment is considered successful as
                        long as the parent resource accepts it partially. For example, Gateway
                        listeners can restrict which Routes can attach to them by Route kind,
                        namespace, or hostname. If 1 of 2 Gateway listeners accept attachment
                        from the referencing Route, the Route MUST be considered successfully
                        attached. If no Gateway listeners accept attachment from this Route,
                        the Route MUST be considered detached from the Gateway.

                        Support: Extended
                      '';
                    };
                    sectionName = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        SectionName is the name of a section within the target resource. In the
                        following resources, SectionName is interpreted as the following:

                        * Gateway: Listener name. When both Port (experimental) and SectionName
                        are specified, the name and port of the selected listener must match
                        both specified values.
                        * Service: Port name. When both Port (experimental) and SectionName
                        are specified, the name and port of the selected listener must match
                        both specified values.

                        Implementations MAY choose to support attaching Routes to other resources.
                        If that is the case, they MUST clearly document how SectionName is
                        interpreted.

                        When unspecified (empty string), this will reference the entire resource.
                        For the purpose of status, an attachment is considered successful if at
                        least one section in the parent resource accepts it. For example, Gateway
                        listeners can restrict which Routes can attach to them by Route kind,
                        namespace, or hostname. If 1 of 2 Gateway listeners accept attachment from
                        the referencing Route, the Route MUST be considered successfully
                        attached. If no Gateway listeners accept attachment from this Route, the
                        Route MUST be considered detached from the Gateway.

                        Support: Core
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              ParentRefs references the resources (usually Gateways) that a Route wants
              to be attached to. Note that the referenced parent resource needs to
              allow this for the attachment to be complete. For Gateways, that means
              the Gateway needs to allow attachment from Routes of this kind and
              namespace. For Services, that means the Service must either be in the same
              namespace for a "producer" route, or the mesh implementation must support
              and allow "consumer" routes for the referenced Service. ReferenceGrant is
              not applicable for governing ParentRefs to Services - it is not possible to
              create a "producer" route for a Service in a different namespace from the
              Route.

              There are two kinds of parent resources with "Core" support:

              * Gateway (Gateway conformance profile)
              * Service (Mesh conformance profile, ClusterIP Services only)

              This API may be extended in the future to support additional kinds of parent
              resources.

              ParentRefs must be _distinct_. This means either that:

              * They select different objects.  If this is the case, then parentRef
                entries are distinct. In terms of fields, this means that the
                multi-part key defined by `group`, `kind`, `namespace`, and `name` must
                be unique across all parentRef entries in the Route.
              * They do not select different objects, but for each optional field used,
                each ParentRef that selects the same object must set the same set of
                optional fields to different values. If one ParentRef sets a
                combination of optional fields, all must set the same combination.

              Some examples:

              * If one ParentRef sets `sectionName`, all ParentRefs referencing the
                same object must also set `sectionName`.
              * If one ParentRef sets `port`, all ParentRefs referencing the same
                object must also set `port`.
              * If one ParentRef sets `sectionName` and `port`, all ParentRefs
                referencing the same object must also set `sectionName` and `port`.

              It is possible to separately reference multiple distinct objects that may
              be collapsed by an implementation. For example, some implementations may
              choose to merge compatible Gateway Listeners together. If that is the
              case, the list of routes attached to those resources should also be
              merged.

              Note that for ParentRefs that cross namespace boundaries, there are specific
              rules. Cross-namespace references are only valid if they are explicitly
              allowed by something in the namespace they are referring to. For example,
              Gateway has the AllowedRoutes field, and ReferenceGrant provides a
              generic way to enable other kinds of cross-namespace reference.


              ParentRefs from a Route to a Service in the same namespace are "producer"
              routes, which apply default routing rules to inbound connections from
              any namespace to the Service.

              ParentRefs from a Route to a Service in a different namespace are
              "consumer" routes, and these routing rules are only applied to outbound
              connections originating from the same namespace as the Route, for which
              the intended destination of the connections are a Service targeted as a
              ParentRef of the Route.





            '';
          };
          rules = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  backendRefs = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (mkTypedSubmodule {
                          options = {
                            group = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                When unspecified or empty string, core API group is inferred.
                              '';
                            };
                            kind = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Kind is the Kubernetes resource kind of the referent. For example
                                "Service".

                                Defaults to "Service" when not specified.

                                ExternalName services can refer to CNAME DNS records that may live
                                outside of the cluster and as such are difficult to reason about in
                                terms of conformance. They also may not be safe to forward to (see
                                CVE-2021-25740 for more information). Implementations SHOULD NOT
                                support ExternalName Services.

                                Support: Core (Services with a type other than ExternalName)

                                Support: Implementation-specific (Services with type ExternalName)
                              '';
                            };
                            name = mkOption {
                              type = types.str;
                              description = "Name is the name of the referent.";
                            };
                            namespace = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Namespace is the namespace of the backend. When unspecified, the local
                                namespace is inferred.

                                Note that when a namespace different than the local namespace is specified,
                                a ReferenceGrant object is required in the referent namespace to allow that
                                namespace's owner to accept the reference. See the ReferenceGrant
                                documentation for details.

                                Support: Core
                              '';
                            };
                            port = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                Port specifies the destination port number to use for this resource.
                                Port is required when the referent is a Kubernetes Service. In this
                                case, the port number is the service port number, not the target port.
                                For other resources, destination port might be derived from the referent
                                resource or this field.
                              '';
                            };
                            weight = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                Weight specifies the proportion of requests forwarded to the referenced
                                backend. This is computed as weight/(sum of all weights in this
                                BackendRefs list). For non-zero values, there may be some epsilon from
                                the exact proportion defined here depending on the precision an
                                implementation supports. Weight is not a percentage and the sum of
                                weights does not need to equal 100.

                                If only one backend is specified and it has a weight greater than 0, 100%
                                of the traffic is forwarded to that backend. If weight is set to 0, no
                                traffic should be forwarded for this entry. If unspecified, weight
                                defaults to 1.

                                Support for this field varies based on the context where used.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = ''
                      BackendRefs defines the backend(s) where matching requests should be
                      sent. If unspecified or invalid (refers to a non-existent resource or
                      a Service with no endpoints), the rule performs no forwarding; if no
                      filters are specified that would result in a response being sent, the
                      underlying implementation must actively reject request attempts to this
                      backend, by rejecting the connection or returning a 500 status code.
                      Request rejections must respect weight; if an invalid backend is
                      requested to have 80% of requests, then 80% of requests must be rejected
                      instead.

                      Support: Core for Kubernetes Service

                      Support: Extended for Kubernetes ServiceImport

                      Support: Implementation-specific for any other resource

                      Support for weight: Extended
                    '';
                  };
                  name = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      Name is the name of the route rule. This name MUST be unique within a Route if it is set.

                      Support: Extended
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              Rules are a list of TLS matchers and actions.

            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

  UDPRoute = mkResource {
    apiVersion = "gateway.networking.k8s.io/v1alpha2";
    kind = "UDPRoute";
    specType = (
      mkTypedSubmodule {
        options = {
          parentRefs = mkOption {
            type = (
              types.nullOr (
                types.listOf (mkTypedSubmodule {
                  options = {
                    group = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Group is the group of the referent.
                        When unspecified, "gateway.networking.k8s.io" is inferred.
                        To set the core API group (such as for a "Service" kind referent),
                        Group must be explicitly set to "" (empty string).

                        Support: Core
                      '';
                    };
                    kind = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Kind is kind of the referent.

                        There are two kinds of parent resources with "Core" support:

                        * Gateway (Gateway conformance profile)
                        * Service (Mesh conformance profile, ClusterIP Services only)

                        Support for other resources is Implementation-Specific.
                      '';
                    };
                    name = mkOption {
                      type = types.str;
                      description = ''
                        Name is the name of the referent.

                        Support: Core
                      '';
                    };
                    namespace = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        Namespace is the namespace of the referent. When unspecified, this refers
                        to the local namespace of the Route.

                        Note that there are specific rules for ParentRefs which cross namespace
                        boundaries. Cross-namespace references are only valid if they are explicitly
                        allowed by something in the namespace they are referring to. For example:
                        Gateway has the AllowedRoutes field, and ReferenceGrant provides a
                        generic way to enable any other kind of cross-namespace reference.


                        ParentRefs from a Route to a Service in the same namespace are "producer"
                        routes, which apply default routing rules to inbound connections from
                        any namespace to the Service.

                        ParentRefs from a Route to a Service in a different namespace are
                        "consumer" routes, and these routing rules are only applied to outbound
                        connections originating from the same namespace as the Route, for which
                        the intended destination of the connections are a Service targeted as a
                        ParentRef of the Route.


                        Support: Core
                      '';
                    };
                    port = mkOption {
                      type = (types.nullOr types.int);
                      default = null;
                      description = ''
                        Port is the network port this Route targets. It can be interpreted
                        differently based on the type of parent resource.

                        When the parent resource is a Gateway, this targets all listeners
                        listening on the specified port that also support this kind of Route(and
                        select this Route). It's not recommended to set `Port` unless the
                        networking behaviors specified in a Route must apply to a specific port
                        as opposed to a listener(s) whose port(s) may be changed. When both Port
                        and SectionName are specified, the name and port of the selected listener
                        must match both specified values.


                        When the parent resource is a Service, this targets a specific port in the
                        Service spec. When both Port (experimental) and SectionName are specified,
                        the name and port of the selected port must match both specified values.


                        Implementations MAY choose to support other parent resources.
                        Implementations supporting other types of parent resources MUST clearly
                        document how/if Port is interpreted.

                        For the purpose of status, an attachment is considered successful as
                        long as the parent resource accepts it partially. For example, Gateway
                        listeners can restrict which Routes can attach to them by Route kind,
                        namespace, or hostname. If 1 of 2 Gateway listeners accept attachment
                        from the referencing Route, the Route MUST be considered successfully
                        attached. If no Gateway listeners accept attachment from this Route,
                        the Route MUST be considered detached from the Gateway.

                        Support: Extended
                      '';
                    };
                    sectionName = mkOption {
                      type = (types.nullOr types.str);
                      default = null;
                      description = ''
                        SectionName is the name of a section within the target resource. In the
                        following resources, SectionName is interpreted as the following:

                        * Gateway: Listener name. When both Port (experimental) and SectionName
                        are specified, the name and port of the selected listener must match
                        both specified values.
                        * Service: Port name. When both Port (experimental) and SectionName
                        are specified, the name and port of the selected listener must match
                        both specified values.

                        Implementations MAY choose to support attaching Routes to other resources.
                        If that is the case, they MUST clearly document how SectionName is
                        interpreted.

                        When unspecified (empty string), this will reference the entire resource.
                        For the purpose of status, an attachment is considered successful if at
                        least one section in the parent resource accepts it. For example, Gateway
                        listeners can restrict which Routes can attach to them by Route kind,
                        namespace, or hostname. If 1 of 2 Gateway listeners accept attachment from
                        the referencing Route, the Route MUST be considered successfully
                        attached. If no Gateway listeners accept attachment from this Route, the
                        Route MUST be considered detached from the Gateway.

                        Support: Core
                      '';
                    };
                  };
                  freeformType = types.attrs;
                })
              )
            );
            default = null;
            description = ''
              ParentRefs references the resources (usually Gateways) that a Route wants
              to be attached to. Note that the referenced parent resource needs to
              allow this for the attachment to be complete. For Gateways, that means
              the Gateway needs to allow attachment from Routes of this kind and
              namespace. For Services, that means the Service must either be in the same
              namespace for a "producer" route, or the mesh implementation must support
              and allow "consumer" routes for the referenced Service. ReferenceGrant is
              not applicable for governing ParentRefs to Services - it is not possible to
              create a "producer" route for a Service in a different namespace from the
              Route.

              There are two kinds of parent resources with "Core" support:

              * Gateway (Gateway conformance profile)
              * Service (Mesh conformance profile, ClusterIP Services only)

              This API may be extended in the future to support additional kinds of parent
              resources.

              ParentRefs must be _distinct_. This means either that:

              * They select different objects.  If this is the case, then parentRef
                entries are distinct. In terms of fields, this means that the
                multi-part key defined by `group`, `kind`, `namespace`, and `name` must
                be unique across all parentRef entries in the Route.
              * They do not select different objects, but for each optional field used,
                each ParentRef that selects the same object must set the same set of
                optional fields to different values. If one ParentRef sets a
                combination of optional fields, all must set the same combination.

              Some examples:

              * If one ParentRef sets `sectionName`, all ParentRefs referencing the
                same object must also set `sectionName`.
              * If one ParentRef sets `port`, all ParentRefs referencing the same
                object must also set `port`.
              * If one ParentRef sets `sectionName` and `port`, all ParentRefs
                referencing the same object must also set `sectionName` and `port`.

              It is possible to separately reference multiple distinct objects that may
              be collapsed by an implementation. For example, some implementations may
              choose to merge compatible Gateway Listeners together. If that is the
              case, the list of routes attached to those resources should also be
              merged.

              Note that for ParentRefs that cross namespace boundaries, there are specific
              rules. Cross-namespace references are only valid if they are explicitly
              allowed by something in the namespace they are referring to. For example,
              Gateway has the AllowedRoutes field, and ReferenceGrant provides a
              generic way to enable other kinds of cross-namespace reference.


              ParentRefs from a Route to a Service in the same namespace are "producer"
              routes, which apply default routing rules to inbound connections from
              any namespace to the Service.

              ParentRefs from a Route to a Service in a different namespace are
              "consumer" routes, and these routing rules are only applied to outbound
              connections originating from the same namespace as the Route, for which
              the intended destination of the connections are a Service targeted as a
              ParentRef of the Route.





            '';
          };
          rules = mkOption {
            type = (
              types.listOf (mkTypedSubmodule {
                options = {
                  backendRefs = mkOption {
                    type = (
                      types.nullOr (
                        types.listOf (mkTypedSubmodule {
                          options = {
                            group = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Group is the group of the referent. For example, "gateway.networking.k8s.io".
                                When unspecified or empty string, core API group is inferred.
                              '';
                            };
                            kind = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Kind is the Kubernetes resource kind of the referent. For example
                                "Service".

                                Defaults to "Service" when not specified.

                                ExternalName services can refer to CNAME DNS records that may live
                                outside of the cluster and as such are difficult to reason about in
                                terms of conformance. They also may not be safe to forward to (see
                                CVE-2021-25740 for more information). Implementations SHOULD NOT
                                support ExternalName Services.

                                Support: Core (Services with a type other than ExternalName)

                                Support: Implementation-specific (Services with type ExternalName)
                              '';
                            };
                            name = mkOption {
                              type = types.str;
                              description = "Name is the name of the referent.";
                            };
                            namespace = mkOption {
                              type = (types.nullOr types.str);
                              default = null;
                              description = ''
                                Namespace is the namespace of the backend. When unspecified, the local
                                namespace is inferred.

                                Note that when a namespace different than the local namespace is specified,
                                a ReferenceGrant object is required in the referent namespace to allow that
                                namespace's owner to accept the reference. See the ReferenceGrant
                                documentation for details.

                                Support: Core
                              '';
                            };
                            port = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                Port specifies the destination port number to use for this resource.
                                Port is required when the referent is a Kubernetes Service. In this
                                case, the port number is the service port number, not the target port.
                                For other resources, destination port might be derived from the referent
                                resource or this field.
                              '';
                            };
                            weight = mkOption {
                              type = (types.nullOr types.int);
                              default = null;
                              description = ''
                                Weight specifies the proportion of requests forwarded to the referenced
                                backend. This is computed as weight/(sum of all weights in this
                                BackendRefs list). For non-zero values, there may be some epsilon from
                                the exact proportion defined here depending on the precision an
                                implementation supports. Weight is not a percentage and the sum of
                                weights does not need to equal 100.

                                If only one backend is specified and it has a weight greater than 0, 100%
                                of the traffic is forwarded to that backend. If weight is set to 0, no
                                traffic should be forwarded for this entry. If unspecified, weight
                                defaults to 1.

                                Support for this field varies based on the context where used.
                              '';
                            };
                          };
                          freeformType = types.attrs;
                        })
                      )
                    );
                    default = null;
                    description = ''
                      BackendRefs defines the backend(s) where matching requests should be
                      sent. If unspecified or invalid (refers to a non-existent resource or a
                      Service with no endpoints), the underlying implementation MUST actively
                      reject connection attempts to this backend. Packet drops must
                      respect weight; if an invalid backend is requested to have 80% of
                      the packets, then 80% of packets must be dropped instead.

                      Support: Core for Kubernetes Service

                      Support: Extended for Kubernetes ServiceImport

                      Support: Implementation-specific for any other resource

                      Support for weight: Extended
                    '';
                  };
                  name = mkOption {
                    type = (types.nullOr types.str);
                    default = null;
                    description = ''
                      Name is the name of the route rule. This name MUST be unique within a Route if it is set.

                      Support: Extended
                    '';
                  };
                };
                freeformType = types.attrs;
              })
            );
            description = ''
              Rules are a list of UDP matchers and actions.

            '';
          };
        };
        freeformType = types.attrs;
      }
    );
  };

}
