//! Session persistence: save/restore open documents to localStorage.
//!
//! On `beforeunload` and every 30 seconds, all open tabs are serialized
//! to localStorage using the binary document format (MessagePack + deflate).
//! On startup, `load_session` restores them.
//!
//! Storage layout:
//!   - `"jas_session"` — JSON manifest listing tab filenames and keys
//!   - `"jas_doc:0"`, `"jas_doc:1"`, … — base64-encoded binary document data

use crate::document::document::Document;
use crate::geometry::binary::{binary_to_document, document_to_binary};

use super::app_state::TabState;

const SESSION_KEY: &str = "jas_session";
const DOC_KEY_PREFIX: &str = "jas_doc:";

// ---------------------------------------------------------------------------
// Base64 encode / decode
// ---------------------------------------------------------------------------

fn base64_encode(data: &[u8]) -> String {
    const TABLE: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((triple >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[((triple >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[(triple & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

fn base64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a' + 26) as u32),
            b'0'..=b'9' => Some((c - b'0' + 52) as u32),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let bytes: Vec<u8> = s.bytes().filter(|&b| b != b'=' && b != b'\n' && b != b'\r').collect();
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    for chunk in bytes.chunks(4) {
        if chunk.len() < 2 { break; }
        let a = val(chunk[0])?;
        let b = val(chunk[1])?;
        out.push(((a << 2) | (b >> 4)) as u8);
        if chunk.len() > 2 {
            let c = val(chunk[2])?;
            out.push((((b & 0xF) << 4) | (c >> 2)) as u8);
            if chunk.len() > 3 {
                let d = val(chunk[3])?;
                out.push((((c & 0x3) << 6) | d) as u8);
            }
        }
    }
    Some(out)
}

// ---------------------------------------------------------------------------
// localStorage helpers
// ---------------------------------------------------------------------------

#[cfg(target_arch = "wasm32")]
fn storage() -> Option<web_sys::Storage> {
    web_sys::window()?.local_storage().ok()?
}

#[cfg(target_arch = "wasm32")]
fn storage_get(key: &str) -> Option<String> {
    storage()?.get_item(key).ok()?
}

#[cfg(target_arch = "wasm32")]
fn storage_set(key: &str, value: &str) {
    if let Some(s) = storage() {
        let _ = s.set_item(key, value);
    }
}

#[cfg(target_arch = "wasm32")]
fn storage_remove(key: &str) {
    if let Some(s) = storage() {
        let _ = s.remove_item(key);
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Save all open tabs to localStorage.
#[cfg(target_arch = "wasm32")]
pub(crate) fn save_session(tabs: &[TabState], active_tab: usize) {
    if tabs.is_empty() {
        clear_session();
        return;
    }

    // Build manifest and write each document.
    let mut tab_entries = Vec::new();
    for (i, tab) in tabs.iter().enumerate() {
        let key = format!("{}{}", DOC_KEY_PREFIX, i);
        let binary = document_to_binary(tab.model.document(), true);
        let encoded = base64_encode(&binary);
        storage_set(&key, &encoded);
        tab_entries.push(format!(
            "{{\"filename\":{},\"key\":\"{}\"}}",
            serde_json::Value::String(tab.model.filename.clone()),
            key
        ));
    }

    let manifest = format!(
        "{{\"version\":1,\"active_tab\":{},\"tabs\":[{}]}}",
        active_tab,
        tab_entries.join(",")
    );
    storage_set(SESSION_KEY, &manifest);

    // Clean up stale document keys beyond current tab count.
    for i in tabs.len()..tabs.len() + 20 {
        let key = format!("{}{}", DOC_KEY_PREFIX, i);
        if storage_get(&key).is_some() {
            storage_remove(&key);
        } else {
            break;
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn save_session(_tabs: &[TabState], _active_tab: usize) {}

/// Load saved session from localStorage.
/// Returns `(active_tab, Vec<(filename, Document)>)`, or `None` if no session.
#[cfg(target_arch = "wasm32")]
pub(crate) fn load_session() -> Option<(usize, Vec<(String, Document)>)> {
    let manifest_str = storage_get(SESSION_KEY)?;
    let manifest: serde_json::Value = serde_json::from_str(&manifest_str).ok()?;

    let version = manifest.get("version")?.as_u64()?;
    if version > 1 {
        log::warn!("session: unsupported version {}", version);
        return None;
    }

    let active_tab = manifest.get("active_tab")?.as_u64()? as usize;
    let tabs_arr = manifest.get("tabs")?.as_array()?;

    let mut restored = Vec::new();
    for tab_entry in tabs_arr {
        let filename = tab_entry.get("filename")?.as_str()?;
        let key = tab_entry.get("key")?.as_str()?;

        let encoded = match storage_get(key) {
            Some(e) => e,
            None => {
                log::warn!("session: missing document key '{}'", key);
                continue;
            }
        };

        let bytes = match base64_decode(&encoded) {
            Some(b) => b,
            None => {
                log::warn!("session: base64 decode failed for '{}'", key);
                continue;
            }
        };

        match binary_to_document(&bytes) {
            Ok(mut doc) => {
                // The binary format predates the artboards feature so
                // unpack_document sets `artboards: Vec::new()`. Run the
                // at-least-one-artboard repair here per ARTBOARDS.md
                // §At-least-one-artboard invariant — without it the
                // restored tab has no artboard and
                // center_view_on_current_artboard early-returns,
                // leaving the canvas blank.
                crate::document::artboard::ensure_artboards_invariant(
                    &mut doc.artboards, None);
                restored.push((filename.to_string(), doc));
            }
            Err(e) => {
                log::warn!("session: binary decode failed for '{}': {}", key, e);
                continue;
            }
        }
    }

    if restored.is_empty() {
        return None;
    }

    Some((active_tab, restored))
}

#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn load_session() -> Option<(usize, Vec<(String, Document)>)> {
    None
}

/// Remove all session keys from localStorage.
#[cfg(target_arch = "wasm32")]
pub(crate) fn clear_session() {
    storage_remove(SESSION_KEY);
    for i in 0..100 {
        let key = format!("{}{}", DOC_KEY_PREFIX, i);
        if storage_get(&key).is_some() {
            storage_remove(&key);
        } else {
            break;
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn clear_session() {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_roundtrip_empty() {
        let encoded = base64_encode(&[]);
        let decoded = base64_decode(&encoded).unwrap();
        assert_eq!(decoded, Vec::<u8>::new());
    }

    #[test]
    fn base64_roundtrip_small() {
        for len in 1..=20 {
            let data: Vec<u8> = (0..len).map(|i| (i * 37 + 13) as u8).collect();
            let encoded = base64_encode(&data);
            let decoded = base64_decode(&encoded).unwrap();
            assert_eq!(decoded, data, "roundtrip failed for len={}", len);
        }
    }

    #[test]
    fn base64_roundtrip_binary_document() {
        let doc = Document::default();
        let binary = document_to_binary(&doc, true);
        let encoded = base64_encode(&binary);
        let decoded = base64_decode(&encoded).unwrap();
        assert_eq!(decoded, binary);
        let doc2 = binary_to_document(&decoded).unwrap();
        assert_eq!(doc.selected_layer, doc2.selected_layer);
    }
}
