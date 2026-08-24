use std::collections::HashMap;
#[cfg(test)]
use std::io::Read;

pub fn caught_in_product_code() {
    let _ = std::fs::read_to_string("/etc/passwd");
}

pub fn a_brace_inside_a_raw_string() -> &'static str {
    r#"{ "not": "a scope }" }"#
}

pub fn a_brace_inside_a_comment() {
    // }
    let _ = std::process::Command::new("true");
}

#[cfg(test)]
mod first_tests {
    use super::*;

    #[test]
    fn tests_may_touch_the_real_filesystem() {
        let _ = std::fs::read_to_string("/tmp/x");
        let _ = tempfile::tempdir();
    }
}

pub fn product_code_after_a_test_module() {
    let _ = std::env::var("HOME");
}

#[cfg(test)]
mod second_tests {
    #[test]
    fn also_exempt() {
        let _ = std::process::Command::new("true");
    }
}
