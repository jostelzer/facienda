import AppKit
import ObjectiveC

/// Textual's text view turns down the first click in a window that isn't the active one, so a link in an agent's
/// answer only brought Facienda forward and had to be clicked again, which read as a dead link. Its links take that
/// click, as a browser's do. Textual has no setting for it, so the method is added to its view once at launch; the
/// view keeps everything else, and NSView's own answer is untouched for every other view.
enum TextualFirstClick {
    /// Textual's view for selection and links. A later Textual that renames it leaves this nil, which a test catches.
    static let view: AnyClass? = NSClassFromString("Textual.NSTextInteractionView")
    private static let selector = #selector(NSView.acceptsFirstMouse(for:))

    @MainActor static func install() {
        guard let view, let types = class_getInstanceMethod(NSView.self, selector).flatMap(method_getTypeEncoding) else { return }
        let accepts: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        // Added to Textual's class only: it does not override the method, so NSView's stays as it was.
        class_addMethod(view, selector, imp_implementationWithBlock(accepts), types)
    }

    /// Whether Textual's view now takes the first click itself rather than inheriting NSView's refusal.
    static var installed: Bool {
        guard let view, let own = class_getInstanceMethod(view, selector), let base = class_getInstanceMethod(NSView.self, selector) else { return false }
        return method_getImplementation(own) != method_getImplementation(base)
    }
}
