//! OpenAPI/JSON Schema parsing and conversion to NixType
//!
//! This module handles parsing Kubernetes OpenAPI specs and converting
//! JSON Schema definitions to our internal NixType representation.

use std::collections::BTreeMap;

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::Value;

use super::types::{GeneratorOptions, K8sResourceType, K8sTypeSet, NixOption, NixType, Submodule};

/// OpenAPI spec structure (minimal subset we need)
#[derive(Debug, Deserialize)]
pub struct OpenApiSpec {
    pub definitions: BTreeMap<String, Value>,
    #[serde(default)]
    pub paths: BTreeMap<String, Value>,
    #[serde(default)]
    pub info: OpenApiInfo,
}

#[derive(Debug, Deserialize, Default)]
pub struct OpenApiInfo {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub version: String,
}

/// Parse an OpenAPI spec from JSON string
pub fn parse_openapi_spec(json: &str) -> Result<OpenApiSpec> {
    serde_json::from_str(json).context("Failed to parse OpenAPI spec")
}

/// Convert an OpenAPI spec to a K8sTypeSet
pub fn convert_openapi_to_types(
    spec: &OpenApiSpec,
    version: &str,
    options: &GeneratorOptions,
) -> K8sTypeSet {
    let mut type_set = K8sTypeSet::new(version);
    let mut converter = SchemaConverter::new(options, &spec.definitions);

    // Process all definitions
    for (name, schema) in &spec.definitions {
        // Skip internal API groups
        if should_skip_definition(name, options) {
            continue;
        }

        // Check if this is a resource type (has x-kubernetes-group-version-kind)
        if let Some(gvk) = extract_gvk(schema) {
            let resource = converter.convert_resource(name, schema, &gvk);
            type_set.add_resource(resource);
        }

        // Also add as a definition for $ref resolution
        let nix_type = converter.convert_schema(schema);
        type_set.add_definition(name.clone(), nix_type);
    }

    type_set
}

/// Check if a definition should be skipped based on options
fn should_skip_definition(name: &str, options: &GeneratorOptions) -> bool {
    for excluded in &options.exclude_groups {
        if name.contains(excluded) {
            return true;
        }
    }
    false
}

/// Extract group-version-kind from x-kubernetes-group-version-kind extension
fn extract_gvk(schema: &Value) -> Option<GroupVersionKind> {
    let gvk_array = schema.get("x-kubernetes-group-version-kind")?;
    let gvk = gvk_array.as_array()?.first()?;

    Some(GroupVersionKind {
        group: gvk.get("group")?.as_str()?.to_string(),
        version: gvk.get("version")?.as_str()?.to_string(),
        kind: gvk.get("kind")?.as_str()?.to_string(),
    })
}

#[derive(Debug)]
struct GroupVersionKind {
    group: String,
    version: String,
    kind: String,
}

/// Schema converter that tracks state during conversion
struct SchemaConverter<'a> {
    options: &'a GeneratorOptions,
    definitions: &'a BTreeMap<String, Value>,
    /// Track visited refs to avoid infinite recursion
    visited_refs: Vec<String>,
}

impl<'a> SchemaConverter<'a> {
    fn new(options: &'a GeneratorOptions, definitions: &'a BTreeMap<String, Value>) -> Self {
        Self {
            options,
            definitions,
            visited_refs: Vec::new(),
        }
    }

    /// Convert a resource definition to K8sResourceType
    fn convert_resource(
        &mut self,
        _name: &str,
        schema: &Value,
        gvk: &GroupVersionKind,
    ) -> K8sResourceType {
        let mut resource =
            K8sResourceType::new(gvk.group.clone(), gvk.version.clone(), gvk.kind.clone());

        // Extract description
        if self.options.include_descriptions {
            resource.description = schema
                .get("description")
                .and_then(|v| v.as_str())
                .map(String::from);
        }

        // Extract spec type if present
        if let Some(properties) = schema.get("properties") {
            if let Some(spec_schema) = properties.get("spec") {
                resource.spec = Some(self.convert_schema(spec_schema));
            }
        }

        // Check if namespaced (heuristic: most resources are namespaced)
        // In a full implementation, we'd check the API endpoints
        resource.namespaced = true;

        resource
    }

    /// Convert a JSON Schema to NixType
    fn convert_schema(&mut self, schema: &Value) -> NixType {
        // Handle $ref
        if let Some(ref_path) = schema.get("$ref").and_then(|v| v.as_str()) {
            return self.convert_ref(ref_path);
        }

        // Handle allOf (intersection type - take first for simplicity)
        if let Some(all_of) = schema.get("allOf").and_then(|v| v.as_array()) {
            if let Some(first) = all_of.first() {
                return self.convert_schema(first);
            }
        }

        // Handle oneOf/anyOf (union type)
        if let Some(one_of) = schema
            .get("oneOf")
            .or_else(|| schema.get("anyOf"))
            .and_then(|v| v.as_array())
        {
            let types: Vec<NixType> = one_of.iter().map(|s| self.convert_schema(s)).collect();
            if types.len() == 2 {
                return NixType::Either(Box::new(types[0].clone()), Box::new(types[1].clone()));
            } else if !types.is_empty() {
                return NixType::OneOf(types);
            }
        }

        // Get the type field
        let type_str = schema.get("type").and_then(|v| v.as_str());

        match type_str {
            Some("string") => self.convert_string_schema(schema),
            Some("integer") => NixType::Int,
            Some("number") => NixType::Float,
            Some("boolean") => NixType::Bool,
            Some("array") => self.convert_array_schema(schema),
            Some("object") => self.convert_object_schema(schema),
            Some("null") => NixType::NullOr(Box::new(NixType::Anything)),
            None => {
                // No type specified - could be a ref or freeform
                if schema.get("properties").is_some() {
                    self.convert_object_schema(schema)
                } else {
                    NixType::Anything
                }
            }
            _ => NixType::Anything,
        }
    }

    fn convert_string_schema(&mut self, schema: &Value) -> NixType {
        // Check for enum
        if let Some(enum_values) = schema.get("enum").and_then(|v| v.as_array()) {
            let values: Vec<String> = enum_values
                .iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect();
            if !values.is_empty() {
                return NixType::Enum(values);
            }
        }

        // Check for format
        if let Some(format) = schema.get("format").and_then(|v| v.as_str()) {
            match format {
                "int-or-string" => {
                    return NixType::Either(Box::new(NixType::Int), Box::new(NixType::Str));
                }
                "date-time" | "date" | "time" | "byte" | "binary" => {
                    // These are all strings
                    return NixType::Str;
                }
                _ => {}
            }
        }

        NixType::Str
    }

    fn convert_array_schema(&mut self, schema: &Value) -> NixType {
        let items = schema.get("items");
        let inner = match items {
            Some(items_schema) => self.convert_schema(items_schema),
            None => NixType::Anything,
        };
        NixType::ListOf(Box::new(inner))
    }

    fn convert_object_schema(&mut self, schema: &Value) -> NixType {
        // Check for additionalProperties (map type)
        if let Some(additional) = schema.get("additionalProperties") {
            if additional.is_boolean() {
                if additional.as_bool() == Some(true) {
                    return NixType::Attrs;
                }
            } else {
                let value_type = self.convert_schema(additional);
                return NixType::AttrsOf(Box::new(value_type));
            }
        }

        // Check for properties (structured object)
        if let Some(properties) = schema.get("properties").and_then(|v| v.as_object()) {
            let required: Vec<&str> = schema
                .get("required")
                .and_then(|v| v.as_array())
                .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
                .unwrap_or_default();

            let mut submodule = Submodule::new();

            for (name, prop_schema) in properties {
                let prop_type = self.convert_schema(prop_schema);
                let is_required = required.contains(&name.as_str());

                let mut option = NixOption::new(if is_required {
                    prop_type
                } else {
                    prop_type.nullable()
                });

                if !is_required {
                    option.default = Some("null".to_string());
                }

                if self.options.include_descriptions {
                    if let Some(desc) = prop_schema.get("description").and_then(|v| v.as_str()) {
                        option.description = Some(desc.to_string());
                    }
                }

                submodule.options.insert(name.clone(), option);
            }

            // Add freeformType if enabled
            if self.options.freeform_type {
                submodule.freeform_type = Some(Box::new(NixType::Attrs));
            }

            return NixType::Submodule(submodule);
        }

        // No properties, just a generic object
        NixType::Attrs
    }

    fn convert_ref(&mut self, ref_path: &str) -> NixType {
        // Extract definition name from "#/definitions/io.k8s.api.core.v1.Container"
        let def_name = ref_path.strip_prefix("#/definitions/").unwrap_or(ref_path);

        // Cycle detection: if we're already resolving this ref, return untyped attrs
        if self.visited_refs.contains(&def_name.to_string()) {
            return NixType::Attrs;
        }

        // Look up the definition and inline it
        if let Some(schema) = self.definitions.get(def_name) {
            let schema = schema.clone();
            self.visited_refs.push(def_name.to_string());
            let result = self.convert_schema(&schema);
            self.visited_refs.pop();
            result
        } else {
            // Unknown ref — fall back to untyped attrs
            NixType::Attrs
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_string() {
        let schema: Value = serde_json::json!({
            "type": "string"
        });

        let options = GeneratorOptions::default();
        let definitions = BTreeMap::new();
        let mut converter = SchemaConverter::new(&options, &definitions);
        let nix_type = converter.convert_schema(&schema);

        matches!(nix_type, NixType::Str);
    }

    #[test]
    fn test_parse_enum() {
        let schema: Value = serde_json::json!({
            "type": "string",
            "enum": ["Always", "Never", "IfNotPresent"]
        });

        let options = GeneratorOptions::default();
        let definitions = BTreeMap::new();
        let mut converter = SchemaConverter::new(&options, &definitions);
        let nix_type = converter.convert_schema(&schema);

        match nix_type {
            NixType::Enum(values) => {
                assert_eq!(values, vec!["Always", "Never", "IfNotPresent"]);
            }
            _ => panic!("Expected Enum type"),
        }
    }
}
