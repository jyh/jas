import Testing
import Foundation
@testable import JasLib

// The test-only `--test-fifo` `state` and `dialog` reads (TESTING.md, the
// level-2 toolbar forms row 50 needs). On the Mac the live tool and the open
// dialog are ContentView @State; the store's `active_tool` is a MIRROR of the
// tool, written on the click and flyout paths. A read of the mirror would
// measure something else, so `active_tool` comes from what ContentView
// publishes, and a read with nothing published is refused, never answered
// from the store.

private func tmpPath(_ name: String) throws -> (URL, String) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fifo-state-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir, dir.appendingPathComponent(name).path)
}

@Test func fifoStateReadsTheLiveToolNotTheStoreMirror() throws {
    // The two disagree on purpose: an answer of "selection" here is the mirror.
    let store = StateStore(defaults: ["active_tool": "selection"])
    let json = try FifoState.json(keys: ["active_tool"], store: store,
                                  liveTool: "partial_selection")
    #expect(json == #"{"active_tool":"partial_selection"}"#)
}

@Test func fifoStateRefusesActiveToolWhenNothingIsPublished() throws {
    // The store holds a value, and answering with it would read as a measurement.
    let store = StateStore(defaults: ["active_tool": "selection"])
    #expect(throws: FifoReadError.self) {
        try FifoState.json(keys: ["active_tool"], store: store, liveTool: nil)
    }
}

@Test func fifoStateSortsKeysAndReadsOtherKeysFromTheStore() throws {
    let store = StateStore(defaults: ["fill_on_top": true, "active_tool": "pen",
                                      "stroke_width": 2])
    let json = try FifoState.json(keys: ["stroke_width", "active_tool", "fill_on_top"],
                                  store: store, liveTool: "pencil")
    #expect(json == #"{"active_tool":"pencil","fill_on_top":true,"stroke_width":2}"#)
}

@Test func fifoStateRefusesAKeyTheStoreDoesNotHoldByName() throws {
    let store = StateStore(defaults: [:])
    do {
        _ = try FifoState.json(keys: ["no_such_key"], store: store, liveTool: "pen")
        Issue.record("an absent key must be refused")
    } catch let e as FifoReadError {
        #expect("\(e)".contains("no_such_key"))
    }
}

@Test func fifoStateParseNeedsAPathAndDistinctKeys() {
    let p = FifoState.parse("/tmp/s.json active_tool fill_on_top")
    #expect(p?.path == "/tmp/s.json")
    #expect(p?.keys == ["active_tool", "fill_on_top"])
    #expect(FifoState.parse("") == nil)
    #expect(FifoState.parse("/tmp/s.json") == nil)          // no key
    #expect(FifoState.parse("/tmp/s.json a a") == nil)      // a repeated key
}

@Test func fifoStateWriteReplacesTheFile() throws {
    let (dir, path) = try tmpPath("state.json")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = StateStore(defaults: [:])
    try FifoState.write(keys: ["active_tool"], store: store, liveTool: "pen", to: path)
    try FifoState.write(keys: ["active_tool"], store: store, liveTool: "zoom", to: path)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == #"{"active_tool":"zoom"}"#)
}

@Test func fifoDialogReadsTheOpenIdOrNull() throws {
    #expect(FifoDialog.json(dialog: "arrow_alternates") == #"{"dialog":"arrow_alternates"}"#)
    #expect(FifoDialog.json(dialog: nil) == #"{"dialog":null}"#)
    let (dir, path) = try tmpPath("dialog.json")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FifoDialog.write(dialog: "arrow_alternates", to: path)
    try FifoDialog.write(dialog: nil, to: path)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == #"{"dialog":null}"#)
}
