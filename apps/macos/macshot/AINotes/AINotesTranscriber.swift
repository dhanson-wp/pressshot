import AVFoundation
import Foundation
import Speech

/// Narration transcription on macOS 26 and later, with the system's own speech model. Unlike
/// the recogniser behind `VideoCaptionTranscriber`, it does not depend on Dictation or Siri
/// being switched on, and it needs no Speech Recognition permission. Everything runs on this Mac.
@available(macOS 26.0, *)
nonisolated enum AINotesTranscriber {
    /// The language the narration would be transcribed in, or nil when this Mac cannot do it.
    static func language() async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
    }

    /// Words with times as the asset has them. `asset` holds only the audio to transcribe.
    static func words(in asset: AVAsset, language: Locale) async throws -> [CaptionTimeline.Word] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pressshot-ai-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("narration.m4a")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await export.export(to: audio, as: .m4a)
        try Task.checkCancellation()

        let transcriber = SpeechTranscriber(locale: language, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // The model is a system asset, shared with other apps; the first use may have to fetch it.
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [CaptionTimeline.Word] in
            var words: [CaptionTimeline.Word] = []
            for try await result in transcriber.results {
                words.append(contentsOf: Self.words(in: result.text, fallback: result.range))
            }
            return words
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value
    }

    private static func words(in text: AttributedString, fallback: CMTimeRange) -> [CaptionTimeline.Word] {
        var words: [CaptionTimeline.Word] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let range = run.audioTimeRange ?? fallback
            words.append(CaptionTimeline.Word(text: piece, start: range.start.seconds, end: range.end.seconds))
        }
        return words
    }
}
