import Testing
@testable import JasLib

// MARK: - Parsed-AST cache (mirrors the Rust + Python implementations)

@Test func cacheReturnsCorrectResultsOnRepeat() {
    let ctx1: [String: Any] = ["x": 1]
    let ctx2: [String: Any] = ["x": 99]
    #expect(evaluate("x", context: ctx1) == .number(1))
    #expect(evaluate("x", context: ctx2) == .number(99))
    // Re-eval is a cache hit but must still see the per-call ctx.
    #expect(evaluate("x", context: ctx1) == .number(1))
    #expect(evaluate("x + 1", context: ctx2) == .number(100))
}

@Test func cacheHandlesUnparseableInput() {
    // First call parses (and fails); second is a cache hit on nil.
    #expect(evaluate(")(", context: [:]) == .null)
    #expect(evaluate(")(", context: [:]) == .null)
}

@Test func cacheHandlesArithmeticRepeats() {
    let ctx: [String: Any] = ["a": 10, "b": 3]
    for _ in 0..<5 {
        #expect(evaluate("a + b", context: ctx) == .number(13))
        #expect(evaluate("a * b", context: ctx) == .number(30))
    }
}
