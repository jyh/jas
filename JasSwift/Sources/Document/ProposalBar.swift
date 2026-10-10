import Foundation

/// A4 (iv)(a): what the accept bar's two buttons DO, kept out of the view so it
/// is testable and the view stays a thin SwiftUI adapter (the iOS-readiness
/// doctrine). The view shows `model.pendingProposalName` while
/// `model.pendingProposalId` is set, and calls these.
///
/// When the proposing client is attached to `server` (its session holds this
/// same model), the act goes THROUGH that session, so the client is told its
/// proposal's fate and a subscriber that the document changed. Otherwise (no
/// server, or the client has gone) it goes straight to the model, which lands
/// or restores the document all the same.
public enum ProposalBar {
    /// The app's socket server, set by the app when it listens
    /// (`--mcp-socket`), so the bar's view can route through the attached
    /// session. Nil in tests and on a normal launch. Main-thread only.
    nonisolated(unsafe) public static var hosted: McpSocketServer?

    public static func accept(model: Model, server: McpSocketServer?) {
        guard let id = model.pendingProposalId else { return }
        if let s = server?.attachedSession, s.model === model {
            for line in s.artistAccept(id) { server?.push(line) }
        } else {
            model.acceptProposal(id)
        }
    }

    public static func reject(model: Model, server: McpSocketServer?) {
        guard let id = model.pendingProposalId else { return }
        if let s = server?.attachedSession, s.model === model {
            for line in s.artistReject(id) { server?.push(line) }
        } else {
            model.rejectProposal(id)
        }
    }
}
