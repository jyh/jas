import Testing
import Foundation
@testable import JasLib

/// STATUS-jas item 37: `toggle_brush_library_persistent` runs its YAML through
/// the Brushes panel's route (`BrushesPanel.dispatch` → `runYamlActionByName`)
/// (`preferences.toggle_member`), an override over the bundle's default list;
/// the Brushes menu's `checked_when` reads the result. Mirrors Rust
/// `interpreter::preferences` tests and the reference's.
@Suite struct PreferenceWriteTests {

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

    @Test func theToggleRefusesAKeyThatIsNotABundledList() {
        #expect(!Preferences.toggleMember("viewport.zoom_step", 2))
        #expect(!Preferences.toggleMember("brushes.no_such_list", "x"))
    }
}
