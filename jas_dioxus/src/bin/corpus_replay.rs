/// CLI over the SHARED corpus replay path (`jas_dioxus::recorder::replay`
/// — the same code the cross-language corpus runners and the recorder's
/// record-stop fidelity check execute). Used by
/// `scripts/ingest_recording.py` to mint `*_expected.json` goldens for
/// recorded fixtures.
///
/// Usage:
///   corpus_replay <gesture|action|journal|key> <fixture.json>
///
/// `fixture.json` is a corpus fixture file (an array of cases — or, for
/// the key seam, groups). `setup_svg` file references are resolved
/// against the fixture's sibling `../svg/` directory (the corpus
/// layout). Prints a JSON object mapping each case/group name to the
/// canonical golden string it replays to.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: {} <gesture|action|journal|key> <fixture.json>", args[0]);
        std::process::exit(1);
    }
    let seam = args[1].as_str();
    let fixture_path = std::path::Path::new(&args[2]);

    let json = std::fs::read_to_string(fixture_path).unwrap_or_else(|e| {
        eprintln!("Failed to read {}: {}", fixture_path.display(), e);
        std::process::exit(1);
    });
    let cases: serde_json::Value = serde_json::from_str(&json).unwrap_or_else(|e| {
        eprintln!("{} is not valid JSON: {}", fixture_path.display(), e);
        std::process::exit(1);
    });
    let svg_dir = fixture_path
        .parent()
        .map(|d| d.join("../svg"))
        .unwrap_or_else(|| "../svg".into());

    let read_setup = |tc: &serde_json::Value| -> String {
        let name = tc["setup_svg"].as_str().unwrap_or_else(|| {
            eprintln!("case {:?} has no setup_svg", tc.get("name"));
            std::process::exit(1);
        });
        let p = svg_dir.join(name);
        std::fs::read_to_string(&p).unwrap_or_else(|e| {
            eprintln!("Failed to read setup {}: {}", p.display(), e);
            std::process::exit(1);
        })
    };

    use jas_dioxus::recorder::replay;
    let mut out = serde_json::Map::new();
    for tc in cases.as_array().unwrap_or(&Vec::new()) {
        let name = tc["name"].as_str().unwrap_or("<unnamed>").to_string();
        let golden = match seam {
            "gesture" => replay::run_gesture_case_json(tc, &read_setup(tc)),
            "action" => replay::run_action_case_json(tc, &read_setup(tc)),
            "journal" => replay::run_journal_case_json(tc, &read_setup(tc)),
            "key" => replay::run_key_group_json(tc),
            other => {
                eprintln!("Unknown seam: {other} (use gesture|action|journal|key)");
                std::process::exit(1);
            }
        };
        out.insert(name, serde_json::Value::String(golden));
    }
    println!("{}", serde_json::to_string_pretty(&serde_json::Value::Object(out)).unwrap());
}
