import SwiftUI

extension Binding where Value == Bool {
    /// True while `item` holds something; closing clears it. For alerts about one thing, such as a task to delete.
    init<Item: Sendable>(presenting item: Binding<Item?>) {
        self.init(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}
