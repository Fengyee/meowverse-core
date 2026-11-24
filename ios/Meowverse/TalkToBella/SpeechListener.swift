// Compiled only with MEOWVERSE_TALK_TO_BELLA=YES (Config.xcconfig): not in 1.0.
#if MEOWVERSE_TALK_TO_BELLA
import AVFAudio
import Foundation
import os
import Speech

/// Hears one sentence for Talk to Bella (docs/TALK_TO_BELLA.md, 隐私).
///
/// - Recognition runs on the device only (`requiresOnDeviceRecognition`). A device that cannot
///   recognise on device, or a denied permission, is `.unavailable`; there is no server fallback.
/// - Sound and text stay in memory: nothing is recorded to a file, and the log never carries
///   what was said.
/// - The audio session switches to recording only while listening, then goes back to the room's
///   ambient sound.
@MainActor
final class SpeechListener {
    enum Outcome: Equatable {
        case heard(String)
        /// Nothing usable came through (silence, or recognition gave up).
        case nothing
        /// The microphone could not be opened just now (another app holds it, a call).
        case failed
        /// No on-device recognition, or the person said no to the microphone or speech recognition.
        case unavailable
    }

    /// About 1.2 s with no new words ends the sentence; 8 s ends it in any case.
    static let silence: Duration = .milliseconds(1200)
    static let longest: Duration = .seconds(8)

    private nonisolated static let log = Logger(subsystem: "app.meowverse", category: "talkToBella")

    private var capture: Capture?

    /// The recogniser's language follows the app's: Chinese interface, Chinese speech.
    nonisolated static var locale: Locale { Locale(identifier: AppLanguage.isChinese ? "zh-CN" : "en-US") }

    /// Whether listening is ruled out without asking anything: a permission already refused, or
    /// no on-device recognition for the app's language. Undecided permissions count as possible.
    static var ruledOut: Bool {
        let speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .denied || speech == .restricted { return true }
        if AVAudioApplication.shared.recordPermission == .denied { return true }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return true }
        return !recognizer.supportsOnDeviceRecognition
    }

    var isListening: Bool { capture != nil }

    /// Listens for one sentence. `level` gets the input loudness, 0...1. Cancelling the calling
    /// task stops at once and returns `.nothing`.
    func listen(level: @escaping @MainActor (Double) -> Void) async -> Outcome {
        guard capture == nil else { return .nothing }
        guard await Self.authorize() else { return .unavailable }
        guard !Task.isCancelled else { return .nothing }
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale), recognizer.supportsOnDeviceRecognition else {
            Self.log.notice("on-device speech recognition unavailable")
            return .unavailable
        }
        guard recognizer.isAvailable else {
            Self.log.notice("speech recognizer not available now")
            return .failed
        }
        let capture = Capture(recognizer: recognizer, level: level)
        self.capture = capture
        defer { if self.capture === capture { self.capture = nil } }
        return await withTaskCancellationHandler {
            await capture.run()
        } onCancel: {
            Task { @MainActor in capture.finish(keepingWords: false) }
        }
    }

    /// The person tapped again: end the sentence now with what was heard so far.
    func stop() {
        capture?.finish(keepingWords: true)
    }

    /// Drops whatever is being heard (left the room, a new tap took over).
    func cancel() {
        capture?.finish(keepingWords: false)
    }

    private nonisolated static func authorize() async -> Bool {
        let speech: SFSpeechRecognizerAuthorizationStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        case let status:
            speech = status
        }
        guard speech == .authorized else { return false }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// One sentence: the audio engine, the recognition request and the timers.
    private final class Capture {
        private let recognizer: SFSpeechRecognizer
        private let level: @MainActor (Double) -> Void
        private let engine = AVAudioEngine()
        private let feed: Feed
        private var task: SFSpeechRecognitionTask?
        private var words = ""
        private var lastChange = ContinuousClock.now
        private let started = ContinuousClock.now
        private var continuation: CheckedContinuation<Outcome, Never>?
        private var outcome: Outcome?
        private var watchdog: Task<Void, Never>?
        private var ducksOthers = false

        init(recognizer: SFSpeechRecognizer, level: @escaping @MainActor (Double) -> Void) {
            self.recognizer = recognizer
            self.level = level
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = false
            feed = Feed(request: request)
        }

        func run() async -> Outcome {
            await withCheckedContinuation { continuation in
                if let outcome {
                    continuation.resume(returning: outcome)
                    return
                }
                self.continuation = continuation
                start()
            }
        }

        private func start() {
            do {
                try enterRecording()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
                input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Feed.tap(feed, level: level))
                engine.prepare()
                try engine.start()
            } catch {
                SpeechListener.log.error("microphone could not start: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
                resolve(.failed)
                return
            }
            task = recognizer.recognitionTask(with: feed.request, resultHandler: Feed.results { [weak self] text, final, failed in
                self?.heard(text, final: final, failed: failed)
            })
            SpeechListener.log.notice("listening")
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.tick()
                }
            }
        }

        private func tick() {
            let now = ContinuousClock.now
            if now - started >= SpeechListener.longest || (!words.isEmpty && now - lastChange >= SpeechListener.silence) {
                finish(keepingWords: true)
            }
        }

        private func heard(_ text: String?, final: Bool, failed: Bool) {
            guard outcome == nil else { return }
            if let text, text != words {
                words = text
                lastChange = .now
            }
            if final || failed {
                if failed { SpeechListener.log.notice("recognition ended with an error") }
                finish(keepingWords: true)
            }
        }

        /// Ends listening. With `keepingWords` the sentence so far is the answer.
        func finish(keepingWords: Bool) {
            guard outcome == nil else { return }
            let sentence = words.trimmingCharacters(in: .whitespacesAndNewlines)
            resolve(keepingWords && !sentence.isEmpty ? .heard(sentence) : .nothing)
        }

        private func resolve(_ result: Outcome) {
            guard outcome == nil else { return }
            outcome = result
            watchdog?.cancel()
            watchdog = nil
            feed.request.endAudio()
            task?.cancel()
            task = nil
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            leaveRecording()
            words = ""
            SpeechListener.log.notice("listening ended: \(result.logName, privacy: .public)")
            continuation?.resume(returning: result)
            continuation = nil
        }

        /// The room plays ambient sound (RoomSounds). While listening the session records too,
        /// and quiets other apps' audio unless the room's own music is on: deactivating the session
        /// afterwards to let them come back would also stop that music.
        private func enterRecording() throws {
            let session = AVAudioSession.sharedInstance()
            ducksOthers = !UserDefaults.standard.bool(forKey: RoomSoundKeys.music)
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: ducksOthers ? [.duckOthers, .defaultToSpeaker] : [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        }

        private func leaveRecording() {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.ambient)
                if ducksOthers { try session.setActive(false, options: .notifyOthersOnDeactivation) }
            } catch {
                SpeechListener.log.notice("audio session restore: \((error as NSError).code, privacy: .public)")
            }
        }
    }

    /// What crosses to the audio and recognition threads. Built in nonisolated functions so the
    /// closures are not tied to the main actor (the app target is MainActor by default, and a
    /// main-actor closure called on the audio thread traps).
    private nonisolated final class Feed: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest

        init(request: SFSpeechAudioBufferRecognitionRequest) {
            self.request = request
        }

        static func tap(_ feed: Feed, level: @escaping @MainActor (Double) -> Void) -> AVAudioNodeTapBlock {
            { buffer, _ in
                feed.request.append(buffer)
                let loudness = Self.loudness(buffer)
                Task { @MainActor in level(loudness) }
            }
        }

        /// Recognition results, hopped to the main actor. Only the text travels, never logged.
        static func results(_ handle: @escaping @MainActor (String?, Bool, Bool) -> Void)
            -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
            { result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in handle(text, final, failed) }
            }
        }

        /// RMS of the first channel mapped from -50…0 dBFS to 0…1.
        static func loudness(_ buffer: AVAudioPCMBuffer) -> Double {
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for index in 0..<count { sum += samples[index] * samples[index] }
            let rms = (sum / Float(count)).squareRoot()
            let decibels = 20 * log10(max(rms, 1e-7))
            return Double(min(max((decibels + 50) / 50, 0), 1))
        }
    }
}

private extension SpeechListener.Outcome {
    /// For the log: which kind of ending, never the words.
    var logName: String {
        switch self {
        case .heard: "heard"
        case .nothing: "nothing"
        case .failed: "failed"
        case .unavailable: "unavailable"
        }
    }
}
#endif
