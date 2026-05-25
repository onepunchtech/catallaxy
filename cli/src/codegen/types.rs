//! Internal type representation for Nix code generation
//!
//! This module defines the intermediate representation (IR) that bridges
//! OpenAPI/JSON Schema types to Nix module types.

use std::collections::BTreeMap;

/// Represents a Nix type in our IR
#[derive(Debug, Clone)]
pub enum NixType {
    /// Nix `types.str`
    Str,
    /// Nix `types.int`
    Int,
    /// Nix `types.float`
    Float,
    /// Nix `types.bool`
    Bool,
    /// Nix `types.nullOr <inner>`
    NullOr(Box<NixType>),
    /// Nix `types.listOf <inner>`
    ListOf(Box<NixType>),
    /// Nix `types.attrsOf <inner>`
    AttrsOf(Box<NixType>),
    /// Nix `types.enum [ ... ]`
    Enum(Vec<String>),
    /// Nix `types.either <a> <b>`
    Either(Box<NixType>, Box<NixType>),
    /// Nix `types.oneOf [ ... ]`
    OneOf(Vec<NixType>),
    /// Nix `types.submodule { ... }`
    Submodule(Submodule),
    /// Reference to a definition (resolved via `$ref`)
    Ref(String),
    /// Nix `types.anything` - escape hatch for untyped values
    Anything,
    /// Nix `types.attrs` - untyped attribute set
    Attrs,
    /// Nix `types.raw` - completely unvalidated
    Raw,
    /// Nix `types.package`
    Package,
    /// Nix `types.path`
    Path,
}

impl NixType {
    /// Wrap this type in `types.nullOr` if not already nullable
    pub fn nullable(self) -> Self {
        match self {
            NixType::NullOr(_) => self,
            other => NixType::NullOr(Box::new(other)),
        }
    }

    /// Create a list type
    pub fn list(inner: NixType) -> Self {
        NixType::ListOf(Box::new(inner))
    }

    /// Create an attrs type
    pub fn attrs_of(inner: NixType) -> Self {
        NixType::AttrsOf(Box::new(inner))
    }
}

/// A Nix submodule definition
#[derive(Debug, Clone)]
pub struct Submodule {
    /// Named options in this submodule
    pub options: BTreeMap<String, NixOption>,
    /// Whether this submodule allows freeform attributes
    pub freeform_type: Option<Box<NixType>>,
    /// Description of the submodule
    pub description: Option<String>,
}

impl Submodule {
    pub fn new() -> Self {
        Self {
            options: BTreeMap::new(),
            freeform_type: None,
            description: None,
        }
    }

    pub fn with_freeform(mut self, ty: NixType) -> Self {
        self.freeform_type = Some(Box::new(ty));
        self
    }

    pub fn with_option(mut self, name: impl Into<String>, opt: NixOption) -> Self {
        self.options.insert(name.into(), opt);
        self
    }
}

impl Default for Submodule {
    fn default() -> Self {
        Self::new()
    }
}

/// A single option in a Nix module
#[derive(Debug, Clone)]
pub struct NixOption {
    /// The Nix type of this option
    pub ty: NixType,
    /// Default value (as Nix expression string)
    pub default: Option<String>,
    /// Description text
    pub description: Option<String>,
    /// Example value (as Nix expression string)
    pub example: Option<String>,
    /// Whether this option is visible in documentation
    pub visible: bool,
    /// Whether this option is internal
    pub internal: bool,
    /// Whether this option is read-only
    pub read_only: bool,
}

impl NixOption {
    pub fn new(ty: NixType) -> Self {
        Self {
            ty,
            default: None,
            description: None,
            example: None,
            visible: true,
            internal: false,
            read_only: false,
        }
    }

    pub fn with_default(mut self, default: impl Into<String>) -> Self {
        self.default = Some(default.into());
        self
    }

    pub fn with_description(mut self, desc: impl Into<String>) -> Self {
        self.description = Some(desc.into());
        self
    }

    pub fn with_example(mut self, example: impl Into<String>) -> Self {
        self.example = Some(example.into());
        self
    }

    pub fn internal(mut self) -> Self {
        self.internal = true;
        self.visible = false;
        self
    }
}

/// Represents a Kubernetes resource type definition
#[derive(Debug, Clone)]
pub struct K8sResourceType {
    /// API group (e.g., "apps", "core", "networking.k8s.io")
    pub group: String,
    /// API version (e.g., "v1", "v1beta1")
    pub version: String,
    /// Kind name (e.g., "Deployment", "Service")
    pub kind: String,
    /// Full apiVersion string (e.g., "apps/v1", "v1")
    pub api_version: String,
    /// The spec type definition
    pub spec: Option<NixType>,
    /// The status type definition (usually not needed for user config)
    pub status: Option<NixType>,
    /// Description of this resource
    pub description: Option<String>,
    /// Whether this is a namespaced resource
    pub namespaced: bool,
}

impl K8sResourceType {
    pub fn new(group: String, version: String, kind: String) -> Self {
        let api_version = if group.is_empty() || group == "core" {
            version.clone()
        } else {
            format!("{}/{}", group, version)
        };

        Self {
            group,
            version,
            kind,
            api_version,
            spec: None,
            status: None,
            description: None,
            namespaced: true,
        }
    }

    /// Get the Nix path for this resource (e.g., "apps.v1.Deployment")
    pub fn nix_path(&self) -> String {
        let group = if self.group.is_empty() || self.group == "core" {
            "core".to_string()
        } else {
            // Convert "networking.k8s.io" to "networking_k8s_io"
            self.group.replace('.', "_").replace('-', "_")
        };
        format!("{}.{}.{}", group, self.version, self.kind)
    }
}

/// A collection of Kubernetes types for a specific version
#[derive(Debug, Clone)]
pub struct K8sTypeSet {
    /// Kubernetes version (e.g., "v1.31.0")
    pub version: String,
    /// Resource types indexed by their full path (group/version/kind)
    pub resources: BTreeMap<String, K8sResourceType>,
    /// Shared definitions for $ref resolution
    pub definitions: BTreeMap<String, NixType>,
}

impl K8sTypeSet {
    pub fn new(version: impl Into<String>) -> Self {
        Self {
            version: version.into(),
            resources: BTreeMap::new(),
            definitions: BTreeMap::new(),
        }
    }

    pub fn add_resource(&mut self, resource: K8sResourceType) {
        let key = format!("{}/{}/{}", resource.group, resource.version, resource.kind);
        self.resources.insert(key, resource);
    }

    pub fn add_definition(&mut self, name: impl Into<String>, ty: NixType) {
        self.definitions.insert(name.into(), ty);
    }
}

/// Generator options
#[derive(Debug, Clone)]
pub struct GeneratorOptions {
    /// Whether to use freeformType on all submodules
    pub freeform_type: bool,
    /// Whether to include descriptions from the spec
    pub include_descriptions: bool,
    /// API groups to exclude from generation
    pub exclude_groups: Vec<String>,
}

impl Default for GeneratorOptions {
    fn default() -> Self {
        Self {
            freeform_type: true,
            include_descriptions: true,
            exclude_groups: vec!["internal.apiserver.k8s.io".to_string()],
        }
    }
}
