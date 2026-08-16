use serde_json::Value;

const EXTERNAL_NAME: &str = "/metadata/annotations/crossplane.io~1external-name";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagedState {
    pub external_name: Option<String>,
    pub has_finalizer: bool,
}

impl ManagedState {
    pub fn of(cr: &Value) -> Self {
        ManagedState {
            external_name: cr
                .pointer(EXTERNAL_NAME)
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(String::from),
            has_finalizer: cr
                .pointer("/metadata/finalizers")
                .and_then(|v| v.as_array())
                .is_some_and(|arr| {
                    arr.iter()
                        .filter_map(|f| f.as_str())
                        .any(|s| s.contains("crossplane.io"))
                }),
        }
    }

    pub fn is_deletable(&self) -> bool {
        self.external_name.is_some() && self.has_finalizer
    }

    pub fn external_name_or_missing(&self) -> &str {
        self.external_name.as_deref().unwrap_or("<missing>")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn cr(annotations: Value, finalizers: Value) -> Value {
        json!({ "metadata": { "annotations": annotations, "finalizers": finalizers } })
    }

    #[test]
    fn a_named_resource_with_a_crossplane_finalizer_is_deletable() {
        let state = ManagedState::of(&cr(
            json!({ "crossplane.io/external-name": "abc-123" }),
            json!(["finalizer.managedresource.crossplane.io"]),
        ));

        assert_eq!(state.external_name.as_deref(), Some("abc-123"));
        assert!(state.has_finalizer);
        assert!(state.is_deletable());
    }

    #[test]
    fn an_empty_external_name_counts_as_absent() {
        let state = ManagedState::of(&cr(
            json!({ "crossplane.io/external-name": "" }),
            json!(["finalizer.managedresource.crossplane.io"]),
        ));

        assert_eq!(state.external_name, None);
        assert!(!state.is_deletable());
        assert_eq!(state.external_name_or_missing(), "<missing>");
    }

    #[test]
    fn a_finalizer_from_something_else_does_not_count() {
        let state = ManagedState::of(&cr(
            json!({ "crossplane.io/external-name": "abc" }),
            json!(["kubernetes.io/pv-protection"]),
        ));

        assert!(!state.has_finalizer);
        assert!(!state.is_deletable());
    }

    #[test]
    fn a_resource_with_no_metadata_at_all_is_not_deletable() {
        let state = ManagedState::of(&json!({}));

        assert_eq!(state.external_name, None);
        assert!(!state.has_finalizer);
        assert!(!state.is_deletable());
    }

    #[test]
    fn a_non_string_finalizer_is_skipped_rather_than_fatal() {
        let state = ManagedState::of(&cr(
            json!({}),
            json!([42, { "nested": true }, "x.crossplane.io"]),
        ));

        assert!(state.has_finalizer);
    }
}
