/// CLI tool for cross-language workspace layout testing.
///
/// Usage:
///   WorkspaceRoundtrip default                       -- canonical JSON for defaultLayout()
///   WorkspaceRoundtrip default_with_panes <w> <h>    -- with pane layout at viewport size
///   WorkspaceRoundtrip parse <workspace.json>        -- parse, output canonical test JSON
///   WorkspaceRoundtrip apply <workspace.json>        -- parse, apply ops from stdin, output canonical test JSON

import Foundation
import JasLib

func readFile(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path),
          let str = String(data: data, encoding: .utf8) else {
        fputs("Failed to read: \(path)\n", stderr)
        exit(1)
    }
    return str.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// OP_LOG 3d-2: this CLI round-trip tool no longer reimplements the 15 layout
/// verbs — it delegates to the shared runtime dispatcher `layoutApply`
/// (Sources/Workspace/LayoutApply.swift), the SAME dispatcher production and the
/// cross-language harness use. Eliminates the third hand-rolled copy (mirrors
/// the Rust `bin/workspace_roundtrip.rs::apply_op` delegation).
func applyOp(_ layout: inout WorkspaceLayout, _ op: [String: Any]) {
    layoutApply(&layout, op)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: \(args[0]) default|default_with_panes|parse|apply ...\n", stderr)
    exit(1)
}

let mode = args[1]

switch mode {
case "default":
    let layout = WorkspaceLayout.defaultLayout()
    print(workspaceToTestJson(layout), terminator: "")

case "default_with_panes":
    guard args.count >= 4,
          let w = Double(args[2]), let h = Double(args[3]) else {
        fputs("Usage: \(args[0]) default_with_panes <width> <height>\n", stderr)
        exit(1)
    }
    var layout = WorkspaceLayout.defaultLayout()
    layout.ensurePaneLayout(viewportW: w, viewportH: h)
    print(workspaceToTestJson(layout), terminator: "")

case "parse":
    guard args.count >= 3 else {
        fputs("Usage: \(args[0]) parse <workspace.json>\n", stderr)
        exit(1)
    }
    let json = readFile(args[2])
    let layout = testJsonToWorkspace(json)
    print(workspaceToTestJson(layout), terminator: "")

case "apply":
    guard args.count >= 3 else {
        fputs("Usage: \(args[0]) apply <workspace.json>  (ops from stdin)\n", stderr)
        exit(1)
    }
    let json = readFile(args[2])
    var layout = testJsonToWorkspace(json)
    var stdinData = Data()
    while let chunk = Optional(FileHandle.standardInput.availableData), !chunk.isEmpty {
        stdinData.append(chunk)
    }
    let opsStr = String(data: stdinData, encoding: .utf8) ?? "[]"
    guard let opsJson = try? JSONSerialization.jsonObject(with: Data(opsStr.utf8)) as? [[String: Any]] else {
        fputs("Failed to parse ops JSON from stdin\n", stderr)
        exit(1)
    }
    for op in opsJson {
        applyOp(&layout, op)
    }
    print(workspaceToTestJson(layout), terminator: "")

default:
    fputs("Unknown mode: \(mode)\n", stderr)
    exit(1)
}
