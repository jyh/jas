import Testing
import Foundation
@testable import JasLib

// The Gradient panel's stop-edit law (Swift arm). Runs
// test_fixtures/gradient_stop/stop_edit.json, which the reference
// (workspace_interpreter/gradient_law.py) and Rust (cross_language_test.rs)
// read too. `editStop` mirrors `gradient_host::edit_stop`.

private func gradientStopCorpus(_ file: String = "gradient_stop/stop_edit.json") -> [[String: Any]] {
    let testsDir = ((#filePath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    let jasSwiftDir = (testsDir as NSString).deletingLastPathComponent
    let fixtures = (jasSwiftDir as NSString).appendingPathComponent("../test_fixtures")
    let path = ((fixtures as NSString)
        .appendingPathComponent(file) as NSString).standardizingPath
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

// The Gradient slider's law (Swift arm). Runs
// test_fixtures/gradient_stop/slider.json, which the reference and Rust read
// too. The five functions mirror `gradient_host.rs`.
@Test func gradientSliderCorpus() {
    var ran: [String: (refused: Int, written: Int)] = [:]
    for vec in gradientStopCorpus("gradient_stop/slider.json") {
        let name = vec["name"] as! String
        let op = vec["op"] as! String
        let stops = (vec["stops"] as! [Any]).map(stop)
        let int = { (k: String) in (vec[k] as! NSNumber).intValue }
        // Every op's result as (stops, selected stop or nil).
        let got: ([GradientStop], Int?)?
        switch op {
        case "add_stop": got = addStop(stops, location: vec["location"]).map { ($0.0, $0.1) }
        case "delete_stop": got = deleteStop(stops, index: int("index")).map { ($0.0, $0.1) }
        case "drag_stop":
            got = dragStop(stops, index: int("index"), location: vec["location"], dy: vec["dy"]).map { ($0.0, $0.1) }
        case "set_midpoint": got = setMidpoint(stops, pair: int("pair"), value: vec["value"]).map { ($0, nil) }
        case "drag_midpoint": got = dragMidpoint(stops, pair: int("pair"), location: vec["location"]).map { ($0, nil) }
        default: Issue.record("gradient_slider '\(name)': unknown op \(op)"); continue
        }
        var tally = ran[op] ?? (0, 0)
        if let expected = vec["expected"] as? [String: Any] {
            guard let (out, idx) = got else {
                Issue.record("gradient_slider '\(name)': refused"); continue
            }
            #expect(out == (expected["stops"] as! [Any]).map(stop), "gradient_slider '\(name)': stops")
            #expect(idx == (expected["index"] as? NSNumber)?.intValue, "gradient_slider '\(name)': index")
            tally.written += 1
        } else {
            #expect(got == nil, "gradient_slider '\(name)': must refuse")
            tally.refused += 1
        }
        ran[op] = tally
    }
    // Every op witnessed refusing and writing, as the reference requires.
    #expect(ran.count == 5, "ops run: \(ran.keys.sorted())")
    for (op, t) in ran {
        #expect(t.refused >= 1 && t.written >= 3, "corpus too thin for \(op): \(t.refused) refused, \(t.written) written")
    }
}
