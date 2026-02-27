use std::fs;
use std::path::PathBuf;

pub struct LocalStore {
    base_dir: PathBuf,
}

impl LocalStore {
    pub fn new() -> Self {
        let xdg = xdg::BaseDirectories::with_prefix(crate::paths::APP_PREFIX);
        let base_dir = xdg
            .get_data_home()
            .map(|d| d.join("vault"))
            .unwrap_or_else(|| PathBuf::from(".bunnylol-vault"));
        Self { base_dir }
    }
}

impl super::Store for LocalStore {
    fn store_id(&self) -> &str {
        "0"
    }

    fn put(&self, namespace: &str, file_id: &str, content: &[u8]) -> Result<(), String> {
        let dir = self.base_dir.join(namespace);
        fs::create_dir_all(&dir).map_err(|e| format!("failed to create vault dir: {e}"))?;
        let path = dir.join(file_id);
        fs::write(&path, content).map_err(|e| format!("failed to write vault file: {e}"))
    }

    fn get(&self, namespace: &str, file_id: &str) -> Result<Vec<u8>, String> {
        let path = self.base_dir.join(namespace).join(file_id);
        fs::read(&path).map_err(|_| format!("paste not found: {file_id}"))
    }
}
