/// Consumes `test_fixtures/algorithms/align.json` entirely inside
/// `swift test` — Swift's Align algorithms must produce the same
/// translations as the Rust reference for every parity vector.
/// Future OCaml and native-Python ports will consume the same file.

import Foundation
import Testing
@testable import JasLib

@Test func alignFixtureMatchesExpected() {
    // Locate test_fixtures by walking up from the test binary's
    // source directory. Mirrors the cross-language Swift tests
    // that read SVG fixtures.
    let thisFile = URL(fileURLWithPath: #filePath)
    let projectRoot = thisFile
        .deletingLastPathComponent()  // Tests/Algorithms
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // JasSwift
        .deletingLastPathComponent()  // repo root
    let fixture = projectRoot.appendingPathComponent("test_fixtures/algorithms/align.json")
    guard let data = try? Data(contentsOf: fixture),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let vectors = json["vectors"] as? [[String: Any]] else {
        Issue.record("failed to read \(fixture.path)")
        return
    }
    for v in vectors {
        let name = v["name"] as? String ?? "<unnamed>"
        let op = v["op"] as? String ?? ""
        let rectsRaw = v["rects"] as? [[Double]] ?? []
        let rects: [Element] = rectsRaw.map {
            .rect(Rect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]))
        }
        let pairs: [(ElementPath, Element)] = rects.enumerated().map { (i, e) in ([i], e) }
        let usePreview = v["use_preview_bounds"] as? Bool ?? false
        let boundsFn: AlignBoundsFn = usePreview ? alignPreviewBounds : alignGeometricBounds
        let refRaw = v["reference"] as? [String: Any] ?? [:]
        let refKind = refRaw["kind"] as? String ?? "selection"
        let reference: AlignReference
        switch refKind {
        case "selection": reference = .selection(alignUnionBounds(rects, boundsFn))
        case "artboard":
            let bb = refRaw["bbox"] as? [Double] ?? [0, 0, 0, 0]
            reference = .artboard((bb[0], bb[1], bb[2], bb[3]))
        case "key_object":
            let idx = (refRaw["index"] as? NSNumber)?.intValue ?? 0
            reference = .keyObject(bbox: boundsFn(rects[idx]), path: [idx])
        default:
            Issue.record("vector \(name): unknown reference kind \(refKind)")
            continue
        }
        let explicitGap: Double? = (v["explicit_gap"] as? NSNumber)?.doubleValue
        let actual: [AlignTranslation]
        switch op {
        case "align_left": actual = alignLeft(pairs, reference, boundsFn)
        case "align_horizontal_center": actual = alignHorizontalCenter(pairs, reference, boundsFn)
        case "align_right": actual = alignRight(pairs, reference, boundsFn)
        case "align_top": actual = alignTop(pairs, reference, boundsFn)
        case "align_vertical_center": actual = alignVerticalCenter(pairs, reference, boundsFn)
        case "align_bottom": actual = alignBottom(pairs, reference, boundsFn)
        case "distribute_left": actual = distributeLeft(pairs, reference, boundsFn)
        case "distribute_horizontal_center": actual = distributeHorizontalCenter(pairs, reference, boundsFn)
        case "distribute_right": actual = distributeRight(pairs, reference, boundsFn)
        case "distribute_top": actual = distributeTop(pairs, reference, boundsFn)
        case "distribute_vertical_center": actual = distributeVerticalCenter(pairs, reference, boundsFn)
        case "distribute_bottom": actual = distributeBottom(pairs, reference, boundsFn)
        case "distribute_vertical_spacing":
            actual = distributeVerticalSpacing(pairs, reference, explicitGap, boundsFn)
        case "distribute_horizontal_spacing":
            actual = distributeHorizontalSpacing(pairs, reference, explicitGap, boundsFn)
        default:
            Issue.record("vector \(name): unknown op \(op)")
            continue
        }

        let expected = v["translations"] as? [[String: Any]] ?? []
        #expect(actual.count == expected.count,
                "vector \(name): translation count mismatch — got \(actual), want \(expected)")
        for (a, e) in zip(actual, expected) {
            let ePath = (e["path"] as? [Int]) ?? []
            let eDx = (e["dx"] as? NSNumber)?.doubleValue ?? 0
            let eDy = (e["dy"] as? NSNumber)?.doubleValue ?? 0
            #expect(a.path == ePath, "vector \(name): path mismatch")
            #expect(abs(a.dx - eDx) < 1e-4,
                    "vector \(name): dx on \(a.path): got \(a.dx), want \(eDx)")
            #expect(abs(a.dy - eDy) < 1e-4,
                    "vector \(name): dy on \(a.path): got \(a.dy), want \(eDy)")
        }
    }
}
