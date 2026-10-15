import FluidAudio
import CoreML
import Foundation

// No ASR: return the acoustic speaker timeline even when no transcription
// token overlaps a short reply. Speaker IDs are clustered over the full call.
struct Segment: Codable {
    let start: Double
    let end: Double
    let speaker: String
    let quality: Float
}

struct Response: Codable {
    let backend: String
    let duration: Double
    let speaker_segments: [Segment]
}

@main
struct RecordCallDiarizer {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            FileHandle.standardError.write(Data("Usage: record-call-diarizer AUDIO OUTPUT_JSON\n".utf8))
            exit(2)
        }
        var config = OfflineDiarizerConfig()
        // Brief acknowledgments are real turns. The upstream 1-second floor
        // also filters the reconstructed output, not just embeddings.
        config.embedding.minSegmentDurationSeconds = 0.1
        let environment = ProcessInfo.processInfo.environment
        // Preserve overlap for the aligner's ambiguity checks. Suppressing
        // overlapping speakers here would fabricate certainty downstream.
        config.postProcessing.exclusiveSegments = false
        let manager = OfflineDiarizerManager(config: config)
        let modelConfig = MLModelConfiguration()
        if environment["RECORD_CALL_DIARIZER_CPU_ONLY"] == "1" {
            modelConfig.computeUnits = .cpuOnly
        }
        let modelDirectory = environment["RECORD_CALL_DIARIZER_MODEL_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        try await manager.prepareModels(directory: modelDirectory, configuration: modelConfig)
        let samples = try AudioConverter().resampleAudioFile(path: arguments[1])
        let result = try await manager.process(audio: samples)
        var segments: [Segment] = []
        for segment in result.segments {
            segments.append(Segment(start: Double(segment.startTimeSeconds),
                                    end: Double(segment.endTimeSeconds),
                                    speaker: segment.speakerId, quality: segment.qualityScore))
        }
        segments.sort { left, right in
            if left.start == right.start { return left.end < right.end }
            return left.start < right.start
        }
        let response = Response(backend: "fluidaudio-offline-vbx-0.15.5",
                                duration: Double(samples.count) / 16000,
                                speaker_segments: segments)
        try JSONEncoder().encode(response).write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
    }
}
