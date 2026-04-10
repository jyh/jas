/// CLI tool for cross-language commutativity testing.
///
/// Usage:
///   svg_roundtrip parse <file.svg>      -- parse SVG, output canonical JSON
///   svg_roundtrip roundtrip <file.svg>  -- parse SVG, re-serialize, output SVG

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: {} parse|roundtrip <file.svg>", args[0]);
        std::process::exit(1);
    }

    let mode = &args[1];
    let path = &args[2];

    let svg = std::fs::read_to_string(path)
        .unwrap_or_else(|e| { eprintln!("Failed to read {}: {}", path, e); std::process::exit(1); });

    let doc = jas_dioxus::geometry::svg::svg_to_document(&svg);

    match mode.as_str() {
        "parse" => {
            print!("{}", jas_dioxus::geometry::test_json::document_to_test_json(&doc));
        }
        "roundtrip" => {
            print!("{}", jas_dioxus::geometry::svg::document_to_svg(&doc));
        }
        _ => {
            eprintln!("Unknown mode: {} (use 'parse' or 'roundtrip')", mode);
            std::process::exit(1);
        }
    }
}
