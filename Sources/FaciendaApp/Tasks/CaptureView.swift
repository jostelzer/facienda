import SwiftUI

/// The New task sheet: the composer, and a way out.
struct CaptureView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New task").font(.system(size: 22, weight: .semibold))
            TaskComposer(model: model)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.capturing)
                Spacer()
            }
        }.padding(28).frame(width: 700).background(Palette.paper)
    }
}
