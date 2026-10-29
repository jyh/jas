import Foundation

/// The Mac host half of Save Brush Library (the 2026-10-28 jas brush-library
/// design, B.3). `brush.save_library` queues `{kind, slug, manifest}` on the
/// store (``StateStore/appendPendingWrite(_:)``); the sink installed from
/// ``live`` writes `<root>/brushes/<slug>/library.json`, and at launch the
/// libraries under `root` shadow the bundle's by slug (``merged(bundle:user:)``).
/// Never the bundle's `workspace/`, which is read-only.
public struct BrushLibraryStore {
    public struct BadSlug: Error { public let slug: String }

    /// The directory that holds `brushes/`.
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The app's store. Set ONLY by `JasApp.init`, and not under `--test-fifo`;
    /// nil in a test process, so a `Model()` there never touches the
    /// developer's Application Support.
    nonisolated(unsafe) public static var live: BrushLibraryStore?

    /// `Application Support/Jas`, the session's sibling.
    public static var appSupportRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Jas")
    }

    /// Write one library. The slug must be what `brush.save_library` makes,
    /// `[a-z0-9_]+`, so no slug can name a path outside `brushes/`.
    public func write(slug: String, manifest: [String: Any]) throws {
        guard !slug.isEmpty, slug.unicodeScalars.allSatisfy({
            ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "_"
        }) else { throw BadSlug(slug: slug) }
        let dir = root.appendingPathComponent("brushes").appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("library.json"), options: .atomic)
    }

    /// Every `brushes/<slug>/library.json` under `root` that holds a JSON
    /// object, keyed by slug, as the reference's loader reads the bundle's.
    /// Anything else is skipped.
    public func load() -> [String: Any] {
        let dir = root.appendingPathComponent("brushes")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var out: [String: Any] = [:]
        for slug in entries.sorted() {
            let file = dir.appendingPathComponent(slug).appendingPathComponent("library.json")
            if let data = try? Data(contentsOf: file),
               let lib = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                out[slug] = lib
            }
        }
        return out
    }

    /// The bundle's libraries with the user's laid over them, slug for slug.
    public static func merged(bundle: [String: Any], user: [String: Any]) -> [String: Any] {
        bundle.merging(user) { _, mine in mine }
    }

    /// A ``StateStore/pendingWriteSink``: writes a `brush_library` request and
    /// reports success; any other kind is not this sink's and stays queued.
    public var sink: ([String: Any]) -> Bool {
        { w in
            guard w["kind"] as? String == "brush_library", let slug = w["slug"] as? String,
                  let manifest = w["manifest"] as? [String: Any] else { return false }
            do { try write(slug: slug, manifest: manifest); return true } catch {
                NSLog("jas: brush library write failed for \(slug): \(error)")
                return false
            }
        }
    }
}
