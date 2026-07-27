import Foundation
import Testing
@testable import JasLib

/// Risk R9's CALL SITES, as opposed to its shared helpers.
///
/// `R9SaturatingCastTests` holds `saturatingInt`, `intIfIntegral`,
/// `hyphenationFieldInt` and friends to their Rust mirrors. Nothing held the
/// production sites to CALLING them: each of the five sites pinned here could
/// be reverted to its trapping pre-R9 expression with the whole Swift suite
/// still green. Each test below drives the site through the shipping entry
/// point, so a revert is a failure and not a silent regression.
struct R9CallSitePinTests {

    // MARK: - Test-JSON tspan id (TestJson.swift parseTspan)

    /// The shared `id`-domain corpus at
    /// `test_fixtures/algorithms/tspan_id_from_json.json`, driven through the
    /// real element decoder. jas_dioxus runs the same file in
    /// `geometry::test_json::tests::tspan_id_domain_corpus`.
    @Test func tspanIdDomainCorpusMatchesAcrossPorts() {
        let thisFile = #filePath
        let testsDir = (thisFile as NSString).deletingLastPathComponent
        let jasTests = (testsDir as NSString).deletingLastPathComponent
        let jasSwift = (jasTests as NSString).deletingLastPathComponent
        let root = (jasSwift as NSString).appendingPathComponent("../test_fixtures")
        let path = ((root as NSString)
            .appendingPathComponent("algorithms/tspan_id_from_json.json")
            as NSString).standardizingPath
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vectors = file["vectors"] as? [[String: Any]]
        else { fatalError("Failed to read fixture: \(path)") }
        #expect(!vectors.isEmpty)
        for v in vectors {
            let name = v["name"] as? String ?? "?"
            guard case .text(let t) = parseElement(v["input"]) else {
                fatalError("vector \(name): expected a text element")
            }
            let expected = UInt32(truncatingIfNeeded: (v["expected"] as? NSNumber)?.int64Value ?? -1)
            #expect(t.tspans[0].id == expected, "vector \(name)")
            if let last = (v["expected_last"] as? NSNumber)?.uint32Value {
                #expect(t.tspans[t.tspans.count - 1].id == last,
                        "vector \(name) (last tspan)")
            }
        }
    }

    // MARK: - Value bridging (Effects.swift, YamlDialogView.swift)

    /// `1e30`, written as a digit literal because the expression lexer has no
    /// exponent form, is integral (`1e30 == 1e30.rounded(.towardZero)`) and NOT
    /// convertible to `Int`, so the pre-R9 `if n == Double(Int(n))` trapped in
    /// its own guard. jas_dioxus's `effects.rs::value_to_json` takes the other
    /// road: `1e30 as i64` saturates to `i64::MAX`, whose `as f64` is 2^63 and
    /// so is NOT equal to 1e30, and the value stays a JSON float. The reference
    /// interpreter's `set_panel_state` stores the evaluated value with no
    /// integer step at all. Both therefore store a float, which is what
    /// `intIfIntegral` returning nil makes this port do.
    @Test func setPanelStateStoresAHugeIntegralValueAsADouble() {
        let store = StateStore()
        store.initPanel("stroke_panel", defaults: ["probe": 0])
        store.setActivePanel("stroke_panel")
        runEffects(
            [["set_panel_state": ["key": "probe",
                                  "value": "1000000000000000000000000000000"]]],
            ctx: [:], store: store
        )
        #expect(store.getPanel("stroke_panel", "probe") as? Double == 1e30)
        #expect(store.getPanel("stroke_panel", "probe") as? Int == nil)
    }

    /// The same bridge on the dialog side (`valueToAnyDlg`), reached through the
    /// param-expression pass of `openYamlDialog`. `rotate_options` is used only
    /// because it exists in the bundle and its own init does not read `probe`.
    @Test func dialogParamsBridgeAHugeIntegralValueAsADouble() {
        let dlg = openYamlDialog(
            dialogId: "rotate_options",
            rawParams: ["probe": "1000000000000000000000000000000"],
            liveState: [:]
        )
        #expect(dlg != nil)
        #expect(dlg?.params["probe"] as? Double == 1e30)
        #expect(dlg?.params["probe"] as? Int == nil)
    }

    /// The bridge must still narrow an ordinary integral number, in both
    /// places — a fix that returned the Double unconditionally would pass the
    /// two cases above and change every small integer the panels and dialogs
    /// store.
    @Test func bothBridgesStillNarrowSmallIntegralValues() {
        let store = StateStore()
        store.initPanel("stroke_panel", defaults: ["probe": 0])
        store.setActivePanel("stroke_panel")
        runEffects(
            [["set_panel_state": ["key": "probe", "value": "4"]]],
            ctx: [:], store: store
        )
        #expect(store.getPanel("stroke_panel", "probe") as? Int == 4)

        let dlg = openYamlDialog(dialogId: "rotate_options",
                                 rawParams: ["probe": "4"], liveState: [:])
        #expect(dlg?.params["probe"] as? Int == 4)
    }
}
