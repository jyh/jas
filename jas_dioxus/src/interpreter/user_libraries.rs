//! A user's saved libraries, laid over the bundle's at launch (row 149).
//!
//! NOT gated on `ffi` or `web`: the engine's door for the Windows shell
//! (`ffi::jas_engine_load_user_libraries`) calls it, and the cross-language
//! corpus `test_fixtures/algorithms/user_library_merge.json` runs it in every
//! feature set, beside the Mac's own loader (`BrushLibraryStore`).

use serde_json::{Map, Value};

/// The three library kinds a user can save, each with its folder under the
/// saved root: `brushes/<slug>/library.json`, `swatches/<id>.json`,
/// `gradients/<id>.json` (the layout every writer uses: the Mac's
/// `BrushLibraryStore`, the Windows shell's library write path).
pub const USER_LIBRARY_KINDS: [(&str, &str); 3] =
    [("brush_libraries", "brushes"), ("swatch_libraries", "swatches"), ("gradient_libraries", "gradients")];

/// The user's saved libraries under `root`, keyed by kind, then by slug. A
/// file is read only when its whole text parses to a JSON OBJECT; anything
/// else (an array, malformed text, another extension, the wrong layout for
/// its folder, an unreadable or absent folder) is skipped, never an error,
/// as the Mac's `BrushLibraryStore.load` / `loadSwatches` / `loadGradients`
/// skip it. Pinned with the Mac's loader by
/// `test_fixtures/algorithms/user_library_merge.json`.
pub fn load_user_libraries(root: &std::path::Path) -> Map<String, Value> {
    fn object_at(path: &std::path::Path) -> Option<Value> {
        let text = std::fs::read_to_string(path).ok()?;
        serde_json::from_str::<Value>(&text).ok().filter(Value::is_object)
    }
    let mut out = Map::new();
    for (kind, folder) in USER_LIBRARY_KINDS {
        let dir = root.join(folder);
        let mut names: Vec<String> = std::fs::read_dir(&dir)
            .map(|rd| rd.filter_map(|e| e.ok()?.file_name().into_string().ok()).collect())
            .unwrap_or_default();
        names.sort();
        let mut libs = Map::new();
        for name in names {
            let (slug, file) = if kind == "brush_libraries" {
                (name.clone(), dir.join(&name).join("library.json"))
            } else {
                match name.strip_suffix(".json").filter(|s| !s.is_empty()) {
                    Some(id) => (id.to_string(), dir.join(&name)),
                    None => continue,
                }
            };
            if file.is_file() {
                if let Some(lib) = object_at(&file) {
                    libs.insert(slug, lib);
                }
            }
        }
        out.insert(kind.into(), Value::Object(libs));
    }
    out
}

/// One kind's libraries: the bundle's, with the user's laid over them slug
/// for slug, the user's winning (the Mac's `BrushLibraryStore.merged`).
pub fn merged_libraries(bundle: &Value, user: &Value) -> Value {
    let mut out = bundle.as_object().cloned().unwrap_or_default();
    if let Some(u) = user.as_object() {
        for (slug, lib) in u {
            out.insert(slug.clone(), lib.clone());
        }
    }
    Value::Object(out)
}
