//! THE RECORDED CORPUS, EMBEDDED — so a backend that cannot touch a filesystem
//! can still be driven by the SAME ARTIFACT as one that can.
//!
//! `direct2d/replay.rs` reads `testdata/*.json` with `read_dir`. A wasm backend
//! has no filesystem, so without this the Canvas2D lane could only ever be
//! driven by the scene BUILDERS — which is a different object. The builders are
//! the producer; these files are the artifact both backends must agree on, and
//! "display-list equivalence" is a claim about the artifact.
//!
//! ⛔ AN EMBEDDED LIST GOES STALE SILENTLY. Adding a scene to `testdata/` and
//! forgetting this file would shrink the wasm lane's corpus while every test
//! still passed — the coverage would drop and nothing would say so. That is why
//! [`tests::embedded_corpus_matches_the_directory`] exists and runs natively,
//! where the directory IS readable: it is the only thing standing between this
//! list and quiet rot.

/// `(file name, contents)` for every recorded scene, sorted by name.
pub const SCENES: &[(&str, &str)] = &[
    ("a6_alpha_law.json", include_str!("testdata/a6_alpha_law.json")),
    ("a6_blend.json", include_str!("testdata/a6_blend.json")),
    ("a6_law_variants.json", include_str!("testdata/a6_law_variants.json")),
    ("a6_layer_no_mask.json", include_str!("testdata/a6_layer_no_mask.json")),
    ("a6_nested_layers.json", include_str!("testdata/a6_nested_layers.json")),
    ("group_blend.json", include_str!("testdata/group_blend.json")),
    ("ref_circle_convert.json", include_str!("testdata/ref_circle_convert.json")),
    ("ref_ellipse_convert.json", include_str!("testdata/ref_ellipse_convert.json")),
    ("ref_gradients.json", include_str!("testdata/ref_gradients.json")),
    ("ref_groups.json", include_str!("testdata/ref_groups.json")),
    ("ref_line_convert.json", include_str!("testdata/ref_line_convert.json")),
    ("ref_path_convert.json", include_str!("testdata/ref_path_convert.json")),
    ("ref_paths.json", include_str!("testdata/ref_paths.json")),
    ("ref_polygon_convert.json", include_str!("testdata/ref_polygon_convert.json")),
    ("ref_polyline_convert.json", include_str!("testdata/ref_polyline_convert.json")),
    ("ref_rect_convert.json", include_str!("testdata/ref_rect_convert.json")),
    ("ref_rect_gradstroke_convert.json", include_str!("testdata/ref_rect_gradstroke_convert.json")),
    ("ref_shapes.json", include_str!("testdata/ref_shapes.json")),
    ("ref_stroke_styles.json", include_str!("testdata/ref_stroke_styles.json")),
    ("scene_golden.json", include_str!("testdata/scene_golden.json")),
];

#[cfg(test)]
mod tests {
    use super::SCENES;

    /// ⛔ THE ANTI-DRIFT ARM. Runs natively, where `testdata/` can be listed.
    #[test]
    fn embedded_corpus_matches_the_directory() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/src/painter/testdata");
        let mut on_disk: Vec<String> = std::fs::read_dir(dir)
            .expect("testdata must be readable")
            .filter_map(Result::ok)
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".json"))
            .collect();
        on_disk.sort();
        let embedded: Vec<String> = SCENES.iter().map(|(n, _)| n.to_string()).collect();
        assert_eq!(embedded, on_disk,
                   "the embedded corpus and testdata/ have diverged -- a scene \
                    added to one and not the other silently changes what the \
                    wasm lane replays");
        // ...and it must not be empty, or the check above passes on two voids.
        assert!(!on_disk.is_empty(), "the corpus is empty; nothing is being replayed");
    }

    /// Every embedded scene must parse as an array of command objects. A file
    /// that is present but unparseable would otherwise surface as a zero-op
    /// replay, which reads as "nothing to do" rather than as a broken fixture.
    #[test]
    fn every_embedded_scene_parses_as_a_command_array() {
        for (name, text) in SCENES {
            let v: serde_json::Value = serde_json::from_str(text)
                .unwrap_or_else(|e| panic!("{name} is not valid JSON: {e}"));
            let a = v.as_array().unwrap_or_else(|| panic!("{name} is not an array"));
            assert!(!a.is_empty(), "{name} holds no commands");
            for op in a {
                assert!(op.get("cmd").and_then(serde_json::Value::as_str).is_some(),
                        "{name} has a record with no `cmd`");
            }
        }
    }
}
