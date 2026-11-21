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

// The stop-colour law (row 198, Swift arm). Runs
// test_fixtures/gradient_stop/stop_color.json, which the reference and Rust
// read too. `setStopColor` mirrors `gradient_host::set_stop_color`.
@Test func gradientStopColorCorpus() {
    var refused = 0, written = 0
    for vec in gradientStopCorpus("gradient_stop/stop_color.json") {
        let name = vec["name"] as! String
        let stops = (vec["stops"] as! [Any]).map(stop)
        let got = setStopColor(stops, index: (vec["index"] as! NSNumber).intValue, color: vec["value"])
        if let expected = vec["expected"] as? [String: Any] {
            guard let (out, idx) = got else {
                Issue.record("stop_color '\(name)': refused"); continue
            }
            #expect(out == (expected["stops"] as! [Any]).map(stop), "stop_color '\(name)': stops")
            #expect(idx == (expected["index"] as! NSNumber).intValue, "stop_color '\(name)': index")
            written += 1
        } else {
            #expect(got == nil, "stop_color '\(name)': must refuse")
            refused += 1
        }
    }
    #expect(refused >= 6 && written >= 2, "corpus too thin: \(refused) refused, \(written) written")
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

// The Gradient panel menu's three stop transforms (Swift arm). Runs
// test_fixtures/gradient_stop/menu_transform.json, which the reference
// (gradient_law.py) and Rust (cross_language_test.rs) read too, through the
// law and through the expression builtin the menu's YAML calls.

/// Numbers compare as numbers (the law writes Doubles; the fixture has ints).
private func sameJSON(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x as String, y as String): return x == y
    case let (x as NSNumber, y as NSNumber): return x.doubleValue == y.doubleValue
    case let (x as [Any], y as [Any]):
        return x.count == y.count && zip(x, y).allSatisfy { sameJSON($0, $1) }
    case let (x as [String: Any], y as [String: Any]):
        return x.count == y.count && x.allSatisfy { k, v in y[k].map { sameJSON(v, $0) } ?? false }
    default: return false
    }
}

@Test func gradientMenuTransformCorpus() {
    let ops: [String: (law: (Any?) -> [[String: Any]]?, builtin: String)] = [
        "reverse": (gradientReverseStops, "gradient_reversed"),
        "distribute": (gradientDistributeStops, "gradient_distributed"),
        "reset_midpoints": (gradientResetMidpoints, "gradient_midpoints_reset"),
    ]
    var ran: [String: (refused: Int, written: Int)] = [:]
    let vectors = gradientStopCorpus("gradient_stop/menu_transform.json")
    for vec in vectors {
        let name = vec["name"] as! String
        let op = vec["op"] as! String
        guard let (law, builtin) = ops[op] else {
            Issue.record("gradient_menu_transform '\(name)': unknown op \(op)"); continue
        }
        let got = law(vec["stops"])
        let viaExpr = evaluate("\(builtin)(panel.stops)", context: ["panel": ["stops": vec["stops"]!]])
        var counts = ran[op] ?? (0, 0)
        if let expected = vec["expected"] as? [Any] {
            #expect(got.map { sameJSON($0, expected) } ?? false,
                    "gradient_menu_transform '\(name)': law \(String(describing: got))")
            if case .list(let items) = viaExpr {
                #expect(sameJSON(items.map(\.value), expected), "gradient_menu_transform '\(name)': builtin")
            } else {
                Issue.record("gradient_menu_transform '\(name)': builtin gave \(viaExpr)")
            }
            counts.written += 1
        } else {
            #expect(got == nil, "gradient_menu_transform '\(name)': the law must refuse")
            #expect(viaExpr == .null, "gradient_menu_transform '\(name)': the builtin must be null")
            counts.refused += 1
        }
        ran[op] = counts
    }
    #expect(ran.count == 3, "ops run: \(ran.keys.sorted())")
    for (op, c) in ran {
        #expect(c.refused >= 2 && c.written >= 2, "op \(op) too thin: \(c.refused) refused, \(c.written) written")
    }
    let ctx: [String: Any] = ["panel": ["stops": vectors[0]["stops"]!]]
    for (_, b) in ops.values {
        #expect(evaluate("\(b)()", context: ctx) == .null, "\(b)()")
        #expect(evaluate("\(b)(panel.stops, panel.stops)", context: ctx) == .null, "\(b)(a, b)")
    }
}
