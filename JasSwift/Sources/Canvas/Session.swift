/// Session persistence — save the open canvases on quit and reload
/// them on launch so dev iteration doesn't have to redraw test
/// content every restart.
///
/// Session lives in `~/Library/Application Support/Jas/session/`:
///   - `index.json`     — tab order, filenames, active-tab pointer.
///   - `tabN.jasbin`    — each tab's document, in JAS binary format
///                        (jas_dioxus / jas / jas_flask cross-port
///                        compatible — see `Geometry/Binary.swift`).
///
/// The session is rewritten in full on every save (no incremental
/// updates) — the data volume is tiny and the codec is fast enough
/// that this stays under a few hundred ms even with several tabs.

import Foundation

private struct SessionTab: Codable {
    let filename: String
    let binFile: String
}

private struct SessionIndex: Codable {
    let schemaVersion: Int
    let tabs: [SessionTab]
    let activeIndex: Int?
}

public extension WorkspaceState {
    /// Disk path where the session lives. Created on demand.
    static var sessionDirectory: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Jas/session")
    }

    /// Persist the current open canvases — tab order, filenames,
    /// active tab — and each canvas's document as a JAS-binary blob.
    /// Idempotent and best-effort: any I/O error is logged and
    /// swallowed (a failed session save shouldn't block app quit).
    func persistSession() {
        let dir = Self.sessionDirectory
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[session] mkdir failed: \(error)")
            return
        }
        // Wipe stale tab blobs from the previous session so a
        // closed-tab file doesn't reappear if the new session has
        // fewer tabs.
        if let existing = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        {
            for url in existing where url.lastPathComponent.hasSuffix(".jasbin") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        var tabs: [SessionTab] = []
        for (i, entry) in canvases.enumerated() {
            let bin = "tab\(i).jasbin"
            let data = documentToBinary(entry.model.document, compress: true)
            let url = dir.appendingPathComponent(bin)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[session] write \(bin) failed: \(error)")
                continue
            }
            tabs.append(SessionTab(
                filename: entry.model.filename,
                binFile: bin
            ))
        }
        let activeIdx: Int? = {
            guard let id = selectedTab else { return canvases.isEmpty ? nil : 0 }
            return canvases.firstIndex { $0.id == id }
        }()
        let index = SessionIndex(
            schemaVersion: 1, tabs: tabs, activeIndex: activeIdx)
        do {
            let data = try JSONEncoder().encode(index)
            try data.write(
                to: dir.appendingPathComponent("index.json"),
                options: .atomic)
        } catch {
            NSLog("[session] index write failed: \(error)")
        }
    }

    /// Reload the session saved by `persistSession`. Returns the
    /// number of tabs restored. Best-effort: any individual tab that
    /// fails to load is skipped (logged) so a single corrupt blob
    /// doesn't lose the rest of the session.
    @discardableResult
    func restoreSession() -> Int {
        let dir = Self.sessionDirectory
        let indexURL = dir.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(SessionIndex.self, from: data)
        else { return 0 }
        guard index.schemaVersion == 1 else {
            NSLog("[session] unsupported schemaVersion \(index.schemaVersion)")
            return 0
        }
        var loaded: [CanvasEntry] = []
        for tab in index.tabs {
            let url = dir.appendingPathComponent(tab.binFile)
            guard let blob = try? Data(contentsOf: url) else {
                NSLog("[session] missing tab blob \(tab.binFile)")
                continue
            }
            do {
                var doc = try binaryToDocument(blob)
                // The binary format predates the artboards feature
                // and decodes into a doc with `artboards: []`. The
                // canvas relies on the at-least-one-artboard
                // invariant; without this, the restored doc shows
                // no artboard frame. Mirrors the Rust load_session
                // path which calls ensure_artboards_invariant.
                let (repaired, _) = ensureArtboardsInvariant(doc.artboards)
                if repaired.count != doc.artboards.count {
                    doc = Document(
                        layers: doc.layers,
                        selectedLayer: doc.selectedLayer,
                        selection: doc.selection,
                        artboards: repaired,
                        artboardOptions: doc.artboardOptions,
                        documentSetup: doc.documentSetup,
                        printPreferences: doc.printPreferences
                    )
                }
                let model = Model(document: doc, filename: tab.filename)
                loaded.append(CanvasEntry(model: model))
            } catch {
                NSLog("[session] decode \(tab.binFile) failed: \(error)")
            }
        }
        guard !loaded.isEmpty else { return 0 }
        canvases = loaded
        if let idx = index.activeIndex, idx >= 0, idx < loaded.count {
            selectedTab = loaded[idx].id
        } else {
            selectedTab = loaded.first?.id
        }
        return loaded.count
    }
}
