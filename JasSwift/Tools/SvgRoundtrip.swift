/// CLI tool for cross-language commutativity testing.
///
/// Usage:
///   SvgRoundtrip parse <file.svg>      -- parse SVG, output canonical JSON
///   SvgRoundtrip roundtrip <file.svg>  -- parse SVG, re-serialize, output SVG

import Foundation
import JasLib

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: \(args[0]) parse|roundtrip <file.svg>\n", stderr)
    exit(1)
}

let mode = args[1]
let path = args[2]

guard let data = FileManager.default.contents(atPath: path),
      let svg = String(data: data, encoding: .utf8) else {
    fputs("Failed to read: \(path)\n", stderr)
    exit(1)
}

let doc = svgToDocument(svg)

switch mode {
case "parse":
    print(documentToTestJson(doc), terminator: "")
case "roundtrip":
    print(documentToSvg(doc), terminator: "")
default:
    fputs("Unknown mode: \(mode) (use 'parse' or 'roundtrip')\n", stderr)
    exit(1)
}
