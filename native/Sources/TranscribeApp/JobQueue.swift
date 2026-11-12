import AppKit
import Foundation
import UniformTypeIdentifiers

enum JobState: Equatable {
    case waiting
    case running(step: String, progress: Double)
    case done
    case failed(String)
    case stopped

    var isFinished: Bool {
        switch self {
        case .done, .failed, .stopped: return true
        case .waiting, .running: return false
        }
    }
}

/// A finished recording, as remembered between launches.
struct HistoryRecord: Codable {
    var id: UUID
    var audioPath: String
    var finished: Date
    var seconds: Double  // how long transcribing took
}

/// Where the app keeps its own data: the list of finished recordings and, for
/// each, the word timings the transcript view needs. Transcripts themselves
/// (.txt, .srt) are saved next to the recordings, not here.
enum Store {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Transcribe", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder.appendingPathComponent("transcripts"), withIntermediateDirectories: true)
        return folder
    }()

    static var historyURL: URL { folder.appendingPathComponent("history.json") }

    static func wordsURL(for id: UUID) -> URL {
        folder.appendingPathComponent("transcripts/\(id.uuidString).json")
    }

    static func loadHistory() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryRecord].self, from: data)) ?? []
    }

    static func saveHistory(_ records: [HistoryRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(records) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }
}

@MainActor
final class Job: ObservableObject, Identifiable {
    let id: UUID
    let url: URL
    @Published var state: JobState = .waiting
    var started: Date?
    var finished: Date?
    var log = ""
    var logURL: URL?
    /// True for rows restored from history rather than transcribed this session.
    var fromHistory = false

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }

    init(record: HistoryRecord) {
        id = record.id
        url = URL(fileURLWithPath: record.audioPath)
        state = .done
        finished = record.finished
        started = record.finished.addingTimeInterval(-record.seconds)
        fromHistory = true
    }

    var transcriptURL: URL { url.deletingPathExtension().appendingPathExtension("txt") }
    var wordsURL: URL { Store.wordsURL(for: id) }

    func elapsed(until date: Date) -> TimeInterval {
        started.map { date.timeIntervalSince($0) } ?? 0
    }
}

/// Runs the bundled pipeline on one recording at a time.
@MainActor
final class JobQueue: ObservableObject {
    static let shared = JobQueue()

    @Published private(set) var jobs: [Job] = []
    @Published var dropTargeted = false
    private var process: Process?
    private var current: Job?

    var isBusy: Bool { process != nil }

    private var historyLoaded = false

    /// Finished recordings from earlier sessions, newest first, below anything
    /// already queued (files dropped on the icon arrive before launch finishes).
    func loadHistoryOnce() {
        guard !historyLoaded else { return }
        historyLoaded = true
        let records = Store.loadHistory().sorted { $0.finished > $1.finished }
        jobs += records.map(Job.init(record:))
    }

    private func saveHistory() {
        let records = jobs.filter { $0.state == .done }.compactMap { job -> HistoryRecord? in
            guard let finished = job.finished else { return nil }
            return HistoryRecord(
                id: job.id, audioPath: job.url.path, finished: finished,
                seconds: job.elapsed(until: finished))
        }
        Store.saveHistory(records)
    }

    /// Sample rows in every state, for `--snapshot` (see Snapshot.swift).
    static func preview() -> JobQueue {
        let queue = JobQueue()
        func job(_ name: String, _ state: JobState, ago: TimeInterval = 0, took: TimeInterval = 0) -> Job {
            let job = Job(url: URL(fileURLWithPath: "/Users/someone/Recordings/\(name)"))
            job.state = state
            job.started = Date().addingTimeInterval(-ago)
            job.finished = job.started?.addingTimeInterval(took)
            return job
        }
        queue.jobs = [
            job("signal-2026-05-19-09-39-37-235.mp4", .running(step: "Transcribing", progress: 0.42), ago: 371),
            job("Site visit notes.wav", .waiting),
            job("broken-download.mp3", .failed("Could not transcribe this file. Invalid data found when processing input")),
            job("Council meeting.m4a", .stopped),
            job("Interview with planning director.m4a", .done, ago: 900, took: 612),
            job("Community forum, part 2.m4a", .done, ago: 86400 * 3, took: 845),
        ]
        queue.jobs.last?.fromHistory = true
        return queue
    }

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            // Dropping a file that is already waiting or running does nothing.
            if jobs.contains(where: { $0.url == url && !$0.state.isFinished }) { continue }
            // New work goes above the history, in the order it was added.
            let firstFinished = jobs.firstIndex(where: { $0.state == .done && $0.fromHistory }) ?? jobs.count
            jobs.insert(Job(url: url), at: firstFinished)
        }
        startNext()
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.prompt = "Transcribe"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// Takes a row off the list. Never touches the recording or its transcript files.
    func remove(_ job: Job) {
        guard job !== current else { return }
        let wasDone = job.state == .done
        jobs.removeAll { $0 === job }
        if wasDone {
            try? FileManager.default.removeItem(at: job.wordsURL)
            saveHistory()
        }
    }

    func retry(_ job: Job) {
        guard job.state.isFinished else { return }
        job.state = .waiting
        job.log = ""
        startNext()
    }

    func stop(_ job: Job) {
        guard job === current else { return }
        job.state = .stopped
        process?.terminate()
    }

    func stopAll() {
        for job in jobs where job.state == .waiting { job.state = .stopped }
        if let current { stop(current) }
    }

    private func startNext() {
        guard process == nil, let job = jobs.first(where: { $0.state == .waiting }) else { return }
        guard let resources = Bundle.main.resourceURL else { return }

        let python = resources.appendingPathComponent("python/bin/python3")
        let process = Process()
        process.executableURL = python
        process.arguments = [
            resources.appendingPathComponent("pipeline.py").path, job.url.path, "--json", job.wordsURL.path,
        ]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // Only the bundled Python and models, and no network: same as the old worker script.
        process.environment = [
            "PATH": python.deletingLastPathComponent().path + ":/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "PYTHONNOUSERSITE": "1",
            "HF_HOME": resources.appendingPathComponent("models/huggingface").path,
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let lines = buffer.append(handle.availableData)
            guard !lines.isEmpty else { return }
            Task { @MainActor in lines.forEach { self.handle(line: $0, for: job) } }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self.finish(job, status: status)
            }
        }

        job.started = Date()
        job.finished = nil
        job.state = .running(step: "Getting ready", progress: 0)
        do {
            try process.run()
        } catch {
            job.state = .failed("Could not start: \(error.localizedDescription)")
            startNext()
            return
        }
        self.process = process
        current = job
    }

    /// Whisper is nearly all of the run time, so its progress fills the bar up
    /// to 96%; the short steps after it take the rest.
    private func handle(line: String, for job: Job) {
        guard case .running(let step, let progress) = job.state else { return }
        if line.hasPrefix("PROGRESS "), let fraction = Double(line.dropFirst(9)) {
            job.state = .running(step: step, progress: max(progress, 0.01 + 0.95 * min(max(fraction, 0), 1)))
            return
        }
        job.log += line + "\n"
        switch line {
        case "Transcribing": job.state = .running(step: "Transcribing", progress: max(progress, 0.01))
        case "Timing words": job.state = .running(step: "Timing words", progress: max(progress, 0.96))
        case "Identifying speakers": job.state = .running(step: "Identifying speakers", progress: max(progress, 0.98))
        case "Adding punctuation": job.state = .running(step: "Adding punctuation", progress: max(progress, 0.99))
        default: break
        }
    }

    private func finish(_ job: Job, status: Int32) {
        process = nil
        current = nil
        job.finished = Date()
        if job.state == .stopped {
            // Stopped by the user; nothing to report.
        } else if status == 0, FileManager.default.fileExists(atPath: job.transcriptURL.path) {
            job.state = .done
            // An earlier transcript of the same recording is replaced by this one.
            for old in jobs where old !== job && old.state == .done && old.url == job.url {
                try? FileManager.default.removeItem(at: old.wordsURL)
            }
            jobs.removeAll { $0 !== job && $0.state == .done && $0.url == job.url }
            saveHistory()
            NSApp.requestUserAttention(.informationalRequest)
        } else {
            let logURL = job.url.appendingPathExtension("log")
            job.logURL = (try? job.log.write(to: logURL, atomically: true, encoding: .utf8)) != nil ? logURL : nil
            let lastLine = job.log.split(separator: "\n").last.map(String.init) ?? "No details available."
            job.state = .failed("Could not transcribe this file. \(lastLine)")
        }
        startNext()
    }
}

/// Splits a stream of bytes into lines. Only touched from the pipe's reader queue.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        // Progress bars use \r, so treat it as a line break too.
        while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lines.append(String(decoding: pending[pending.startIndex..<i], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...i)
        }
        return lines
    }
}
