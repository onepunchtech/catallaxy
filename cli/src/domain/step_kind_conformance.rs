#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use serde::Deserialize;
    use serde_json::{Map, Value};

    use crate::domain::plan::{Direction, Idempotency, StepParams};
    use crate::domain::step_kind::StepKind;

    #[derive(Debug, Deserialize)]
    struct KindSchema {
        directions: Vec<String>,
        #[serde(rename = "dryRunSafe")]
        dry_run_safe: bool,
        idempotency: String,
        params: BTreeMap<String, Param>,
    }

    #[derive(Debug, Deserialize)]
    struct Param {
        required: bool,
        sample: Value,
    }

    fn registry() -> BTreeMap<String, KindSchema> {
        serde_json::from_str(include_str!("../../tests/fixtures/step-kinds.json"))
            .expect("cli/tests/fixtures/step-kinds.json is not valid step-kind schema JSON")
    }

    fn step_json(kind: &str, schema: &KindSchema, skip: Option<&str>) -> Value {
        let mut obj = Map::new();
        obj.insert("kind".into(), Value::String(kind.into()));
        for (field, param) in &schema.params {
            if Some(field.as_str()) == skip {
                continue;
            }
            if param.required || skip.is_some() {
                obj.insert(field.clone(), param.sample.clone());
            }
        }
        Value::Object(obj)
    }

    #[test]
    fn every_nix_kind_deserializes_into_its_variant() {
        for (kind, schema) in registry() {
            let params: StepParams = serde_json::from_value(step_json(&kind, &schema, None))
                .unwrap_or_else(|e| panic!("kind '{kind}' does not parse as StepParams: {e}"));
            assert_eq!(
                params.kind().tag(),
                kind,
                "kind '{kind}' parsed as another variant"
            );
        }
    }

    #[test]
    fn every_nix_optional_param_is_accepted_by_its_variant() {
        for (kind, schema) in registry() {
            let mut obj = Map::new();
            obj.insert("kind".into(), Value::String(kind.clone()));
            for (field, param) in &schema.params {
                obj.insert(field.clone(), param.sample.clone());
            }
            serde_json::from_value::<StepParams>(Value::Object(obj)).unwrap_or_else(|e| {
                panic!("kind '{kind}' rejects a param the Nix registry declares: {e}")
            });
        }
    }

    #[test]
    fn every_nix_required_param_is_required_by_its_variant() {
        for (kind, schema) in registry() {
            for (field, param) in &schema.params {
                if !param.required {
                    continue;
                }
                let json = step_json(&kind, &schema, Some(field));
                assert!(
                    serde_json::from_value::<StepParams>(json).is_err(),
                    "kind '{kind}' parses without '{field}', which the Nix registry declares required"
                );
            }
        }
    }

    #[test]
    fn the_two_kind_lists_agree() {
        let nix: Vec<String> = registry().keys().cloned().collect();
        let mut rust: Vec<String> = StepKind::ALL.iter().map(|k| k.tag().to_string()).collect();
        rust.sort();
        assert_eq!(nix, rust);
    }

    #[test]
    fn idempotency_agrees_with_the_registry() {
        for (kind, schema) in registry() {
            let expected = match schema.idempotency.as_str() {
                "idempotent" => Idempotency::Idempotent,
                "oneShot" => Idempotency::OneShot,
                "destructive" => Idempotency::Destructive,
                other => panic!("kind '{kind}' declares unknown idempotency '{other}'"),
            };
            let actual = StepKind::from_tag(&kind)
                .expect("kind list already checked")
                .retry();
            assert_eq!(actual, expected, "idempotency drift on kind '{kind}'");
        }
    }

    #[test]
    fn directions_and_dry_run_safety_agree_with_the_registry() {
        for (kind, schema) in registry() {
            let step_kind = StepKind::from_tag(&kind).expect("kind list already checked");
            assert_eq!(
                step_kind.runs_in(Direction::Deploy),
                schema.directions.iter().any(|d| d == "deploy"),
                "deploy-direction drift on kind '{kind}'"
            );
            assert_eq!(
                step_kind.runs_in(Direction::Teardown),
                schema.directions.iter().any(|d| d == "teardown"),
                "teardown-direction drift on kind '{kind}'"
            );
            assert_eq!(
                step_kind.dry_run_safe(),
                schema.dry_run_safe,
                "dry-run-safety drift on kind '{kind}'"
            );
        }
    }
}
