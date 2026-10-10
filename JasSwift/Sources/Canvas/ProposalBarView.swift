import SwiftUI

/// A4 (iv)(a): the accept bar over the canvas, shown while the model has a
/// pending proposal. A THIN adapter: the label is `model.pendingProposalName`
/// and the buttons call `ProposalBar`, where the behaviour lives and is tested.
/// It observes the model, so it appears when a proposal's preview lands and
/// goes when the proposal is accepted, rejected or withdrawn (each of those
/// replaces the published document).
public struct ProposalBarView: View {
    @ObservedObject var model: Model

    public init(model: Model) {
        self.model = model
    }

    public var body: some View {
        if model.pendingProposalId != nil {
            HStack(spacing: 12) {
                SwiftUI.Text("Proposed: \(model.pendingProposalName ?? "an edit")")
                    .font(.system(size: 12, weight: .medium))
                Button("Accept") { ProposalBar.accept(model: model, server: ProposalBar.hosted) }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button("Reject") { ProposalBar.reject(model: model, server: ProposalBar.hosted) }
                    .keyboardShortcut(.escape, modifiers: [.command])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(SwiftUI.Color(white: 0.15).opacity(0.92)))
            .foregroundColor(.white)
        }
    }
}
