import Foundation
import Testing

@Test func speechDownloadsUseImmutableSnapshotsAndSafePaths() throws {
    let source = SpeechModelSnapshot.model
    #expect(source.revision.count == 40)
    #expect(SpeechModelSnapshot.tokenizer.revision.count == 40)
    let file = SpeechModelSnapshot.File(type: "file", path: "model/weights.bin", size: 3, oid: "", lfs: nil)
    #expect(source.treeURL(under: "model").path.hasSuffix("/\(source.revision)/model"))
    #expect(source.url(for: file).path.hasSuffix("/resolve/\(source.revision)/model/weights.bin"))
    #expect(try file.relativePath(under: "model") == "weights.bin")
    for path in ["/outside", "model/../outside", "model//file", "model/./file", "other/file", "model/\\file"] {
        let bad = SpeechModelSnapshot.File(type: "file", path: path, size: 3, oid: "", lfs: nil)
        #expect(throws: SpeechModelSnapshot.InvalidManifest.self) { try bad.relativePath(under: "model") }
    }
}

@Test func speechChecksContentRatherThanJustFileSize() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "speech-hash-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("abc".utf8).write(to: file)
    let lfs = SpeechModelSnapshot.File(type: "file", path: "weights.bin", size: 3, oid: "unused", lfs: .init(oid: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    let git = SpeechModelSnapshot.File(type: "file", path: "tokenizer.json", size: 3, oid: "f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f", lfs: nil)
    #expect(lfs.matches(file) && git.matches(file))
    try Data("abd".utf8).write(to: file)
    #expect(!lfs.matches(file) && !git.matches(file))
}

@Test func anOldOrIncompleteSpeechCacheIsNotReady() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "speech-ready-\(UUID().uuidString)")
    let folder = root.appending(path: "model"), suite = "FaciendaSpeechTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defaults.set("/old/unpinned/model", forKey: SpeechModelSnapshot.readyKey)
    #expect(!SpeechModelSnapshot.isReady(defaults: defaults, folder: folder))
    defaults.set(folder.path, forKey: SpeechModelSnapshot.readyKey)
    #expect(!SpeechModelSnapshot.isReady(defaults: defaults, folder: folder))
    for name in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc", "config.json"] {
        try Data().write(to: folder.appending(path: name))
    }
    try Data().write(to: root.appending(path: "tokenizer.json"))
    #expect(!SpeechModelSnapshot.isReady(defaults: defaults, folder: folder))
    try Data().write(to: root.appending(path: "tokenizer_config.json"))
    #expect(SpeechModelSnapshot.isReady(defaults: defaults, folder: folder))
}
