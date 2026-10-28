import Testing
import Foundation
@testable import JasLib

/// STATUS-jas item 37: `toggle_brush_library_persistent` runs its YAML through
/// the Brushes panel's route (`BrushesPanel.dispatch` → `runYamlActionByName`)
/// (`preferences.toggle_member`), an override over the bundle's default list;
/// the Brushes menu's `checked_when` reads the result. Mirrors Rust
/// `interpreter::preferences` tests and the reference's.
/// `.serialized`: the overrides are one process-wide store, and two tests
/// here toggle it.
@Suite(.serialized) struct PreferenceWriteTests {

    private static func list(_ prefs: [String: Any]?) -> [String] {
        ((prefs?["brushes"] as? [String: Any])?["persistent_libraries"] as? [String]) ?? []
    }

    @Test func thePersistentToggleRunsItsYamlAndTheCheckFollows() {
        let bundled = Self.list(WorkspaceData.load()?.data["preferences"] as? [String: Any])
        #expect(!bundled.isEmpty, "the control: the bundle names a persistent library")
        let lib = "a_library_not_in_the_bundle_swift"
        let m = Model()
        m.stateStore.initPanel("brushes_panel_content", defaults: ["selected_library": lib])
        m.stateStore.setActivePanel("brushes_panel_content")
        runYamlActionByName("toggle_brush_library_persistent", params: [:], model: m)
        #expect(Self.list(Preferences.current()) == bundled + [lib], "toggled on")
        runYamlActionByName("toggle_brush_library_persistent", params: [:], model: m)
        #expect(Self.list(Preferences.current()) == bundled, "toggled off: the override is dropped")
        #expect(Self.list(WorkspaceData.load()?.data["preferences"] as? [String: Any]) == bundled,
                "the bundle is never written")
    }

    /// The launch half (state.yaml: `brushes_open_libraries` is initialised at
    /// startup from the preference), against the shared fixture the
    /// reference and Rust read.
    @Test func openLibrariesAtLaunchMatchesTheSharedFixture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("test_fixtures").appendingPathComponent("preferences/open_libraries_at_launch.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let cases = json?["cases"] as? [[String: Any]] ?? []
        #expect(cases.count >= 4, "the fixture is not vacuous")
        for c in cases {
            let got = Preferences.openLibrariesAtLaunch(c["persistent_libraries"])
            #expect(NSArray(array: got).isEqual(to: c["expected"] as? [Any] ?? []), "\(c["name"] ?? "")")
        }
    }

    @Test func theStateDefaultsOpenTheCurrentPreferencesLibraries() {
        let open = { WorkspaceData.load()?.stateDefaults()["brushes_open_libraries"] as? [[String: Any]] ?? [] }
        let ids = { open().compactMap { $0["id"] as? String } }
        #expect(ids() == ["default_brushes"], "the bundle")
        let lib = "a_library_not_in_the_bundle_swift_launch"
        #expect(Preferences.toggleMember("brushes.persistent_libraries", lib))
        let got = ids()
        #expect(Preferences.toggleMember("brushes.persistent_libraries", lib), "restore")
        #expect(got == ["default_brushes", lib], "the override is read")
        #expect(open().allSatisfy { ($0["collapsed"] as? Bool) == false })
    }

    /// Persistence across launches: every write hands the overrides to the
    /// app's hook, and a launch imports what was saved.
    @Test func theOverridesRoundTripThroughTheAppsStorage() {
        var saved: [String] = []
        Preferences.onChange = { saved.append($0) }
        defer { Preferences.onChange = nil; Preferences.importOverrides("{}") }
        let lib = "a_library_saved_across_launches_swift"
        #expect(Preferences.toggleMember("brushes.persistent_libraries", lib))
        let json = saved.last
        #expect(json != nil, "the toggle saved")
        Preferences.onChange = nil
        Preferences.importOverrides("{}")
        #expect(!Self.list(Preferences.current()).contains(lib), "the control: a fresh launch without the save")
        Preferences.importOverrides(json)
        #expect(Self.list(Preferences.current()).contains(lib), "the save restores the override")
        Preferences.importOverrides("garbage{{{")
        #expect(Self.list(Preferences.current()) == Self.list(WorkspaceData.load()?.data["preferences"] as? [String: Any]),
                "an unreadable save is the bundle, not a crash")
        #expect(Preferences.exportOverrides() == "{}")
    }

    @Test func theToggleRefusesAKeyThatIsNotABundledList() {
        #expect(!Preferences.toggleMember("viewport.zoom_step", 2))
        #expect(!Preferences.toggleMember("brushes.no_such_list", "x"))
    }
}
