use aes_gcm::aead::rand_core::{OsRng, RngCore};
use aes_gcm::aead::{Aead, AeadCore, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use sha2::{Digest, Sha256};

const ALPHABET: &[u8] = b"0123456789ABCDEF";
const RANDOM_LEN: usize = 7;

pub fn generate_id() -> String {
    let mut bytes = [0u8; RANDOM_LEN];
    OsRng.fill_bytes(&mut bytes);
    bytes
        .iter()
        .map(|b| ALPHABET[(*b as usize) % ALPHABET.len()] as char)
        .collect()
}

/// Derive the file path component from an ID (one-way).
pub fn file_id(id: &str) -> String {
    let hash = Sha256::digest(id.as_bytes());
    hash[..8].iter().map(|b| format!("{b:02x}")).collect()
}

/// Derive a 32-byte AES-256 key from the short ID.
fn derive_key(id: &str) -> [u8; 32] {
    let input = format!("bunnylol:{id}");
    Sha256::digest(input.as_bytes()).into()
}

pub fn encrypt(id: &str, plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let key_bytes = derive_key(id);
    let key = Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    let nonce = Aes256Gcm::generate_nonce(OsRng);
    let ciphertext = cipher
        .encrypt(&nonce, plaintext)
        .map_err(|e| format!("encryption failed: {e}"))?;
    let mut out = nonce.to_vec();
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

pub fn decrypt(id: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() < 12 {
        return Err("ciphertext too short (missing nonce)".into());
    }
    let key_bytes = derive_key(id);
    let key = Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    let nonce = Nonce::from_slice(&data[..12]);
    cipher
        .decrypt(nonce, &data[12..])
        .map_err(|e| format!("decryption failed: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let id = generate_id();
        let plaintext = b"hello world";
        let encrypted = encrypt(&id, plaintext).unwrap();
        let decrypted = decrypt(&id, &encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn wrong_id_fails() {
        let id1 = generate_id();
        let id2 = generate_id();
        let encrypted = encrypt(&id1, b"secret").unwrap();
        assert!(decrypt(&id2, &encrypted).is_err());
    }

    #[test]
    fn id_format() {
        let id = generate_id();
        assert_eq!(id.len(), 7);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn file_id_is_deterministic() {
        let id = generate_id();
        assert_eq!(file_id(&id), file_id(&id));
        assert_eq!(file_id(&id).len(), 16);
    }

    #[test]
    fn different_ids_different_file_ids() {
        let id1 = generate_id();
        let id2 = generate_id();
        assert_ne!(file_id(&id1), file_id(&id2));
    }
}
