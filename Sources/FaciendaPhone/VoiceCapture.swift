import AVFoundation
import Observation
import Speech

@MainActor @Observable final class VoiceCapture {
    enum Phase: Equatable { case idle, preparing, recording, transcribing }
    private(set) var phase: Phase = .idle
    private(set) var level: Double = 0
    var error: String?
    private var recorder: AVAudioRecorder?
    private var meter: Task<Void, Never>?
    private var audioURL: URL?

    var isBusy: Bool { phase == .preparing || phase == .transcribing }
    var hasRecording: Bool { audioURL != nil }

    func start() async {
        guard phase == .idle else { return }
        discard()
        phase = .preparing; error = nil
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw VoiceError.message("Allow microphone access in Settings to record a task. You can also type it.")
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appending(path: Self.filePrefix + UUID().uuidString + ".m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            recorder.isMeteringEnabled = true
            audioURL = url
            guard recorder.record() else { throw VoiceError.message("The microphone could not start. Please try again.") }
            self.recorder = recorder; phase = .recording
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    self.level = max(0, min(1, Double((recorder.averagePower(forChannel: 0) + 55) / 55)))
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        } catch { fail(error) }
    }

    func finish() async -> String? {
        guard phase == .recording else { return nil }
        recorder?.stop(); recorder = nil; meter?.cancel(); meter = nil; level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle
        return await transcribe()
    }

    func transcribe() async -> String? {
        guard phase == .idle, let audioURL else { return nil }
        phase = .transcribing; error = nil
        defer { phase = .idle }
        do {
            guard SpeechTranscriber.isAvailable else {
                throw VoiceError.message("On-device transcription is unavailable here. Try this on your iPhone, or use keyboard dictation.")
            }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
                throw VoiceError.message("This device’s language is not supported by on-device transcription yet. You can use keyboard dictation.")
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let results = Task { () throws -> String in
                var text = ""
                for try await result in transcriber.results { text += String(result.text.characters) }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            do {
                let file = try AVAudioFile(forReading: audioURL)
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                let text = try await results.value
                guard !text.isEmpty else { throw VoiceError.message("No speech was detected. Record again or type your task.") }
                discard()
                return text
            } catch {
                results.cancel(); await analyzer.cancelAndFinishNow(); throw error
            }
        } catch { self.error = error.localizedDescription; return nil }
    }

    /// Deletes the recording. Kept only while a failed transcription can be tried again.
    func discard() {
        guard phase != .recording, let audioURL else { return }
        try? FileManager.default.removeItem(at: audioURL)
        self.audioURL = nil
    }

    static let filePrefix = "facienda-voice-"
    /// Recordings left by a transcription that never finished, for example when the app was closed.
    static func removeLeftovers() {
        let folder = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(filePrefix) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    private func fail(_ error: Error) {
        recorder?.stop(); recorder = nil; meter?.cancel(); meter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle; self.error = error.localizedDescription
        discard()
    }
}

private enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}
