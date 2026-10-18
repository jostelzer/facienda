import Foundation

/// The cards folded to their title on one workspace's board, kept between launches.
/// A group's card is keyed by its ID, "Unsorted" by the board's empty key.
enum FoldedCards {
    static func key(_ storageKey: String) -> String { "boardFolded:" + storageKey }

    static func load(_ storageKey: String, from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key(storageKey)) ?? [])
    }

    static func save(_ folded: Set<String>, for storageKey: String, in defaults: UserDefaults = .standard) {
        if folded.isEmpty { defaults.removeObject(forKey: key(storageKey)) } else { defaults.set(folded.sorted(), forKey: key(storageKey)) }
    }
}
