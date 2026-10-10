import Testing
import Foundation
@testable import JasLib

private let moveOps: [[String: Any]] = [
    ["op": "select_rect", "x": 0, "y": 0, "width": 200, "height": 200, "extend": false],
    ["op": "move_selection", "dx": 3, "dy": 4],
]

private func twoRects() -> Model {
    Model(document: svgToDocument(#"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200"><g><rect x="10" y="10" width="20" height="20" fill="red"/><rect x="60" y="60" width="20" height="20" fill="blue"/></g></svg>"#))
}

private func propose(_ s: McpSession) {
    let out = s.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"propose","arguments":{"name":"nudge","ops":[{"op":"select_rect","x":0,"y":0,"width":50,"height":50,"extend":false},{"op":"move_selection","dx":10,"dy":0}]}}}"#)
    #expect(out.first?.contains("p-0") == true, "the control: a proposal is pending: \(out)")
}

private func edit(_ m: Model) {
    // An ORDINARY app edit: straight through the model, never through
    // `McpSession.artistEdit`. This is the path every tool and panel takes.
    m.withTxn { let c = Controller(model: m); for op in moveOps { _ = opApply(m, c, op) } }
}

/// A4 (iv)(b): an edit made through the app's ordinary paths withdraws the
/// pending proposal (the model already did that) AND now tells the client.
@Test func anOrdinaryEditTellsTheClientItsProposalWasWithdrawn() {
    let m = twoRects()
    let s = McpSession(model: m)
    var sent: [String] = []
    s.send = { sent.append($0) }
    propose(s)
    edit(m)
    #expect(m.pendingProposalId == nil, "the control: the model withdrew it")
    #expect(sent.filter { $0.contains("notifications/jas/proposal") && $0.contains("withdrawn") && $0.contains("p-0") }.count == 1, "\(sent)")
}

/// A4 (iv)(b): a subscriber hears about an ordinary edit to the settled
/// document, and does NOT hear about a proposal's preview (which changes the
/// drawn document, not the settled one).
@Test func aSubscriberHearsAnOrdinaryEditButNotAPreview() {
    let m = twoRects()
    let s = McpSession(model: m)
    var sent: [String] = []
    s.send = { sent.append($0) }
    _ = s.handle(#"{"jsonrpc":"2.0","id":9,"method":"resources/subscribe","params":{"uri":"jas://document"}}"#)
    propose(s)
    #expect(!sent.contains { $0.contains("resources/updated") }, "a preview is not a settled change: \(sent)")
    edit(m)
    #expect(sent.filter { $0.contains("resources/updated") }.count == 1, "\(sent)")
}

/// A4 (iv)(b): the session's own artist act reports itself, so the hook must
/// not report it a second time.
@Test func anArtistActThroughTheSessionIsReportedOnce() {
    let m = twoRects()
    let s = McpSession(model: m)
    var sent: [String] = []
    s.send = { sent.append($0) }
    propose(s)
    let returned = s.artistEdit { mm in let c = Controller(model: mm); for op in moveOps { _ = opApply(mm, c, op) } }
    let all = returned + sent
    #expect(all.filter { $0.contains("withdrawn") }.count == 1, "returned \(returned), sent \(sent)")
}

/// A4 (iv)(a): the bar's Accept with NO client attached lands the proposal as
/// ONE journal transaction, named by the proposal, with actor `ai`; the bar
/// reads the name it shows from the model.
@Test func theBarAcceptsWithNoClientAsOneNamedAiTransaction() {
    let m = twoRects()
    let s = McpSession(model: m)
    propose(s)
    #expect(m.pendingProposalName == "nudge", "the bar's label")
    let before = m.journal.count
    ProposalBar.accept(model: m, server: nil)
    #expect(m.pendingProposalId == nil)
    #expect(m.journal.count == before + 1, "one transaction")
    #expect(m.journal.last?.actor == "ai" && m.journal.last?.name == "nudge", "\(String(describing: m.journal.last))")
}

/// A4 (iv)(a): Reject restores the document and journals nothing.
@Test func theBarRejectsAndJournalsNothing() {
    let m = twoRects()
    let settled = documentToTestJson(m.document)
    let s = McpSession(model: m)
    propose(s)
    #expect(documentToTestJson(m.document) != settled, "the control: the preview is drawn")
    let before = m.journal.count
    ProposalBar.reject(model: m, server: nil)
    #expect(m.pendingProposalId == nil && m.journal.count == before)
    #expect(documentToTestJson(m.document) == settled)
}
