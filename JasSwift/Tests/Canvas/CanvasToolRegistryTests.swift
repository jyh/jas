import Testing
import AppKit
@testable import JasLib

// Tests for the createTools / loadYamlTool tiered-failure design:
//   * Workspace nil → fatalError (cannot test directly without
//     crashing the test process; covered by manual code review)
//   * Per-tool nil → log + omit (verified here)

@Test func loadYamlToolReturnsToolForKnownId() {
    guard let ws = WorkspaceData.load() else {
        Issue.record("workspace.json must be loadable for this test")
        return
    }
    #expect(loadYamlTool("rect", in: ws) != nil)
    #expect(loadYamlTool("selection", in: ws) != nil)
    #expect(loadYamlTool("pen", in: ws) != nil)
}

@Test func loadYamlToolReturnsNilForUnknownId() {
    guard let ws = WorkspaceData.load() else {
        Issue.record("workspace.json must be loadable for this test")
        return
    }
    #expect(loadYamlTool("definitely_not_a_tool", in: ws) == nil)
    #expect(loadYamlTool("", in: ws) == nil)
}

@Test func createToolsAlwaysIncludesNativeOnly() {
    // Type and TypeOnPath are permanent-native per
    // NATIVE_BOUNDARY.md §6 — they don't depend on workspace.json
    // having a spec, and createTools adds them unconditionally.
    let registry = createTools()
    #expect(registry[.typeTool] != nil)
    #expect(registry[.typeOnPath] != nil)
}

@Test func createToolsIncludesYamlToolsWhenSpecsExist() {
    // Sanity check that the canonical YAML tools are present in a
    // working workspace. If a future change drops a spec, this test
    // fails loudly rather than the missing tool silently no-op'ing
    // at the dispatch site.
    let registry = createTools()
    let expected: [Tool] = [
        .selection, .partialSelection, .interiorSelection,
        .pen, .addAnchorPoint, .deleteAnchorPoint, .anchorPoint,
        .pencil, .pathEraser, .smooth,
        .line, .rect, .roundedRect, .ellipse, .polygon, .star, .lasso,
    ]
    for tool in expected {
        #expect(registry[tool] != nil, "expected createTools() to include \(tool)")
    }
}
