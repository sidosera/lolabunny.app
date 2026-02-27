const SERVICE: &str = "bunnylol-vault";

pub fn get(key: &str) -> Result<String, String> {
    let entry =
        keyring::Entry::new(SERVICE, key).map_err(|e| format!("keychain error: {e}"))?;
    entry
        .get_password()
        .map_err(|e| format!("keychain lookup failed for '{key}': {e}"))
}

pub fn set(key: &str, value: &str) -> Result<(), String> {
    let entry =
        keyring::Entry::new(SERVICE, key).map_err(|e| format!("keychain error: {e}"))?;
    entry
        .set_password(value)
        .map_err(|e| format!("keychain save failed for '{key}': {e}"))
}

pub fn delete(key: &str) -> Result<(), String> {
    let entry =
        keyring::Entry::new(SERVICE, key).map_err(|e| format!("keychain error: {e}"))?;
    entry
        .delete_credential()
        .map_err(|e| format!("keychain delete failed for '{key}': {e}"))
}
