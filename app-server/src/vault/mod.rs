mod crypto;
mod local;
pub mod secrets;

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

trait Store {
    fn store_id(&self) -> &str;
    fn put(&self, namespace: &str, file_id: &str, content: &[u8]) -> Result<(), String>;
    fn get(&self, namespace: &str, file_id: &str) -> Result<Vec<u8>, String>;
}

const STORE_ID_LEN: usize = 1;

fn store_for_id(store_id: &str) -> Result<Box<dyn Store>, String> {
    match store_id {
        "0" => Ok(Box::new(local::LocalStore::new())),
        other => Err(format!("unknown store ID: '{other}'")),
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VaultConfig {
    pub backend: Option<String>,
}

impl VaultConfig {
    pub fn load() -> Result<Self, String> {
        let Some(path) = Self::config_path() else {
            return Ok(Self::default());
        };
        let Ok(contents) = fs::read_to_string(&path) else {
            return Ok(Self::default());
        };
        toml::from_str(&contents).map_err(|e| format!("invalid vault config: {e}"))
    }

    fn config_path() -> Option<PathBuf> {
        let xdg = xdg::BaseDirectories::with_prefix(crate::paths::APP_PREFIX);
        Some(xdg.get_config_home()?.join("vault.toml"))
    }

    fn build_backend(&self) -> Result<Box<dyn Store>, String> {
        let backend_name = self.backend.as_deref().unwrap_or("local");

        match backend_name {
            "local" => Ok(Box::new(local::LocalStore::new())),
            other => Err(format!("unknown vault backend: '{other}'")),
        }
    }
}

pub struct Vault {
    backend: Box<dyn Store>,
}

impl Vault {
    pub fn from_config() -> Result<Self, String> {
        let config = VaultConfig::load()?;
        let backend = config.build_backend()?;
        Ok(Self { backend })
    }

    /// Encrypt and store content. Returns a blob ID with embedded store ID.
    pub fn put(&self, namespace: &str, content: &[u8]) -> Result<String, String> {
        let raw_id = crypto::generate_id();
        let encrypted = crypto::encrypt(&raw_id, content)?;
        let fid = crypto::file_id(&raw_id);
        self.backend.put(namespace, &fid, &encrypted)?;
        Ok(format!("{}{raw_id}", self.backend.store_id()))
    }

    /// Fetch and decrypt content by blob ID (store ID + crypto ID).
    pub fn get(namespace: &str, blob_id: &str) -> Result<Vec<u8>, String> {
        if blob_id.len() <= STORE_ID_LEN {
            return Err(format!("invalid blob ID: {blob_id}"));
        }
        let store_id = &blob_id[..STORE_ID_LEN];
        let raw_id = &blob_id[STORE_ID_LEN..];
        let backend = store_for_id(store_id)?;
        let fid = crypto::file_id(raw_id);
        let encrypted = backend.get(namespace, &fid)?;
        crypto::decrypt(raw_id, &encrypted)
    }
}
