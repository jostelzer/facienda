import Foundation

/// The cards sorted by date on one workspace's board, kept between launches. The order the user dragged is not in here:
/// it stays saved with the tasks, and comes back exactly when a card goes back to it.
/// A group's card is keyed by its ID, "Unsorted" by the board's empty key.
enum DateSortedCards {
    static func key(_ storageKey: String) -> String { "boardByDate:" + storageKey }

    static func load(_ storageKey: String, from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key(storageKey)) ?? [])
    }

    static func save(_ cards: Set<String>, for storageKey: String, in defaults: UserDefaults = .standard) {
        if cards.isEmpty { defaults.removeObject(forKey: key(storageKey)) } else { defaults.set(cards.sorted(), forKey: key(storageKey)) }
    }
}
