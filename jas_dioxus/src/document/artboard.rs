//! Artboards: print-page regions attached to the document root.
//!
//! See `transcripts/ARTBOARDS.md` for the full specification. In
//! summary, every document has at least one artboard; `Artboard`
//! carries position, size, fill, display toggles, and a stable
//! 8-char base36 `id`. The 1-based `number` shown in the panel is
//! derived from list position, not stored.
//!
//! Serialization format (matches Python `StateStore._document["artboards"]`
//! exactly — cross-app contract, ART-441):
//!
//! ```text
//! {
//!   "id": "abc12345",
//!   "name": "Artboard 1",
//!   "x": 0, "y": 0,
//!   "width": 612, "height": 792,
//!   "fill": "transparent",  // or a "#rrggbb" hex
//!   "show_center_mark": false,
//!   "show_cross_hairs": false,
//!   "show_video_safe_areas": false,
//!   "video_ruler_pixel_aspect_ratio": 1.0
//! }
//! ```

// Module-wide allow: this is a foundational types module (Artboard,
// ArtboardOptions, ID generation, JSON shape) most of whose surface
// is consumed by tests, the test_json fixture pipeline, and panels
// that read individual fields lazily. Per-item annotation would
// approach one allow per public type.
#![allow(dead_code)]

const ARTBOARD_ID_ALPHABET: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
const ARTBOARD_ID_LENGTH: usize = 8;

/// The `fill` property is a sum type: either `Transparent` or an
/// opaque color literal. The string form (`"transparent"` or
/// `"#rrggbb"`) is the canonical serialization.
#[derive(Debug, Clone, PartialEq)]
pub enum ArtboardFill {
    Transparent,
    Color(String),
}

impl ArtboardFill {
    pub fn as_canonical(&self) -> String {
        match self {
            ArtboardFill::Transparent => "transparent".to_string(),
            ArtboardFill::Color(hex) => hex.clone(),
        }
    }

    pub fn from_canonical(s: &str) -> Self {
        if s == "transparent" {
            ArtboardFill::Transparent
        } else {
            ArtboardFill::Color(s.to_string())
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Artboard {
    pub id: String,
    pub name: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub fill: ArtboardFill,
    pub show_center_mark: bool,
    pub show_cross_hairs: bool,
    pub show_video_safe_areas: bool,
    pub video_ruler_pixel_aspect_ratio: f64,
}

impl Artboard {
    /// Canonical default: Letter 612x792 at origin, transparent fill,
    /// all display toggles off. The `id` argument comes from the
    /// id generator (seeded in tests; platform-sourced in production).
    pub fn default_with_id(id: String) -> Self {
        Self {
            id,
            name: "Artboard 1".to_string(),
            x: 0.0,
            y: 0.0,
            width: 612.0,
            height: 792.0,
            fill: ArtboardFill::Transparent,
            show_center_mark: false,
            show_cross_hairs: false,
            show_video_safe_areas: false,
            video_ruler_pixel_aspect_ratio: 1.0,
        }
    }
}

/// Document-global artboard toggles. Both default to on.
#[derive(Debug, Clone, PartialEq)]
pub struct ArtboardOptions {
    pub fade_region_outside_artboard: bool,
    pub update_while_dragging: bool,
}

impl Default for ArtboardOptions {
    fn default() -> Self {
        Self {
            fade_region_outside_artboard: true,
            update_while_dragging: true,
        }
    }
}

/// Platform-sourced 32-bit entropy. In wasm uses `Math::random()`;
/// on other targets a one-shot draw from `std::collections::hash_map::RandomState`.
fn platform_entropy() -> u32 {
    #[cfg(target_arch = "wasm32")]
    {
        (js_sys::Math::random() * (u32::MAX as f64)) as u32
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        use std::collections::hash_map::RandomState;
        use std::hash::{BuildHasher, Hasher};
        let mut h = RandomState::new().build_hasher();
        h.write_usize(std::process::id() as usize);
        // Also mix current nanoseconds for some intra-process variation.
        if let Ok(dur) = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
        {
            h.write_u128(dur.as_nanos());
        }
        h.finish() as u32
    }
}

/// Mint a fresh 8-char base36 id. Optionally seeded via ``rng`` for
/// deterministic tests; otherwise the platform entropy source is
/// tapped fresh per character.
pub fn generate_artboard_id(rng: Option<&mut dyn FnMut() -> u32>) -> String {
    let mut bytes = [0u8; ARTBOARD_ID_LENGTH];
    match rng {
        Some(source) => {
            for slot in bytes.iter_mut() {
                let idx = (source() as usize) % ARTBOARD_ID_ALPHABET.len();
                *slot = ARTBOARD_ID_ALPHABET[idx];
            }
        }
        None => {
            for slot in bytes.iter_mut() {
                let idx = (platform_entropy() as usize) % ARTBOARD_ID_ALPHABET.len();
                *slot = ARTBOARD_ID_ALPHABET[idx];
            }
        }
    }
    // Safe: the alphabet contains only ASCII characters.
    String::from_utf8(bytes.to_vec()).expect("base36 alphabet is ASCII")
}

/// Match a name against the default `Artboard N` pattern and return
/// N on success. Case-sensitive, exactly one space between `Artboard`
/// and the digits (ARTBOARDS.md §Numbering and naming).
fn parse_default_name(name: &str) -> Option<u32> {
    let prefix = "Artboard ";
    if !name.starts_with(prefix) {
        return None;
    }
    let rest = &name[prefix.len()..];
    if rest.is_empty() {
        return None;
    }
    // Exactly-one-space enforcement: `rest` must start with a digit.
    if !rest.chars().next().unwrap().is_ascii_digit() {
        return None;
    }
    // All remaining chars must be ASCII digits.
    if !rest.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    rest.parse::<u32>().ok()
}

/// Pick the next unused ``Artboard N`` name.
pub fn next_artboard_name(artboards: &[Artboard]) -> String {
    let mut used: std::collections::HashSet<u32> = std::collections::HashSet::new();
    for a in artboards {
        if let Some(n) = parse_default_name(&a.name) {
            used.insert(n);
        }
    }
    let mut n: u32 = 1;
    while used.contains(&n) {
        n += 1;
    }
    format!("Artboard {}", n)
}

/// Enforce the at-least-one-artboard invariant in place. Returns
/// true when a default artboard was inserted (caller emits log).
pub fn ensure_artboards_invariant(
    artboards: &mut Vec<Artboard>,
    id_generator: Option<&mut dyn FnMut() -> String>,
) -> bool {
    if !artboards.is_empty() {
        return false;
    }
    let id = match id_generator {
        Some(id_gen) => id_gen(),
        None => generate_artboard_id(None),
    };
    artboards.push(Artboard::default_with_id(id));
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_artboard_has_canonical_fields() {
        let ab = Artboard::default_with_id("seedfeed".to_string());
        assert_eq!(ab.id, "seedfeed");
        assert_eq!(ab.name, "Artboard 1");
        assert_eq!(ab.x, 0.0);
        assert_eq!(ab.y, 0.0);
        assert_eq!(ab.width, 612.0);
        assert_eq!(ab.height, 792.0);
        assert_eq!(ab.fill, ArtboardFill::Transparent);
        assert!(!ab.show_center_mark);
        assert!(!ab.show_cross_hairs);
        assert!(!ab.show_video_safe_areas);
        assert_eq!(ab.video_ruler_pixel_aspect_ratio, 1.0);
    }

    #[test]
    fn fill_canonical_roundtrip() {
        assert_eq!(ArtboardFill::Transparent.as_canonical(), "transparent");
        assert_eq!(
            ArtboardFill::Color("#ff0000".to_string()).as_canonical(),
            "#ff0000"
        );
        assert_eq!(
            ArtboardFill::from_canonical("transparent"),
            ArtboardFill::Transparent
        );
        assert_eq!(
            ArtboardFill::from_canonical("#ff0000"),
            ArtboardFill::Color("#ff0000".to_string())
        );
    }

    #[test]
    fn id_is_8_chars_base36_seeded() {
        let mut seq: u32 = 0;
        let mut id_gen = || {
            seq += 1;
            seq
        };
        let id = generate_artboard_id(Some(&mut id_gen));
        assert_eq!(id.len(), ARTBOARD_ID_LENGTH);
        assert!(id.chars().all(|c| ARTBOARD_ID_ALPHABET.contains(&(c as u8))));
    }

    #[test]
    fn id_deterministic_with_same_seed() {
        let mut seq_a = 42u32;
        let mut id_gen_a = || {
            seq_a = seq_a.wrapping_mul(1103515245).wrapping_add(12345);
            seq_a
        };
        let id_a = generate_artboard_id(Some(&mut id_gen_a));

        let mut seq_b = 42u32;
        let mut id_gen_b = || {
            seq_b = seq_b.wrapping_mul(1103515245).wrapping_add(12345);
            seq_b
        };
        let id_b = generate_artboard_id(Some(&mut id_gen_b));

        assert_eq!(id_a, id_b);
    }

    #[test]
    fn next_name_empty_is_artboard_1() {
        assert_eq!(next_artboard_name(&[]), "Artboard 1");
    }

    #[test]
    fn next_name_skips_used() {
        let abs = vec![
            Artboard {
                name: "Artboard 1".to_string(),
                ..Artboard::default_with_id("aaa".to_string())
            },
            Artboard {
                name: "Artboard 2".to_string(),
                ..Artboard::default_with_id("bbb".to_string())
            },
        ];
        assert_eq!(next_artboard_name(&abs), "Artboard 3");
    }

    #[test]
    fn next_name_fills_gaps() {
        let abs = vec![
            Artboard {
                name: "Artboard 1".to_string(),
                ..Artboard::default_with_id("aaa".to_string())
            },
            Artboard {
                name: "Artboard 3".to_string(),
                ..Artboard::default_with_id("bbb".to_string())
            },
        ];
        assert_eq!(next_artboard_name(&abs), "Artboard 2");
    }

    #[test]
    fn next_name_case_sensitive() {
        let abs = vec![
            Artboard {
                name: "artboard 1".to_string(),
                ..Artboard::default_with_id("aaa".to_string())
            },
            Artboard {
                name: "Artboard  1".to_string(), // two spaces
                ..Artboard::default_with_id("bbb".to_string())
            },
        ];
        // Neither matches the strict pattern; "Artboard 1" is free.
        assert_eq!(next_artboard_name(&abs), "Artboard 1");
    }

    #[test]
    fn parse_default_name_rejects_edge_cases() {
        assert_eq!(parse_default_name("Artboard 1"), Some(1));
        assert_eq!(parse_default_name("Artboard 42"), Some(42));
        assert_eq!(parse_default_name("artboard 1"), None);
        assert_eq!(parse_default_name("Artboard  1"), None); // two spaces
        assert_eq!(parse_default_name("Artboard 1 "), None); // trailing space
        assert_eq!(parse_default_name("Artboard"), None);
        assert_eq!(parse_default_name("Artboard "), None);
        assert_eq!(parse_default_name("Artboard abc"), None);
    }

    #[test]
    fn ensure_invariant_inserts_on_empty() {
        let mut abs: Vec<Artboard> = Vec::new();
        let mut seq = 0u32;
        let mut id_gen = || {
            seq += 1;
            format!("seed{:04}", seq)
        };
        let inserted = ensure_artboards_invariant(&mut abs, Some(&mut id_gen));
        assert!(inserted);
        assert_eq!(abs.len(), 1);
        assert_eq!(abs[0].name, "Artboard 1");
        assert_eq!(abs[0].id, "seed0001");
    }

    #[test]
    fn ensure_invariant_noop_when_nonempty() {
        let mut abs = vec![Artboard::default_with_id("existing".to_string())];
        let inserted = ensure_artboards_invariant(&mut abs, None);
        assert!(!inserted);
        assert_eq!(abs.len(), 1);
        assert_eq!(abs[0].id, "existing");
    }

    #[test]
    fn artboard_options_defaults() {
        let opts = ArtboardOptions::default();
        assert!(opts.fade_region_outside_artboard);
        assert!(opts.update_while_dragging);
    }
}
