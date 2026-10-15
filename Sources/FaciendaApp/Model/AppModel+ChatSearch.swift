import Foundation
import FaciendaCore
import FaciendaBridge

extension AppModel {
    /// The private index of this Mac's Codex chats, opened on first use. Nil in the demo or while chat search is off.
    var chatIndex: ChatIndex? {
        guard !demo, chatSearchEnabled == true else { return nil }
        if openedChatIndex == nil { openedChatIndex = try? ChatIndex() }
        return openedChatIndex
    }
    func setChatSearch(_ enabled: Bool) {
        guard !demo else { return }
        chatSearchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "chatSearchEnabled")
        if enabled {
            if chatIndex == nil { chatIndexError = "Facienda could not open its chat index." }
            indexChats()
            return
        }
        indexTask?.cancel(); indexTask = nil; chatIndexProgress = nil
        // Turning search off removes everything that was indexed.
        do {
            if let index = openedChatIndex { try index.erase() }
            else if FileManager.default.fileExists(atPath: ChatIndex.defaultURL.path) { try ChatIndex().erase() }
            chatIndexError = nil
        } catch { chatIndexError = error.localizedDescription }
        openedChatIndex = nil
    }
    /// Keeps the chat index current while connected: quick steps until it has caught up, then a check each minute.
    func indexChats() {
        guard indexTask == nil, connected, let index = chatIndex else { return }
        chatIndexProgress = try? index.progress()
        let indexer = ChatIndexer(bridge: bridge, index: index)
        indexTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.connected, self.chatSearchEnabled == true else { break }
                var pause = 60.0
                do {
                    let progress = try await indexer.step()
                    self.chatIndexProgress = progress; self.chatIndexError = nil
                    if progress.building { pause = 1 }
                } catch is CancellationError { break }
                catch { self.chatIndexError = error.localizedDescription; pause = 30 }
                do { try await Task.sleep(for: .seconds(pause)) } catch { break }
            }
            // Whoever cancelled the task has already cleared it.
            if !Task.isCancelled { self?.indexTask = nil }
        }
    }
}
