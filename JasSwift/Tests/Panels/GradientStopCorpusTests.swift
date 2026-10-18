import Testing
import Foundation
@testable import JasLib

// The Gradient panel's stop-edit law (Swift arm). Runs
// test_fixtures/gradient_stop/stop_edit.json, which the reference
// (workspace_interpreter/gradient_law.py) and Rust (cross_language_test.rs)
// read too. `editStop` mirrors `gradient_host::edit_stop`.

private func gradientStopCorpus() -> [[String: Any]] {
    let testsDir = ((#filePath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    let jasSwiftDir = (testsDir as NSString).deletingLastPathComponent
    let path = ((jasSwiftDir as NSString)
        .appendingPathComponent("../test_fixtures/gradient_stop/stop_edit.json") as NSString).standardizingPath
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let vectors = obj["vectors"] as? [[String: Any]] else {
        fatalError("Failed to read gradient_stop corpus: \(path)")
    }
    return vectors
}

private func stop(_ d: Any) -> GradientStop {
    let s = d as! [String: Any]
    return GradientStop(color: s["color"] as! String,
                        opacity: (s["opacity"] as! NSNumber).doubleValue,
                        location: (s["location"] as! NSNumber).doubleValue,
                        midpointToNext: (s["midpoint_to_next"] as! NSNumber).doubleValue)
}

@Test func gradientStopEditCorpus() {
    var refused = 0, written = 0
    for vec in gradientStopCorpus() {
        let name = vec["name"] as! String
        let stops = (vec["stops"] as! [Any]).map(stop)
        let got = editStop(stops, index: (vec["index"] as! NSNumber).intValue,
                           field: vec["field"] as! String, value: vec["value"])
        if let expected = vec["expected"] as? [String: Any] {
            guard let (out, idx) = got else {
                Issue.record("gradient_stop '\(name)': refused"); continue
            }
            #expect(out == (expected["stops"] as! [Any]).map(stop), "gradient_stop '\(name)': stops")
            #expect(idx == (expected["index"] as! NSNumber).intValue, "gradient_stop '\(name)': index")
            written += 1
        } else {
            #expect(got == nil, "gradient_stop '\(name)': must refuse")
            refused += 1
        }
    }
    #expect(refused >= 3 && written >= 5, "corpus too thin: \(refused) refused, \(written) written")
}
