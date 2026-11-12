// speaker-native — who spoke when, using pyannote models in Core ML. Replaces
// only the NeMo step of the Python pipeline; transcription stays as it was.
//
//   speaker-native fetch-models <models-dir> [--revision R]
//       Build time only. Downloads the speaker models into <models-dir>.
//
//   speaker-native diarize <audio> --models <models-dir> --out <turns.json>
//       Writes [[start_ms, end_ms, speaker], ...] sorted by start, the same
//       shape NeMo's diarizer returns. Never uses the network.
import Foundation
import SpeakerKit
import WhisperKit

let speakerRepo = "argmaxinc/speakerkit-coreml"

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

/// Written by fetch-models, read by diarize: where the models landed.
struct Manifest: Codable {
    var speaker: String
}

func fetchModels(into dir: URL, revision: String) async throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let folder = try await ModelDownloader(config: ModelDownloadConfig(modelRepo: speakerRepo, revision: revision))
        .resolveRepo(
            patterns: [ModelInfo.segmenter().downloadPattern,
                       ModelInfo.embedder().downloadPattern,
                       ModelInfo.plda().downloadPattern],
            downloadBase: dir)
    let prefix = dir.standardizedFileURL.path + "/"
    let manifest = Manifest(speaker: String(folder.standardizedFileURL.path.dropFirst(prefix.count)))
    try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("models.json"))
}

func diarize(audio: String, modelsDir: URL, out: String) async throws {
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: modelsDir.appendingPathComponent("models.json")))
    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio)
    let speakerKit = try await SpeakerKit(PyannoteConfig(
        modelFolder: modelsDir.appendingPathComponent(manifest.speaker).path,
        download: false, load: true, verbose: false, logLevel: .error))
    let result = try await speakerKit.diarize(audioArray: samples, options: PyannoteDiarizationOptions())
    // Segments with no identified speaker are dropped.
    let turns: [[Int]] = result.segments
        .compactMap { s in s.speaker.speakerId.map { [Int(Double(s.startTime) * 1000), Int(Double(s.endTime) * 1000), $0] } }
        .sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
    try JSONEncoder().encode(turns).write(to: URL(fileURLWithPath: out))
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let usage = """
usage: speaker-native fetch-models <models-dir> [--revision R]
       speaker-native diarize <audio> --models <models-dir> --out <turns.json>
"""

do {
    switch args.first {
    case "fetch-models":
        let revision = option("--revision") ?? "main"
        guard args.count == 2 else { fail(usage) }
        try await fetchModels(into: URL(fileURLWithPath: args[1]), revision: revision)
    case "diarize":
        guard let models = option("--models"), let out = option("--out"), args.count == 2 else { fail(usage) }
        try await diarize(audio: args[1], modelsDir: URL(fileURLWithPath: models), out: out)
    default:
        fail(usage)
    }
} catch {
    fail("\(error.localizedDescription)")
}
