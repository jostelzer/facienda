import SwiftUI

/// A capsule at the foot of the window saying what just happened, with Undo.
struct UndoToast: View {
    let message: String
    let maxWidth: CGFloat
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message).font(.system(size: 12)).lineLimit(1)
            Button("Undo", action: undo).buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.blue)
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .background(Palette.card, in: Capsule()).overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3).padding(.bottom, 18).frame(maxWidth: maxWidth)
    }
}

/// Reports the last change that can be undone for a few seconds: a delete, a move, a task done or parked.
struct UndoOfferToast: View {
    @Bindable var model: AppModel

    var body: some View {
        if let offer = model.undoOffer {
            UndoToast(message: offer.message, maxWidth: 460) { withAnimation(Motion.move) { model.takeBack(offer) } }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: offer.id) {
                    try? await Task.sleep(for: .seconds(8))
                    if model.undoOffer?.id == offer.id { withAnimation(Motion.move) { model.undoOffer = nil } }
                }
        }
    }
}
