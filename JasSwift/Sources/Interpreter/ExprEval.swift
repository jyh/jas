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
    case fun
    case `let`
    case ifKw
    case then
    case elseKw
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
    case arrow    // ->
    case larrow   // <-
    case semicolon // ;
    case equals   // =
    case plus     // +
    case minus    // -
    case star     // *
    case slash    // /
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

        // Whitespace (including newlines — YAML > and | folds may
        // embed newlines in expression strings)
        if c == " " || c == "\t" || c == "\n" || c == "\r" {
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

        // String literal (double or single quotes — matching Python / Rust)
        if c == "\"" || c == "'" {
            let quote = c
            var j = i + 1
            var parts = ""
            while j < n && chars[j] != quote {
                if chars[j] == "\\" && j + 1 < n {
                    parts.append(chars[j + 1])
                    j += 2
                } else {
                    parts.append(chars[j])
                    j += 1
                }
            }
            if j < n { j += 1 }  // consume closing quote
            tokens.append(Token(kind: .str(parts)))
            i = j
            continue
        }

        // Number (digits only — unary minus is handled as an operator)
        if c.isNumber {
            let start = i
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
            case "fun": kind = .fun
            case "let": kind = .let
            case "if": kind = .ifKw
            case "then": kind = .then
            case "else": kind = .elseKw
            default: kind = .ident(word)
            }
            tokens.append(Token(kind: kind))
            continue
        }

        // Multi-character operators (order matters)
        if c == "=" && i + 1 < n && chars[i + 1] == "=" {
            tokens.append(Token(kind: .eq)); i += 2; continue
        }
        if c == "!" && i + 1 < n && chars[i + 1] == "=" {
            tokens.append(Token(kind: .neq)); i += 2; continue
        }
        // <- : no space between < and - (greedy)
        if c == "<" && i + 1 < n && chars[i + 1] == "-" {
            tokens.append(Token(kind: .larrow)); i += 2; continue
        }
        if c == "<" && i + 1 < n && chars[i + 1] == "=" {
            tokens.append(Token(kind: .lte)); i += 2; continue
        }
        if c == ">" && i + 1 < n && chars[i + 1] == "=" {
            tokens.append(Token(kind: .gte)); i += 2; continue
        }
        // -> : no space between - and > (greedy)
        if c == "-" && i + 1 < n && chars[i + 1] == ">" {
            tokens.append(Token(kind: .arrow)); i += 2; continue
        }

        // Single-character operators
        switch c {
        case "<": tokens.append(Token(kind: .lt))
        case ">": tokens.append(Token(kind: .gt))
        case "=": tokens.append(Token(kind: .equals))
        case "?": tokens.append(Token(kind: .question))
        case ":": tokens.append(Token(kind: .colon))
        case ".": tokens.append(Token(kind: .dot))
        case ",": tokens.append(Token(kind: .comma))
        case ";": tokens.append(Token(kind: .semicolon))
        case "(": tokens.append(Token(kind: .lParen))
        case ")": tokens.append(Token(kind: .rParen))
        case "[": tokens.append(Token(kind: .lBracket))
        case "]": tokens.append(Token(kind: .rBracket))
        case "+": tokens.append(Token(kind: .plus))
        case "-": tokens.append(Token(kind: .minus))
        case "*": tokens.append(Token(kind: .star))
        case "/": tokens.append(Token(kind: .slash))
        default: tokens.append(Token(kind: .error(String(c))))
        }
        i += 1
    }

    tokens.append(Token(kind: .eof))
    return tokens
}

// MARK: - AST

/// Binary comparison / arithmetic operator.
enum BinOp {
    case eq, neq, lt, gt, lte, gte
    case plus, minus, star, slash
}

/// Literal value kind.
enum LiteralKind {
    case number(Double)
    case str(String)
    case color(String)
    case bool(Bool)
    case null
    case list([Expr])
}

/// Expression AST node.
indirect enum Expr {
    case literal(LiteralKind)
    case path([String])
    case funcCall(name: String, args: [Expr])
    case dotAccess(obj: Expr, member: String)
    case indexAccess(obj: Expr, index: Expr)
    case binaryOp(op: BinOp, left: Expr, right: Expr)
    case unaryNot(Expr)
    case unaryMinus(Expr)
    case ternary(cond: Expr, trueExpr: Expr, falseExpr: Expr)
    case logicalAnd(Expr, Expr)
    case logicalOr(Expr, Expr)
    case lambda(params: [String], body: Expr)
    case letBinding(name: String, value: Expr, body: Expr)
    case assign(target: String, value: Expr)
    case sequence(left: Expr, right: Expr)
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
        case .fun: return "fun"
        case .let: return "let"
        case .ifKw: return "ifKw"
        case .then: return "then"
        case .elseKw: return "elseKw"
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
        case .arrow: return "arrow"
        case .larrow: return "larrow"
        case .semicolon: return "semicolon"
        case .equals: return "equals"
        case .plus: return "plus"
        case .minus: return "minus"
        case .star: return "star"
        case .slash: return "slash"
        case .eof: return "eof"
        case .error: return "error"
        }
    }

    // MARK: - Grammar rules

    func parse() -> Expr? {
        if case .eof = peek() { return nil }
        let node = parseSequence()
        // Ignore trailing tokens
        return node
    }

    /// sequence = let_expr (';' let_expr)*
    func parseSequence() -> Expr {
        var node = parseLet()
        while case .semicolon = peek() {
            pos += 1
            let right = parseLet()
            node = .sequence(left: node, right: right)
        }
        return node
    }

    /// let_expr = 'let' IDENT '=' sequence 'in' let_expr | assign
    func parseLet() -> Expr {
        if case .let = peek() {
            pos += 1
            guard case .ident(let name) = peek() else {
                return .literal(.null)
            }
            pos += 1
            expect(.equals)
            let value = parseSequence()
            expect(.in)
            let body = parseLet()
            return .letBinding(name: name, value: value, body: body)
        }
        return parseAssign()
    }

    /// assign = ternary '<-' assign | ternary
    func parseAssign() -> Expr {
        let node = parseTernary()
        if case .larrow = peek() {
            pos += 1
            // The left side must be an identifier (Path with one segment)
            if case .path(let segs) = node, segs.count == 1 {
                let value = parseAssign()
                return .assign(target: segs[0], value: value)
            }
            // Parse error — fall through with null
            return .literal(.null)
        }
        return node
    }

    /// ternary = 'if' sequence 'then' sequence 'else' sequence | or_expr
    func parseTernary() -> Expr {
        if case .ifKw = peek() {
            pos += 1
            let cond = parseSequence()
            expect(.then)
            let trueExpr = parseSequence()
            expect(.elseKw)
            let falseExpr = parseSequence()
            return .ternary(cond: cond, trueExpr: trueExpr, falseExpr: falseExpr)
        }
        return parseOr()
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

    /// not_expr = 'not' not_expr | '-' not_expr | comparison
    func parseNot() -> Expr {
        if case .not = peek() {
            pos += 1
            let operand = parseNot()
            return .unaryNot(operand)
        }
        if case .minus = peek() {
            pos += 1
            let operand = parseNot()
            return .unaryMinus(operand)
        }
        return parseComparison()
    }

    /// comparison = addition ( comp_op addition )?
    func parseComparison() -> Expr {
        let node = parseAddition()
        let op: BinOp?
        switch peek() {
        case .eq: op = .eq
        case .neq: op = .neq
        case .lt: op = .lt
        case .gt: op = .gt
        case .lte: op = .lte
        case .gte: op = .gte
        default: op = nil
        }
        if let op = op {
            pos += 1
            let right = parseAddition()
            return .binaryOp(op: op, left: node, right: right)
        }
        return node
    }

    /// addition = multiplication (('+' | '-') multiplication)*
    func parseAddition() -> Expr {
        var node = parseMultiplication()
        while true {
            if case .plus = peek() {
                pos += 1
                let right = parseMultiplication()
                node = .binaryOp(op: .plus, left: node, right: right)
            } else if case .minus = peek() {
                pos += 1
                let right = parseMultiplication()
                node = .binaryOp(op: .minus, left: node, right: right)
            } else {
                break
            }
        }
        return node
    }

    /// multiplication = primary (('*' | '/') primary)*
    func parseMultiplication() -> Expr {
        var node = parsePrimary()
        while true {
            if case .star = peek() {
                pos += 1
                let right = parsePrimary()
                node = .binaryOp(op: .star, left: node, right: right)
            } else if case .slash = peek() {
                pos += 1
                let right = parsePrimary()
                node = .binaryOp(op: .slash, left: node, right: right)
            } else {
                break
            }
        }
        return node
    }

    /// primary = atom accessor*
    /// accessor = '.' IDENT | '.' NUMBER | '[' expr ']' | '(' args ')'
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
                case .fun:
                    pos += 1
                    node = extendOrDot(node, "fun")
                case .let:
                    pos += 1
                    node = extendOrDot(node, "let")
                case .ifKw:
                    pos += 1
                    node = extendOrDot(node, "if")
                case .then:
                    pos += 1
                    node = extendOrDot(node, "then")
                case .elseKw:
                    pos += 1
                    node = extendOrDot(node, "else")
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
                let indexExpr = parseSequence()
                expect(.rBracket)
                node = .indexAccess(obj: node, index: indexExpr)
            } else if case .lParen = peek() {
                // Function application: expr(args)
                pos += 1
                var args: [Expr] = []
                if case .rParen = peek() {
                    // no args
                } else {
                    args.append(parseSequence())
                    while case .comma = peek() {
                        pos += 1
                        args.append(parseSequence())
                    }
                }
                expect(.rParen)
                // If node is a Path with one segment, use FuncCall for compat
                if case .path(let segs) = node, segs.count == 1 {
                    node = .funcCall(name: segs[0], args: args)
                } else {
                    node = .funcCall(name: "__apply__", args: [node] + args)
                }
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

    /// atom = 'fun' ... | IDENT | literal | '(' expr ')' | '[' items ']'
    func parseAtom() -> Expr {
        switch peek() {
        // Lambda: fun x -> body | fun (params) -> body | fun () -> body
        case .fun:
            pos += 1
            var params: [String] = []
            if case .lParen = peek() {
                pos += 1
                if case .rParen = peek() {
                    // nullary
                } else {
                    guard case .ident(let first) = peek() else {
                        return .literal(.null)
                    }
                    pos += 1
                    params.append(first)
                    while case .comma = peek() {
                        pos += 1
                        guard case .ident(let next) = peek() else {
                            return .literal(.null)
                        }
                        pos += 1
                        params.append(next)
                    }
                }
                expect(.rParen)
            } else if case .ident(let name) = peek() {
                // Unary lambda without parens: fun x -> body
                pos += 1
                params.append(name)
            }
            // else: fun -> body is nullary (caught by expect below)
            expect(.arrow)
            let body = parseSequence()
            return .lambda(params: params, body: body)

        case .ident(let name):
            pos += 1
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
            let node = parseSequence()
            expect(.rParen)
            return node

        // List literal: [expr, expr, ...]
        case .lBracket:
            pos += 1
            var items: [Expr] = []
            if case .rBracket = peek() {
                // empty list
            } else {
                items.append(parseSequence())
                while case .comma = peek() {
                    pos += 1
                    items.append(parseSequence())
                }
            }
            expect(.rBracket)
            return .literal(.list(items))

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
func evalNode(_ node: Expr, _ ctx: [String: Any]) -> Value {
    switch node {
    case .literal(let lit):
        return evalLiteral(lit, ctx)
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
    case .unaryMinus(let operand):
        return evalUnaryMinus(operand, ctx)
    case .ternary(let cond, let trueExpr, let falseExpr):
        return evalTernary(cond, trueExpr, falseExpr, ctx)
    case .logicalAnd(let left, let right):
        return evalLogicalAnd(left, right, ctx)
    case .logicalOr(let left, let right):
        return evalLogicalOr(left, right, ctx)
    case .lambda(let params, let body):
        return .closure(params: params, body: body, capturedCtx: ctx)
    case .letBinding(let name, let value, let body):
        let val = evalNode(value, ctx)
        var childCtx = ctx
        if case .closure = val {
            childCtx[name] = val
        } else {
            childCtx[name] = val.toAny()
        }
        return evalNode(body, childCtx)
    case .assign(let target, let value):
        let val = evalNode(value, ctx)
        if let storeCb = ctx["__store_cb__"] as? (String, Value) -> Void {
            storeCb(target, val)
        }
        return val
    case .sequence(let left, let right):
        let _ = evalNode(left, ctx)
        return evalNode(right, ctx)
    }
}

// MARK: - Literals

private func evalLiteral(_ lit: LiteralKind, _ ctx: [String: Any]) -> Value {
    switch lit {
    case .number(let n): return .number(n)
    case .str(let s): return .string(s)
    case .color(let c): return Value.colorValue(c)
    case .bool(let b): return .bool(b)
    case .null: return .null
    case .list(let items):
        let values = items.map { evalNode($0, ctx) }
        return .list(values.map { AnyJSON($0.toAny() ?? NSNull()) })
    }
}

// MARK: - Path resolution

private func evalPath(_ segments: [String], _ ctx: [String: Any]) -> Value {
    guard !segments.isEmpty else { return .null }

    let namespace = segments[0]
    guard var obj = ctx[namespace] else { return .null }

    // If the namespace resolves to a Value (e.g. .path or .closure set by
    // foreach/let), handle the typed-value drill cases here.
    if let v = obj as? Value {
        if segments.count == 1 { return v }
        // Drill into path Value by property name (.depth/.parent/.id/.indices)
        if case .path(let indices) = v, segments.count == 2 {
            switch segments[1] {
            case "depth": return .number(Double(indices.count))
            case "parent":
                return indices.isEmpty ? .null : .path(Array(indices.dropLast()))
            case "id": return .string(indices.map { String($0) }.joined(separator: "."))
            case "indices": return .list(indices.map { AnyJSON($0) })
            default: return .null
            }
        }
        return .null
    }

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
            // A String obj may be a serialized-JSON dict put there by
            // Value.toAny() — try deserializing and continuing the drill.
            if let data = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                if let dict = parsed as? [String: Any] {
                    guard let next = dict[seg] else { return .null }
                    obj = next
                    continue
                }
                if let arr = parsed as? [Any] {
                    if let idx = Int(seg), idx >= 0 && idx < arr.count {
                        obj = arr[idx]
                        continue
                    }
                    if seg == "length" {
                        return .number(Double(arr.count))
                    }
                }
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

    // Path computed properties (Phase 3 §6.2)
    if case .path(let indices) = objVal {
        switch member {
        case "depth":
            return .number(Double(indices.count))
        case "parent":
            if indices.isEmpty { return .null }
            return .path(Array(indices.dropLast()))
        case "id":
            return .string(indices.map { String($0) }.joined(separator: "."))
        case "indices":
            return .list(indices.map { AnyJSON($0) })
        default:
            return .null
        }
    }

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

/// Keys in ctx that are runtime-context namespaces, not user bindings.
/// When applying a closure, these are refreshed from the caller so state/
/// panel reads are current; captured user bindings stay lexical.
private let namespaceKeys: Set<String> = [
    "state", "panel", "theme", "dialog", "param", "event", "node", "prop",
    "active_document", "workspace", "data"
]

/// Apply a closure value to evaluated arguments (lexical scoping).
private func applyClosure(_ closureVal: Value, _ evaluatedArgs: [Value], _ callerCtx: [String: Any]) -> Value {
    guard case .closure(let params, let body, let capturedCtx) = closureVal else {
        return .null
    }
    guard evaluatedArgs.count == params.count else { return .null }
    // Start from captured (lexical user bindings); refresh only the
    // runtime-context namespaces from the caller so closures see
    // current state/panel values but do NOT pick up caller's user lets.
    var callCtx = capturedCtx
    for k in namespaceKeys {
        if let v = callerCtx[k] {
            callCtx[k] = v
        }
    }
    for (p, a) in zip(params, evaluatedArgs) {
        if case .closure = a {
            callCtx[p] = a
        } else {
            callCtx[p] = a.toAny()
        }
    }
    return evalNode(body, callCtx)
}

private func evalFunc(_ name: String, _ args: [Expr], _ ctx: [String: Any]) -> Value {
    // __apply__: first arg is the callee expression result
    if name == "__apply__" && args.count >= 1 {
        let callee = evalNode(args[0], ctx)
        if case .closure = callee {
            let evaluatedArgs = args.dropFirst().map { evalNode($0, ctx) }
            return applyClosure(callee, Array(evaluatedArgs), ctx)
        }
        return .null
    }

    // Check if name resolves to a closure in scope
    if let closureVal = ctx[name] as? Value, case .closure = closureVal {
        let evaluatedArgs = args.map { evalNode($0, ctx) }
        return applyClosure(closureVal, evaluatedArgs, ctx)
    }

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

    // Higher-order functions (Phase 3 §6.1)
    case "any", "all", "map", "filter":
        guard args.count == 2 else {
            return (name == "map" || name == "filter") ? .null : .bool(name == "all")
        }
        let lst = evalNode(args[0], ctx)
        let callable = evalNode(args[1], ctx)
        guard case .list(let items) = lst else {
            return (name == "map" || name == "filter") ? .null : .bool(name == "all")
        }
        guard case .closure = callable else {
            return (name == "map" || name == "filter") ? .null : .bool(name == "all")
        }
        var results: [Value] = []
        for item in items {
            let argVal = Value.fromJson(item.value)
            results.append(applyClosure(callable, [argVal], ctx))
        }
        switch name {
        case "any":
            return .bool(results.contains(where: { $0.toBool() }))
        case "all":
            return .bool(results.allSatisfy({ $0.toBool() }))
        case "map":
            return .list(results.map { r -> AnyJSON in
                switch r {
                case .null: return AnyJSON(NSNull())
                case .bool(let b): return AnyJSON(b)
                case .number(let n): return AnyJSON(n)
                case .string(let s): return AnyJSON(s)
                case .color(let c): return AnyJSON(c)
                case .list(let l): return AnyJSON(l.map { $0.value })
                case .path(let p): return AnyJSON(["__path__": p])
                case .closure: return AnyJSON(NSNull())
                }
            })
        case "filter":
            var kept: [AnyJSON] = []
            for (i, r) in results.enumerated() {
                if r.toBool() { kept.append(items[i]) }
            }
            return .list(kept)
        default:
            return .null
        }

    // Path functions (Phase 3 §6.2)
    case "path":
        var indices: [Int] = []
        for a in args {
            let v = evalNode(a, ctx)
            guard case .number(let n) = v, n >= 0 else { return .null }
            indices.append(Int(n))
        }
        return .path(indices)

    case "path_child":
        guard args.count == 2 else { return .null }
        let p = evalNode(args[0], ctx)
        let i = evalNode(args[1], ctx)
        guard case .path(var indices) = p, case .number(let n) = i, n >= 0 else {
            return .null
        }
        indices.append(Int(n))
        return .path(indices)

    case "path_from_id":
        guard args.count == 1 else { return .null }
        let s = evalNode(args[0], ctx)
        guard case .string(let str) = s else { return .null }
        if str.isEmpty { return .path([]) }
        var parts: [Int] = []
        for p in str.split(separator: ".") {
            if let n = Int(p) { parts.append(n) }
            else { return .null }
        }
        return .path(parts)

    // reverse: list -> list
    case "reverse":
        guard args.count == 1 else { return .null }
        let v = evalNode(args[0], ctx)
        guard case .list(let items) = v else { return .null }
        return .list(items.reversed())

    // mem: (element, list) -> bool — list membership
    case "mem":
        guard args.count == 2 else { return .bool(false) }
        let elem = evalNode(args[0], ctx)
        let lst = evalNode(args[1], ctx)
        guard case .list(let arr) = lst else { return .bool(false) }
        for item in arr {
            let itemVal = Value.fromJson(item.value)
            if elem.strictEq(itemVal) {
                return .bool(true)
            }
        }
        return .bool(false)

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
    case .plus:
        if case .number(let a) = lv, case .number(let b) = rv {
            return .number(a + b)
        }
        // String concatenation
        return .string(lv.toStringCoerce() + rv.toStringCoerce())
    case .minus:
        if case .number(let a) = lv, case .number(let b) = rv {
            return .number(a - b)
        }
        return .null
    case .star:
        if case .number(let a) = lv, case .number(let b) = rv {
            return .number(a * b)
        }
        return .null
    case .slash:
        if case .number(let a) = lv, case .number(let b) = rv {
            if b == 0 { return .null }
            return .number(a / b)
        }
        return .null
    }
}

private func numericCmp(_ left: Value, _ right: Value, _ f: (Double, Double) -> Bool) -> Value {
    if case .number(let a) = left, case .number(let b) = right {
        return .bool(f(a, b))
    }
    return .bool(false)
}

// MARK: - Unary not

private func evalUnaryNot(_ operand: Expr, _ ctx: [String: Any]) -> Value {
    let val = evalNode(operand, ctx)
    return .bool(!val.toBool())
}

// MARK: - Unary minus

private func evalUnaryMinus(_ operand: Expr, _ ctx: [String: Any]) -> Value {
    let val = evalNode(operand, ctx)
    if case .number(let n) = val {
        return .number(-n)
    }
    return .null
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
