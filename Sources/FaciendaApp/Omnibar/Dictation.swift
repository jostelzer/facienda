import AVFoundation
import Observation
import OSLog
import SwiftUI

/// Speech to text for the top bar, with Whisper on this Mac. Audio never leaves it.
/// While you speak, the recording so far is transcribed again every moment; stopping runs one last, complete pass.
@MainActor @Observable final class Dictation {
    enum Phase: Equatable { case idle, preparing, downloading, listening, finishing }
    private(set) var phase: Phase = .idle
    /// Download progress of the speech model, 0…1.
    private(set) var progress: Double = 0
    /// False until the speech model is in memory; the first load can take a while.
    private(set) var modelReady = false
    /// Microphone loudness, 0…1, for the button.
    private(set) var level: Double = 0
    private(set) var text = ""
    /// The voice heard since the words so far, drawn as outlines until Whisper writes it down.
    /// Only the outlines read it: it changes every few milliseconds.
    private(set) var shapes: [VoiceShape] = []
    /// Whether any outline is showing, for views that only need to know that.
    private(set) var showsVoice = false
    var error: String?
    /// Called on every change to the words heard so far.
    @ObservationIgnored var onText: ((String) -> Void)?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var recording = Recording()
    @ObservationIgnored private var shaper = VoiceShaper()
    private static let log = Logger(subsystem: "org.facienda.mac", category: "Dictation")
    @ObservationIgnored private var preview: Task<Void, Never>?
    @ObservationIgnored private var language: String?
    @ObservationIgnored private var prompt = ""
    /// Bumped by every start and cancel, so work that is still running can tell it was called off.
    @ObservationIgnored private var generation = 0

    var isActive: Bool { phase != .idle }

    /// Languages to offer besides detecting it: the Mac's preferred languages, as Whisper's codes.
    static let languages: [String] = {
        var seen = Set<String>()
        return Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }.filter { seen.insert($0).inserted }
    }()

    static let languageKey = "dictationLanguageCode"
    /// The language chosen from any mic's menu, or nil to let Whisper tell.
    static var language: String? {
        let code = UserDefaults.standard.string(forKey: languageKey) ?? ""
        return code.isEmpty ? nil : code
    }

    /// Spoken words follow what was already written.
    static func join(_ base: String, _ words: String) -> String {
        words.isEmpty || base.isEmpty || base.last?.isWhitespace == true ? base + words : base + " " + words
    }

    /// Starts dictating into a text, or stops if already listening. Typing in between stops listening and keeps what is there.
    func toggle(into text: Binding<String>, vocabulary: [String]) {
        if isActive { Task { await finish() }; return }
        let base = text.wrappedValue
        var placed = base
        onText = { [weak self] words in
            guard text.wrappedValue == placed else { self?.cancel(); return }
            placed = Self.join(base, words)
            text.wrappedValue = placed
        }
        Task { await start(language: Self.language, vocabulary: vocabulary) }
    }

    /// Runs an action once the last words are in, or at once when not dictating.
    func finishing(_ action: @escaping () -> Void) {
        guard isActive else { action(); return }
        Task { await finish(); action() }
    }

    /// Loads the model ahead of time if it is already downloaded, so the first words come quickly.
    func warm() {
        guard WhisperEngine.isDownloaded, !modelReady else { return }
        Task { if (try? await WhisperEngine.shared.load()) != nil { modelReady = true } }
    }

    /// Starts listening. `language` is a code such as "en", or nil to detect it.
    /// Names such as group titles help Whisper with words it may not know.
    func start(language: String?, vocabulary: [String] = []) async {
        guard phase == .idle else { return }
        generation += 1
        let run = generation
        phase = .preparing; error = nil; text = ""
        shaper = VoiceShaper(); publish()
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw DictationError("Allow Facienda to use the microphone in System Settings › Privacy & Security › Microphone.")
            }
            if !WhisperEngine.isDownloaded {
                phase = .downloading; progress = 0
                try await WhisperEngine.shared.download { [weak self] value in Task { @MainActor in self?.progress = value } }
                guard generation == run else { return }
            }
            // Listening starts at once; words follow when the model is ready.
            if !modelReady {
                Task {
                    do { try await WhisperEngine.shared.load(); modelReady = true } catch {
                        guard generation == run else { return }
                        cancel()
                        self.error = "The speech model could not be loaded. Try again to repair it. (\(error.localizedDescription))"
                    }
                }
            }
            self.language = language
            prompt = vocabulary.joined(separator: ", ")
            try startMicrophone()
            phase = .listening
            preview = Task { await showWordsSoFar(run) }
        } catch {
            guard generation == run else { return }
            tearDown()
            self.error = error.localizedDescription
        }
    }

    /// Stops listening and transcribes everything once more. Returns what was said.
    @discardableResult func finish() async -> String {
        guard phase == .listening else { if phase != .idle { cancel() }; return text }
        let run = generation
        phase = .finishing
        stopMicrophone(); preview?.cancel(); preview = nil
        // Nothing is being spoken any more; the outlines wait for the last pass in grey.
        shapes = shapes.map { var shape = $0; shape.open = false; return shape }
        if recording.heardSpeech {
            do {
                let samples = recording.samples
                let words = try await WhisperEngine.shared.transcribe(samples, language: language, prompt: prompt)
                Self.log.info("Final pass over \(Double(samples.count) / 16_000, format: .fixed(precision: 1)) s gave \(words.count) characters")
                guard generation == run else { return text }
                modelReady = true
                update(words, covering: .infinity)
            } catch {
                Self.log.error("Final pass failed: \(error.localizedDescription, privacy: .public)")
                guard generation == run else { return text }
                self.error = error.localizedDescription
            }
        } else {
            Self.log.info("Stopped without speech louder than the room")
            update("", covering: .infinity)
        }
        tearDown()
        return text
    }

    /// Stops at once and forgets what was heard.
    func cancel() {
        generation += 1
        tearDown()
        text = ""
    }

    private func showWordsSoFar(_ run: Int) async {
        var transcribed = 0
        while generation == run, phase == .listening {
            try? await Task.sleep(for: .milliseconds(700))
            guard generation == run, phase == .listening, recording.heardSpeech else { continue }
            let samples = recording.samples
            // A pass is only worth it with new audio, and long recordings wait for the final pass.
            guard samples.count - transcribed >= WhisperEngine.sampleRate / 2, samples.count <= WhisperEngine.sampleRate * 45 else { continue }
            transcribed = samples.count
            let words: String
            do { words = try await WhisperEngine.shared.transcribe(samples, language: language, prompt: prompt) } catch {
                Self.log.error("Pass failed: \(error.localizedDescription, privacy: .public)"); continue
            }
            Self.log.info("Pass over \(Double(samples.count) / 16_000, format: .fixed(precision: 1)) s gave \(words.count) characters")
            guard generation == run, phase == .listening else { continue }
            modelReady = true
            update(words, covering: Double(samples.count) / Double(WhisperEngine.sampleRate))
        }
    }

    /// Takes Whisper's words for the first `covering` seconds; the voice after that stays as outlines.
    private func update(_ words: String, covering seconds: Double) {
        shaper.cover(until: seconds)
        publish()
        // Whisper marks silence and noise in brackets, such as [BLANK_AUDIO].
        let cleaned = words.replacing(/\[[^\]]*\]/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != text else { return }
        text = cleaned
        if onText == nil { Self.log.error("Words arrived with nowhere to put them") }
        onText?(cleaned)
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let microphone = engine.inputNode.outputFormat(forBus: 0)
        guard microphone.sampleRate > 0, microphone.channelCount > 0,
              let whisper = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(WhisperEngine.sampleRate), channels: 1, interleaved: false)
        else { throw DictationError("No microphone is connected.") }
        let recording = Recording()
        self.recording = recording
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: microphone,
                                    block: Self.tap(converter: BufferConverter(output: whisper), meter: LevelMeter(sampleRate: microphone.sampleRate),
                                                    recording: recording) { [weak self] levels in
            Task { @MainActor in self?.hear(levels) }
        })
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Loudness every 10 ms: the button follows it, and the shaper turns it into outlines.
    private func hear(_ levels: [Double]) {
        guard phase == .listening, !levels.isEmpty else { return }
        for value in levels { shaper.hear(value) }
        publish()
        level = levels.max() ?? 0
    }

    private func publish() {
        shapes = shaper.shapes
        if showsVoice == shapes.isEmpty { showsVoice = !shapes.isEmpty }
    }

    private func stopMicrophone() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        level = 0
    }

    private func tearDown() {
        stopMicrophone()
        shapes = []; showsVoice = false
        preview?.cancel(); preview = nil
        phase = .idle
    }

    /// Runs on the audio thread, so it must not belong to the main actor.
    private nonisolated static func tap(converter: BufferConverter, meter: LevelMeter, recording: Recording,
                                        levels: @escaping @Sendable ([Double]) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let loudness = Self.loudness(buffer)
            levels(meter.levels(buffer))
            guard let converted = try? converter.convert(buffer) else { return }
            recording.append(converted, loudness: loudness)
        }
    }

    private nonisolated static func loudness(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        return scale(meanSquare: sum / Float(buffer.frameLength))
    }

    /// Mean power on a 0…1 scale from −55 dB, where a quiet room sits near the bottom and speech in the upper half.
    nonisolated static func scale(meanSquare: Float) -> Double {
        max(0, min(1, Double(10 * log10(max(meanSquare, 1e-10)) + 55) / 55))
    }
}

/// Loudness in 10 ms steps, carried across buffers. Used only on the audio thread.
private final class LevelMeter: @unchecked Sendable {
    private let window: Int
    private var sum: Float = 0
    private var count = 0

    init(sampleRate: Double) { window = max(1, Int(sampleRate / 100)) }

    func levels(_ buffer: AVAudioPCMBuffer) -> [Double] {
        guard let samples = buffer.floatChannelData?[0] else { return [] }
        var out: [Double] = []
        for index in 0..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]; count += 1
            if count == window { out.append(Dictation.scale(meanSquare: sum / Float(window))); sum = 0; count = 0 }
        }
        return out
    }
}

/// The microphone's samples at 16 kHz, written on the audio thread and read on the main actor.
private final class Recording: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float] = []
    private var loudest: Double = 0

    var samples: [Float] { lock.withLock { stored } }
    /// Whether anything louder than room noise came in. Whisper invents words for silence.
    var heardSpeech: Bool { lock.withLock { loudest > 0.25 } }

    func append(_ buffer: AVAudioPCMBuffer, loudness: Double) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.withLock { stored.append(contentsOf: chunk); loudest = max(loudest, loudness) }
    }
}

/// Converts microphone buffers to the format Whisper wants. Used only on the audio thread.
private final class BufferConverter: @unchecked Sendable {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(output: AVAudioFormat) { self.output = output }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard buffer.format != output else { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            converter?.primeMethod = .none
        }
        guard let converter else { throw DictationError("Dictation could not convert the microphone's audio.") }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate).rounded(.up))
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            throw DictationError("Dictation could not convert the microphone's audio.")
        }
        var error: NSError?
        var delivered = false
        let status = converter.convert(to: converted, error: &error) { _, status in
            if delivered { status.pointee = .noDataNow; return nil }
            delivered = true; status.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? DictationError("Dictation could not convert the microphone's audio.") }
        return converted
    }
}

private struct DictationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
