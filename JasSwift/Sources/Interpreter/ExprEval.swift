/// Combined lexer, parser, and evaluator for the expression language.
///
/// Public API:
///   evaluate(_:context:)   — evaluate a single expression
///   evaluateText(_:context:) — interpolate {{expr}} in text
///
/// Matches the Rust implementation semantics exactly.

import Foundation

// MARK: - Public API

/// Evaluate an expression string against a context.
/// Returns `.null` for empty or unparseable input.
func evaluate(_ expr: String, context: [String: Any]) -> Value {
    if expr.isEmpty { return .null }
    guard let ast = parseExpr(expr) else { return .null }
    return evalNode(ast, context)
}

/// Evaluate a text string with embedded {{expr}} regions.
/// Returns the string with each {{expr}} replaced by its evaluated
/// value coerced to a string.
func evaluateText(_ text: String, context: [String: Any]) -> String {
    guard text.contains("{{") else { return text }
    var result = ""
    var rest = text[text.startIndex...]
    while let startRange = rest.range(of: "{{") {
        result += rest[rest.startIndex..<startRange.lowerBound]
        let afterOpen = rest[startRange.upperBound...]
        if let endRange = afterOpen.range(of: "}}") {
            let exprStr = String(afterOpen[afterOpen.startIndex..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let val = evaluate(exprStr, context: context)
            result += val.toStringCoerce()
            rest = afterOpen[endRange.upperBound...]
        } else {
            result += String(rest[startRange.lowerBound...])
            return result
        }
    }
    result += rest
    return result
}

// MARK: - Tokens

private enum TokenKind: Equatable {
    case ident(String)
    case number(Double)
    case str(String)
    case color(String)
    case `true`
    case `false`
    case null
    case not
    case and
    case or
    case `in`
    case eq       // ==
    case neq      // !=
    case lt       // <
    case gt       // >
    case lte      // <=
    case gte      // >=
    case question
    case colon
    case dot
    case comma
    case lParen
    case rParen
    case lBracket
    case rBracket
    case eof
    case error(String)
}

private struct Token {
    let kind: TokenKind
}

// MARK: - Tokenizer

private func tokenize(_ source: String) -> [Token] {
    var tokens: [Token] = []
    let chars = Array(source)
    let n = chars.count
    var i = 0

    while i < n {
        let c = chars[i]

        // Whitespace
        if c == " " || c == "\t" {
            i += 1
            continue
        }

        // Color literal: #rrggbb or #rgb
        if c == "#" {
            var j = i + 1
            while j < n && chars[j].isHexDigit {
                j += 1
            }
            let hexLen = j - i - 1
            if hexLen == 3 || hexLen == 6 {
                let s = String(chars[i..<j]).lowercased()
                tokens.append(Token(kind: .color(s)))
                i = j
                continue
            }
            let s = String(chars[i..<j])
            tokens.append(Token(kind: .error(s)))
            i = j
            continue
        }

        // String literal
        if c == "\"" {
            var j = i + 1
            var parts = ""
            while j < n && chars[j] != "\"" {
                if chars[j] == "\\" && j + 1 < n {
                    parts.append(chars[j + 1])
                    j += 2
                } else {
                    parts.append(chars[j])
                    j += 1
                }
            }
            if j < n { j += 1 }  // consume closing "
            tokens.append(Token(kind: .str(parts)))
            i = j
            continue
        }

        // Number (including negative)
        if c.isNumber || (c == "-" && i + 1 < n && chars[i + 1].isNumber) {
            let start = i
            if c == "-" { i += 1 }
            while i < n && chars[i].isNumber { i += 1 }
            if i < n && chars[i] == "." {
                i += 1
                while i < n && chars[i].isNumber { i += 1 }
            }
            let s = String(chars[start..<i])
            tokens.append(Token(kind: .number(Double(s) ?? 0.0)))
            continue
        }

        // Identifier / keyword
        if c.isLetter || c == "_" {
            let start = i
            while i < n && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                i += 1
            }
            let word = String(chars[start..<i])
            let kind: TokenKind
            switch word {
            case "true": kind = .true
            case "false": kind = .false
            case "null": kind = .null
            case "not": kind = .not
            case "and": kind = .and
            case "or": kind = .or
            case "in": kind = .in
            default: kind = .ident(word)
            }
            tokens.append(Token(kind: kind))
            continue
        }

        // Two-character operators
        if i + 1 < n {
            let two = String(chars[i...i+1])
            switch two {
            case "==": tokens.append(Token(kind: .eq)); i += 2; continue
            case "!=": tokens.append(Token(kind: .neq)); i += 2; continue
            case "<=": tokens.append(Token(kind: .lte)); i += 2; continue
            case ">=": tokens.append(Token(kind: .gte)); i += 2; continue
            default: break
            }
        }

        // Single-character operators
        switch c {
        case "<": tokens.append(Token(kind: .lt))
        case ">": tokens.append(Token(kind: .gt))
        case "?": tokens.append(Token(kind: .question))
        case ":": tokens.append(Token(kind: .colon))
        case ".": tokens.append(Token(kind: .dot))
        case ",": tokens.append(Token(kind: .comma))
        case "(": tokens.append(Token(kind: .lParen))
        case ")": tokens.append(Token(kind: .rParen))
        case "[": tokens.append(Token(kind: .lBracket))
        case "]": tokens.append(Token(kind: .rBracket))
        default: tokens.append(Token(kind: .error(String(c))))
        }
        i += 1
    }

    tokens.append(Token(kind: .eof))
    return tokens
}

// MARK: - AST

/// Binary comparison / membership operator.
private enum BinOp {
    case eq, neq, lt, gt, lte, gte, `in`
}

/// Literal value kind.
private enum LiteralKind {
    case number(Double)
    case str(String)
    case color(String)
    case bool(Bool)
    case null
}

/// Expression AST node.
private indirect enum Expr {
    case literal(LiteralKind)
    case path([String])
    case funcCall(name: String, args: [Expr])
    case dotAccess(obj: Expr, member: String)
    case indexAccess(obj: Expr, index: Expr)
    case binaryOp(op: BinOp, left: Expr, right: Expr)
    case unaryNot(Expr)
    case ternary(cond: Expr, trueExpr: Expr, falseExpr: Expr)
    case logicalAnd(Expr, Expr)
    case logicalOr(Expr, Expr)
}

// MARK: - Parser

private class Parser {
    let tokens: [Token]
    var pos: Int = 0

    init(_ tokens: [Token]) {
        self.tokens = tokens
    }

    func peek() -> TokenKind {
        tokens[pos].kind
    }

    @discardableResult
    func advance() -> TokenKind {
        let kind = tokens[pos].kind
        pos += 1
        return kind
    }

    @discardableResult
    func expect(_ expected: TokenKind) -> Bool {
        if discriminant(peek()) == discriminant(expected) {
            pos += 1
            return true
        }
        return false
    }

    func at(_ kind: TokenKind) -> Bool {
        discriminant(peek()) == discriminant(kind)
    }

    /// Compare token kinds ignoring associated values.
    private func discriminant(_ kind: TokenKind) -> String {
        switch kind {
        case .ident: return "ident"
        case .number: return "number"
        case .str: return "str"
        case .color: return "color"
        case .true: return "true"
        case .false: return "false"
        case .null: return "null"
        case .not: return "not"
        case .and: return "and"
        case .or: return "or"
        case .in: return "in"
        case .eq: return "eq"
        case .neq: return "neq"
        case .lt: return "lt"
        case .gt: return "gt"
        case .lte: return "lte"
        case .gte: return "gte"
        case .question: return "question"
        case .colon: return "colon"
        case .dot: return "dot"
        case .comma: return "comma"
        case .lParen: return "lParen"
        case .rParen: return "rParen"
        case .lBracket: return "lBracket"
        case .rBracket: return "rBracket"
        case .eof: return "eof"
        case .error: return "error"
        }
    }

    // MARK: - Grammar rules

    func parse() -> Expr? {
        if case .eof = peek() { return nil }
        let node = parseTernary()
        // Ignore trailing tokens
        return node
    }

    /// ternary = or_expr ( '?' expr ':' expr )?
    func parseTernary() -> Expr {
        let node = parseOr()
        if case .question = peek() {
            pos += 1
            let trueExpr = parseTernary()
            expect(.colon)
            let falseExpr = parseTernary()
            return .ternary(cond: node, trueExpr: trueExpr, falseExpr: falseExpr)
        }
        return node
    }

    /// or_expr = and_expr ( 'or' and_expr )*
    func parseOr() -> Expr {
        var node = parseAnd()
        while case .or = peek() {
            pos += 1
            let right = parseAnd()
            node = .logicalOr(node, right)
        }
        return node
    }

    /// and_expr = not_expr ( 'and' not_expr )*
    func parseAnd() -> Expr {
        var node = parseNot()
        while case .and = peek() {
            pos += 1
            let right = parseNot()
            node = .logicalAnd(node, right)
        }
        return node
    }

    /// not_expr = 'not' not_expr | comparison
    func parseNot() -> Expr {
        if case .not = peek() {
            pos += 1
            let operand = parseNot()
            return .unaryNot(operand)
        }
        return parseComparison()
    }

    /// comparison = primary ( comp_op primary )?
    func parseComparison() -> Expr {
        let node = parsePrimary()
        let op: BinOp?
        switch peek() {
        case .eq: op = .eq
        case .neq: op = .neq
        case .lt: op = .lt
        case .gt: op = .gt
        case .lte: op = .lte
        case .gte: op = .gte
        case .in: op = .in
        default: op = nil
        }
        if let op = op {
            pos += 1
            let right = parsePrimary()
            return .binaryOp(op: op, left: node, right: right)
        }
        return node
    }

    /// primary = atom accessor*
    /// accessor = '.' IDENT | '.' NUMBER | '[' expr ']'
    func parsePrimary() -> Expr {
        var node = parseAtom()
        while true {
            if case .dot = peek() {
                pos += 1
                switch peek() {
                case .ident(let name):
                    pos += 1
                    node = extendOrDot(node, name)
                case .true:
                    pos += 1
                    node = extendOrDot(node, "true")
                case .false:
                    pos += 1
                    node = extendOrDot(node, "false")
                case .null:
                    pos += 1
                    node = extendOrDot(node, "null")
                case .not:
                    pos += 1
                    node = extendOrDot(node, "not")
                case .and:
                    pos += 1
                    node = extendOrDot(node, "and")
                case .or:
                    pos += 1
                    node = extendOrDot(node, "or")
                case .in:
                    pos += 1
                    node = extendOrDot(node, "in")
                case .number(let n):
                    // Integer index after dot (e.g. list.0)
                    pos += 1
                    let seg = "\(Int(n))"
                    node = extendOrDot(node, seg)
                default:
                    break  // unexpected token after dot
                }
            } else if case .lBracket = peek() {
                pos += 1
                let indexExpr = parseTernary()
                expect(.rBracket)
                node = .indexAccess(obj: node, index: indexExpr)
            } else {
                break
            }
        }
        return node
    }

    /// If node is a Path, extend it; otherwise create a DotAccess.
    func extendOrDot(_ node: Expr, _ member: String) -> Expr {
        if case .path(var segs) = node {
            segs.append(member)
            return .path(segs)
        }
        return .dotAccess(obj: node, member: member)
    }

    /// atom = IDENT '(' args? ')' | IDENT | literal | '(' expr ')'
    func parseAtom() -> Expr {
        switch peek() {
        case .ident(let name):
            pos += 1
            // Check for function call: IDENT '('
            if case .lParen = peek() {
                pos += 1
                var args: [Expr] = []
                if case .rParen = peek() {
                    // no args
                } else {
                    args.append(parseTernary())
                    while case .comma = peek() {
                        pos += 1
                        args.append(parseTernary())
                    }
                }
                expect(.rParen)
                return .funcCall(name: name, args: args)
            }
            return .path([name])

        case .number(let n):
            pos += 1
            return .literal(.number(n))

        case .str(let s):
            pos += 1
            return .literal(.str(s))

        case .color(let c):
            pos += 1
            return .literal(.color(c))

        case .true:
            pos += 1
            return .literal(.bool(true))

        case .false:
            pos += 1
            return .literal(.bool(false))

        case .null:
            pos += 1
            return .literal(.null)

        case .lParen:
            pos += 1
            let node = parseTernary()
            expect(.rParen)
            return node

        default:
            // Unexpected token -- return null literal as fallback.
            return .literal(.null)
        }
    }
}

/// Parse an expression string into an AST node. Returns nil for empty input.
private func parseExpr(_ source: String) -> Expr? {
    let tokens = tokenize(source)
    let parser = Parser(tokens)
    return parser.parse()
}

// MARK: - Evaluator

/// Evaluate an AST node against a context.
private func evalNode(_ node: Expr, _ ctx: [String: Any]) -> Value {
    switch node {
    case .literal(let lit):
        return evalLiteral(lit)
    case .path(let segs):
        return evalPath(segs, ctx)
    case .funcCall(let name, let args):
        return evalFunc(name, args, ctx)
    case .dotAccess(let obj, let member):
        return evalDotAccess(obj, member, ctx)
    case .indexAccess(let obj, let index):
        return evalIndexAccess(obj, index, ctx)
    case .binaryOp(let op, let left, let right):
        return evalBinary(op, left, right, ctx)
    case .unaryNot(let operand):
        return evalUnaryNot(operand, ctx)
    case .ternary(let cond, let trueExpr, let falseExpr):
        return evalTernary(cond, trueExpr, falseExpr, ctx)
    case .logicalAnd(let left, let right):
        return evalLogicalAnd(left, right, ctx)
    case .logicalOr(let left, let right):
        return evalLogicalOr(left, right, ctx)
    }
}

// MARK: - Literals

private func evalLiteral(_ lit: LiteralKind) -> Value {
    switch lit {
    case .number(let n): return .number(n)
    case .str(let s): return .string(s)
    case .color(let c): return Value.colorValue(c)
    case .bool(let b): return .bool(b)
    case .null: return .null
    }
}

// MARK: - Path resolution

private func evalPath(_ segments: [String], _ ctx: [String: Any]) -> Value {
    guard !segments.isEmpty else { return .null }

    let namespace = segments[0]
    guard var obj = ctx[namespace] else { return .null }

    for seg in segments.dropFirst() {
        if let dict = obj as? [String: Any] {
            guard let next = dict[seg] else { return .null }
            obj = next
        } else if let arr = obj as? [Any] {
            // Try numeric index first
            if let idx = Int(seg), idx >= 0 && idx < arr.count {
                obj = arr[idx]
            } else if seg == "length" {
                return .number(Double(arr.count))
            } else {
                return .null
            }
        } else if let s = obj as? String {
            if seg == "length" {
                return .number(Double(s.count))
            }
            return .null
        } else {
            return .null
        }
    }

    return Value.fromJson(obj)
}

// MARK: - Dot access on computed values

private func evalDotAccess(_ objExpr: Expr, _ member: String, _ ctx: [String: Any]) -> Value {
    let objVal = evalNode(objExpr, ctx)

    // List .length
    if case .list(let arr) = objVal, member == "length" {
        return .number(Double(arr.count))
    }

    // String .length
    if case .string(let s) = objVal, member == "length" {
        return .number(Double(s.count))
    }

    // Dict property access -- Str that is actually serialised JSON object
    if case .string(let s) = objVal {
        if let data = s.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = json[member] {
            return Value.fromJson(v)
        }
    }

    // List numeric index via dot (e.g. computed_list.0)
    if case .list(let arr) = objVal {
        if let idx = Int(member), idx >= 0 && idx < arr.count {
            return Value.fromJson(arr[idx].value)
        }
    }

    return .null
}

// MARK: - Index access

private func evalIndexAccess(_ objExpr: Expr, _ indexExpr: Expr, _ ctx: [String: Any]) -> Value {
    let objVal = evalNode(objExpr, ctx)
    let idxVal = evalNode(indexExpr, ctx)
    let key = idxVal.toStringCoerce()

    // Dict-like access via serialised JSON object
    if case .string(let s) = objVal {
        if let data = s.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = json[key] {
            return Value.fromJson(v)
        }
    }

    // List numeric index
    if case .list(let arr) = objVal {
        if let idx = Int(key), idx >= 0 && idx < arr.count {
            return Value.fromJson(arr[idx].value)
        }
    }

    return .null
}

// MARK: - Function calls

/// Extract a hex color string from a Value for color functions.
private func colorArg(_ val: Value) -> String {
    switch val {
    case .color(let c): return c
    case .string(let s): return s
    case .null: return "#000000"
    default: return "#000000"
    }
}

private func valToUInt8(_ v: Value) -> UInt8 {
    if case .number(let n) = v { return UInt8(clamping: Int(n)) }
    return 0
}

private func valToDouble(_ v: Value) -> Double {
    if case .number(let n) = v { return n }
    return 0.0
}

private func evalFunc(_ name: String, _ args: [Expr], _ ctx: [String: Any]) -> Value {
    // Color decomposition: single color argument -> number
    typealias DecomposeFunc = (UInt8, UInt8, UInt8) -> Int

    let decompose: DecomposeFunc? = {
        switch name {
        case "hsb_h": return { r, g, b in rgbToHsb(r, g, b).0 }
        case "hsb_s": return { r, g, b in rgbToHsb(r, g, b).1 }
        case "hsb_b": return { r, g, b in rgbToHsb(r, g, b).2 }
        case "rgb_r": return { r, _, _ in Int(r) }
        case "rgb_g": return { _, g, _ in Int(g) }
        case "rgb_b": return { _, _, b in Int(b) }
        case "cmyk_c": return { r, g, b in rgbToCmyk(r, g, b).0 }
        case "cmyk_m": return { r, g, b in rgbToCmyk(r, g, b).1 }
        case "cmyk_y": return { r, g, b in rgbToCmyk(r, g, b).2 }
        case "cmyk_k": return { r, g, b in rgbToCmyk(r, g, b).3 }
        default: return nil
        }
    }()

    if let func_ = decompose {
        guard args.count == 1 else { return .number(0.0) }
        let arg = evalNode(args[0], ctx)
        let c = colorArg(arg)
        let (r, g, b) = parseHex(c)
        return .number(Double(func_(r, g, b)))
    }

    switch name {
    // hex: color -> string (6 hex digits without #)
    case "hex":
        guard args.count == 1 else { return .string("") }
        let arg = evalNode(args[0], ctx)
        let c = colorArg(arg)
        let (r, g, b) = parseHex(c)
        return .string(String(format: "%02x%02x%02x", r, g, b))

    // rgb: (r, g, b) -> color
    case "rgb":
        guard args.count == 3 else { return .null }
        let vals = args.map { evalNode($0, ctx) }
        let r = valToUInt8(vals[0])
        let g = valToUInt8(vals[1])
        let b = valToUInt8(vals[2])
        return Value.colorValue(rgbToHex(r, g, b))

    // hsb: (h, s, b) -> color
    case "hsb":
        guard args.count == 3 else { return .null }
        let vals = args.map { evalNode($0, ctx) }
        let h = valToDouble(vals[0])
        let s = valToDouble(vals[1])
        let bv = valToDouble(vals[2])
        let (r, g, b) = hsbToRgb(h, s, bv)
        return Value.colorValue(rgbToHex(r, g, b))

    // invert: color -> color
    case "invert":
        guard args.count == 1 else { return .null }
        let arg = evalNode(args[0], ctx)
        let c = colorArg(arg)
        let (r, g, b) = parseHex(c)
        return Value.colorValue(rgbToHex(255 - r, 255 - g, 255 - b))

    // complement: color -> color (rotate hue 180 degrees)
    case "complement":
        guard args.count == 1 else { return .null }
        let arg = evalNode(args[0], ctx)
        let c = colorArg(arg)
        let (r, g, b) = parseHex(c)
        let (h, s, bv) = rgbToHsb(r, g, b)
        if s == 0 {
            return Value.colorValue(rgbToHex(r, g, b))
        }
        let newH = (h + 180) % 360
        let (nr, ng, nb) = hsbToRgb(Double(newH), Double(s), Double(bv))
        return Value.colorValue(rgbToHex(nr, ng, nb))

    // Unknown function
    default:
        return .null
    }
}

// MARK: - Binary operators

private func evalBinary(_ op: BinOp, _ left: Expr, _ right: Expr, _ ctx: [String: Any]) -> Value {
    let lv = evalNode(left, ctx)
    let rv = evalNode(right, ctx)

    switch op {
    case .eq: return .bool(lv.strictEq(rv))
    case .neq: return .bool(!lv.strictEq(rv))
    case .lt: return numericCmp(lv, rv) { $0 < $1 }
    case .gt: return numericCmp(lv, rv) { $0 > $1 }
    case .lte: return numericCmp(lv, rv) { $0 <= $1 }
    case .gte: return numericCmp(lv, rv) { $0 >= $1 }
    case .in: return evalIn(lv, rv)
    }
}

private func numericCmp(_ left: Value, _ right: Value, _ f: (Double, Double) -> Bool) -> Value {
    if case .number(let a) = left, case .number(let b) = right {
        return .bool(f(a, b))
    }
    return .bool(false)
}

private func evalIn(_ left: Value, _ right: Value) -> Value {
    if case .list(let arr) = right {
        for item in arr {
            let itemVal = Value.fromJson(item.value)
            if left.strictEq(itemVal) {
                return .bool(true)
            }
        }
    }
    return .bool(false)
}

// MARK: - Unary not

private func evalUnaryNot(_ operand: Expr, _ ctx: [String: Any]) -> Value {
    let val = evalNode(operand, ctx)
    return .bool(!val.toBool())
}

// MARK: - Ternary

private func evalTernary(_ cond: Expr, _ trueExpr: Expr, _ falseExpr: Expr, _ ctx: [String: Any]) -> Value {
    let condVal = evalNode(cond, ctx)
    if condVal.toBool() {
        return evalNode(trueExpr, ctx)
    } else {
        return evalNode(falseExpr, ctx)
    }
}

// MARK: - Logical operators (short-circuit)

private func evalLogicalAnd(_ left: Expr, _ right: Expr, _ ctx: [String: Any]) -> Value {
    let lv = evalNode(left, ctx)
    if !lv.toBool() { return lv }
    return evalNode(right, ctx)
}

private func evalLogicalOr(_ left: Expr, _ right: Expr, _ ctx: [String: Any]) -> Value {
    let lv = evalNode(left, ctx)
    if lv.toBool() { return lv }
    return evalNode(right, ctx)
}
