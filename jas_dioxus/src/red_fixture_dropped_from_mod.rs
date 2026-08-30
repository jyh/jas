// ⛔ TEMPORARY RED FIXTURE — this file is deliberately NOT declared in any
// `mod`, so rustc never compiles it and the wasm lane never runs the test
// below. The crate's source therefore declares 18 `#[wasm_bindgen_test]`
// while the lane can only run 17.
//
// That is not a contrived shape: "a renamed file dropped from `mod`" is one of
// the failure modes check_wasm_canvas_count.py names in its own header, and it
// is invisible to the floor this commit's parent replaced. This fixture exists
// to be SEEN RED in real CI before the gate is trusted, and the next commit
// deletes it.
#[wasm_bindgen_test]
fn declared_in_a_file_no_mod_declares() {}
