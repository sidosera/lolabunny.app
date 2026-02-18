use serde::Serialize;

/// Information about a registered command binding
#[derive(Clone, Serialize)]
pub struct BunnylolCommandInfo {
    pub bindings: Vec<String>,
    pub description: String,
    pub example: String,
}

impl BunnylolCommandInfo {
    pub fn new(bindings: &[&str], description: &str, example: &str) -> Self {
        BunnylolCommandInfo {
            bindings: bindings.iter().map(|s| s.to_string()).collect(),
            description: description.to_string(),
            example: example.to_string(),
        }
    }
}
