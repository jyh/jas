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

    // MARK: - Calligraphic outline sample count

    /// `sampleLine`'s `if len == 0.0` bail is false for a NaN length, so a NaN
    /// coordinate reaches the sample-count conversion. jas_dioxus's
    /// `(len / SAMPLE_INTERVAL_PT).ceil() as u32` is 0 for NaN and `.max(1)`
    /// lifts it to one interval, i.e. two samples and a four-point polygon;
    /// this port trapped. The point VALUES are NaN in both ports — the count is
    /// the whole of what agrees, so the count is all this checks.
    ///
    /// Mirrored in jas_dioxus by
    /// `algorithms::calligraphic_outline::tests::nan_coordinate_yields_two_samples`.
    /// There is no corpus family for this algorithm (it has no entry in
    /// cross_language_algorithms.py's ALGORITHMS dict and no roundtrip arm in
    /// either port's CLI), so the gate is a matched pair of unit tests.
    @Test func calligraphicOutlineSurvivesANaNCoordinate() {
        let brush = CalligraphicBrush(angle: 0, roundness: 100, size: 4)
        let pts = calligraphicOutline([.moveTo(0, 0), .lineTo(.nan, 0)], brush)
        #expect(pts.count == 4)
    }

    /// A finite length still gets one sample per SAMPLE_INTERVAL_PT: 10pt is 10
    /// intervals, 11 samples, 22 polygon points. Pins the same expression's
    /// ordinary arm so a "fix" cannot collapse every stroke to one interval.
    @Test func calligraphicOutlineStillSamplesAFiniteLine() {
        let brush = CalligraphicBrush(angle: 0, roundness: 100, size: 4)
        let pts = calligraphicOutline([.moveTo(0, 0), .lineTo(10, 0)], brush)
        #expect(pts.count == 22)
    }

    // MARK: - Paragraph hyphenation fields

    /// The four hyphenation call sites in `buildParagraphSegments`, all in one
    /// segment. Two of the four are pinned by a VALUE and two by the trap:
    ///
    ///   jas:hyphenate-min-word   = nan  -> Rust `nan as usize` is 0; `Int(nan)` trapped
    ///   jas:hyphenate-min-before = -1   -> Rust `-1.0 as usize` is 0; `Int(-1.0)` was -1
    ///   jas:hyphenate-min-after  = nan  -> as min-word
    ///   jas:hyphenate-bias       = 300  -> Rust `300.0 as u8` is 255; this stored 300
    ///
    /// The Rust expressions are text_layout_paragraph.rs's
    /// `t.jas_hyphenate_min_word.unwrap_or(6.0) as usize` and
    /// `t.jas_hyphenate_bias.unwrap_or(0.0) as u8`. The values reach a document
    /// through the SVG attribute readers, which are `Double(string) ?? default`
    /// here and `parse::<f64>()` there and accept "nan".
    ///
    /// The `text_layout_paragraph` corpus family cannot host this: its vectors
    /// supply already-built `paragraphs` segments, so it never runs the
    /// Tspan-to-Int conversion these four sites are.
    @Test func paragraphHyphenationFieldsSaturateLikeRust() {
        let segs = buildParagraphSegments(
            tspans: [
                Tspan(id: 0, content: "", jasRole: "paragraph",
                      jasHyphenateMinWord: .nan,
                      jasHyphenateMinBefore: -1,
                      jasHyphenateMinAfter: .nan,
                      jasHyphenateBias: 300),
                Tspan(id: 1, content: "hello"),
            ],
            content: "hello", isArea: true)
        #expect(segs.count == 1)
        #expect(segs[0].hyphenateMinWord == 0)
        #expect(segs[0].hyphenateMinBefore == 0)
        #expect(segs[0].hyphenateMinAfter == 0)
        #expect(segs[0].hyphenateBias == 255)
    }

    /// The ordinary arm of the same four sites: an in-range value passes
    /// through, so a "fix" cannot zero the fields it was meant to protect.
    @Test func paragraphHyphenationFieldsPassInRangeValues() {
        let segs = buildParagraphSegments(
            tspans: [
                Tspan(id: 0, content: "", jasRole: "paragraph",
                      jasHyphenateMinWord: 7,
                      jasHyphenateMinBefore: 3,
                      jasHyphenateMinAfter: 4,
                      jasHyphenateBias: 42),
                Tspan(id: 1, content: "hello"),
            ],
            content: "hello", isArea: true)
        #expect(segs.count == 1)
        #expect(segs[0].hyphenateMinWord == 7)
        #expect(segs[0].hyphenateMinBefore == 3)
        #expect(segs[0].hyphenateMinAfter == 4)
        #expect(segs[0].hyphenateBias == 42)
    }
}
