/// Value types for the expression language.
///
/// The seven value types: null, bool, number, string, color, list, closure.
/// Matches the Python reference implementation semantics.

import Foundation

/// The value types in the expression language.
enum Value: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case color(String)  // normalized #rrggbb
    case list([AnyJSON])
    /// Opaque document path (Phase 3 §6.2). Non-negative indices.
    case path([Int])
    case closure(params: [String], body: Expr, capturedCtx: [String: Any])

    /// Normalize a color string: 3-digit -> 6-digit, lowercase.
    static func colorValue(_ s: String) -> Value {
        let s = s.lowercased()
        if s.count == 4 && s.hasPrefix("#") {
            let chars = Array(s)
            let expanded = "#\(chars[1])\(chars[1])\(chars[2])\(chars[2])\(chars[3])\(chars[3])"
            return .color(expanded)
        }
        return .color(s)
    }

    /// Convert a JSON value (Any?) to a typed Value.
    static func fromJson(_ v: Any?) -> Value {
        guard let v = v else { return .null }

        // NSNumber must be checked BEFORE the bare `as? Bool`: in Swift an
        // NSNumber(0) / NSNumber(1) (how JSONSerialization boxes the integers 0
        // and 1) ALSO satisfies `as? Bool` (bridging 0→false, 1→true), so a bare
        // Bool cast first would misread a JSON integer 0 as `false`. The objCType
        // encoding (`c` / `B` ⇒ CFBoolean) is the correct bool-vs-number
        // discriminator — a real JSON boolean still routes here. (Exposed by the
        // concept-fitter corpus: vertices with a literal `0` coordinate, e.g.
        // [10, 0], indexed via `p[1]`.)
        if let n = v as? NSNumber {
            let objCType = String(cString: n.objCType)
            if objCType == "c" || objCType == "B" {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        }
        if let b = v as? Bool {
            return .bool(b)
        }
        if let n = v as? Int {
            return .number(Double(n))
        }
        if let n = v as? Double {
            return .number(n)
        }
        if let s = v as? String {
            // Detect hex color patterns
            if s.hasPrefix("#") && (s.count == 4 || s.count == 7) {
                let hex = String(s.dropFirst())
                if hex.allSatisfy({ $0.isHexDigit }) {
                    return colorValue(s)
                }
            }
            return .string(s)
        }
        if let arr = v as? [Any] {
            return .list(arr.map { AnyJSON($0) })
        }
        if let dict = v as? [String: Any] {
            // Path round-trip: recognize {"__path__": [i, j, ...]} marker
            if dict.count == 1, let arr = dict["__path__"] as? [Any] {
                var idx: [Int] = []
                for n in arr {
                    if let i = n as? Int {
                        idx.append(i)
                    } else if let d = n as? Double {
                        idx.append(Int(d))
                    } else if let num = n as? NSNumber {
                        idx.append(num.intValue)
                    } else {
                        // Invalid path element; fall through to JSON-string path
                        if let data = try? JSONSerialization.data(withJSONObject: dict),
                           let str = String(data: data, encoding: .utf8) {
                            return .string(str)
                        }
                        return .null
                    }
                }
                return .path(idx)
            }
            // Keep as JSON string for property access
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let str = String(data: data, encoding: .utf8) {
                return .string(str)
            }
            return .null
        }
        return .null
    }

    /// Bool coercion per spec.
    func toBool() -> Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0.0
        case .string(let s): return !s.isEmpty
        case .color: return true
        case .list(let l): return !l.isEmpty
        case .path(let p): return !p.isEmpty
        case .closure: return true
        }
    }

    /// String coercion for text interpolation.
    func toStringCoerce() -> String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            return numberToCanonicalString(n)
        case .string(let s): return s
        case .color(let c): return c
        case .list: return "[list]"
        case .path(let p): return p.map { String($0) }.joined(separator: ".")
        case .closure: return "[closure]"
        }
    }

    /// Check if this value is null.
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Convert to Any for context injection. Returns nil for .null.
    func toAny() -> Any? {
        switch self {
        case .null: return nil
        case .bool(let b): return b
        case .number(let n):
            if n == Double(Int(n)) { return Int(n) }
            return n
        case .string(let s): return s
        case .color(let c): return c
        case .list(let l): return l.map { $0.value }
        case .path: return self  // keep as Value for path-typed context ops
        case .closure: return self  // keep as Value for closure dispatch
        }
    }

    /// Strict typed equality.
    func strictEq(_ other: Value) -> Bool {
        switch (self, other) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.number(let a), .number(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.color(let a), .color(let b)):
            return normalizeColor(a) == normalizeColor(b)
        case (.path(let a), .path(let b)):
            return a == b
        case (.closure, _), (_, .closure):
            return false  // closures are never equal
        default:
            return false  // different types -> false
        }
    }

    static func == (lhs: Value, rhs: Value) -> Bool {
        lhs.strictEq(rhs)
    }
}

/// Wrapper for Any values in lists so Value can conform to Equatable.
struct AnyJSON: Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    static func == (lhs: AnyJSON, rhs: AnyJSON) -> Bool {
        // Use JSON serialization for comparison
        if let lData = try? JSONSerialization.data(withJSONObject: [lhs.value]),
           let rData = try? JSONSerialization.data(withJSONObject: [rhs.value]),
           let lStr = String(data: lData, encoding: .utf8),
           let rStr = String(data: rData, encoding: .utf8) {
            return lStr == rStr
        }
        return false
    }
}

/// Normalize a color string for comparison.
private func normalizeColor(_ c: String) -> String {
    let c = c.lowercased()
    if c.count == 4 && c.hasPrefix("#") {
        let chars = Array(c)
        return "#\(chars[1])\(chars[1])\(chars[2])\(chars[2])\(chars[3])\(chars[3])"
    }
    return c
}

/// Expand a scientific-notation float string (e.g. "1e-05", "-1.23e+20") to
/// positional decimal — Rust's f64 Display never uses scientific notation.
private func sciToPositional(_ input: String) -> String {
    let neg = input.hasPrefix("-")
    let s = neg ? String(input.dropFirst()) : input
    guard let eIdx = s.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
        return neg ? "-" + s : s
    }
    let mant = String(s[s.startIndex..<eIdx])
    let exp = Int(s[s.index(after: eIdx)...]) ?? 0
    let intPart: String, fracPart: String
    if let dot = mant.firstIndex(of: ".") {
        intPart = String(mant[mant.startIndex..<dot])
        fracPart = String(mant[mant.index(after: dot)...])
    } else {
        intPart = mant
        fracPart = ""
    }
    let digits = intPart + fracPart
    let point = intPart.count + exp  // decimal-point offset from start of `digits`
    var out: String
    if point <= 0 {
        out = "0." + String(repeating: "0", count: -point) + digits
    } else if point >= digits.count {
        out = digits + String(repeating: "0", count: point - digits.count)
    } else {
        let idx = digits.index(digits.startIndex, offsetBy: point)
        out = String(digits[digits.startIndex..<idx]) + "." + String(digits[idx...])
    }
    if out.contains(".") {
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
    }
    if out.isEmpty { out = "0" }
    return (neg && out != "0") ? "-" + out : out
}

/// Coerce a number to a string, matching the Rust reference
/// (Value::to_string_coerce): integer-valued floats print as integers (any
/// magnitude — no Int64 overflow trap); other values use the shortest
/// round-trip decimal in positional, never scientific, notation. Keeps
/// {{ }} interpolation and string concatenation byte-identical across apps.
func numberToCanonicalString(_ n: Double) -> String {
    if n.isNaN { return "NaN" }
    if n == .infinity { return "inf" }
    if n == -.infinity { return "-inf" }
    if n == n.rounded(.towardZero) {  // integer-valued
        if n == 0 { return "0" }      // normalize -0.0
        return String(format: "%.0f", n)
    }
    let s = "\(n)"  // Swift's shortest round-trip description
    return (s.contains("e") || s.contains("E")) ? sciToPositional(s) : s
}
