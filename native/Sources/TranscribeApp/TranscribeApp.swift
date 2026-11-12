// Transcribe — the app's window. Drop recordings in, watch progress, open the
// transcript. All the work is done by the bundled pipeline (Resources/pipeline.py),
// run one recording at a time as a child process; nothing here uses the network.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Transcribe", id: "main") {
            ContentView(queue: .shared)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Recordings…") { JobQueue.shared.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the app icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in JobQueue.shared.add(urls) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `Transcribe --snapshot <folder>` draws the window to PNG files and quits
        // (used to check the layout without needing screen-recording permission).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { writeSnapshots(to: URL(fileURLWithPath: args[i + 1])) }
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { JobQueue.shared.loadHistoryOnce() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = MainActor.assumeIsolated { JobQueue.shared.isBusy }
        guard busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A recording is still being transcribed."
        alert.informativeText = "Quitting now stops it. Finished transcripts are already saved."
        alert.addButton(withTitle: "Keep Going")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        MainActor.assumeIsolated { JobQueue.shared.stopAll() }
        return .terminateNow
    }
}

struct ContentView: View {
    @ObservedObject var queue: JobQueue
    // Kept on the queue object rather than in @State: @State is a macro whose
    // compiler plugin ships only with full Xcode, not the Command Line Tools.
    private var dropTargeted: Bool { queue.dropTargeted }

    var body: some View {
        VStack(spacing: 0) {
            dropZone
                .padding(16)
            if !queue.jobs.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(queue.jobs) { job in
                            JobRow(job: job, queue: queue)
                            Divider()
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
            Divider()
            HStack {
                Image(systemName: "lock.fill")
                Text("Runs entirely on this Mac. Nothing is uploaded.")
                Spacer()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls)
            return true
        } isTargeted: { queue.dropTargeted = $0 }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: queue.jobs.isEmpty ? 44 : 28, weight: .light))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            Text("Drop recordings here")
                .font(queue.jobs.isEmpty ? .title2 : .headline)
            if queue.jobs.isEmpty {
                Text("Audio or video. The transcript, with speaker labels, is saved next to each file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Choose Files…") { queue.chooseFiles() }
        }
        .padding(queue.jobs.isEmpty ? 32 : 16)
        .frame(maxWidth: .infinity, maxHeight: queue.jobs.isEmpty ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    let queue: JobQueue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .font(.title2)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: Image(systemName: "waveform").foregroundStyle(Color.accentColor)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .waiting:
            Text("Waiting").font(.callout).foregroundStyle(.secondary)
        case .running(let step, let progress):
            ProgressView(value: progress)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(runningCaption(step: step, progress: progress, now: context.date))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .done:
            Text(doneCaption)
                .font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(3)
        case .stopped:
            Text("Stopped").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .waiting:
            Button("Remove") { queue.remove(job) }
        case .running:
            Button("Stop") { queue.stop(job) }
        case .done:
            HStack(spacing: 6) {
                Button("Open Transcript") { TranscriptWindows.shared.open(job) }
                Menu {
                    Button("Show in Finder") {
                        let file = FileManager.default.fileExists(atPath: job.transcriptURL.path) ? job.transcriptURL : job.url
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    Button("Open Text File") { NSWorkspace.shared.open(job.transcriptURL) }
                    Button("Transcribe Again") { queue.add([job.url]) }
                    Divider()
                    Button("Remove from List") { queue.remove(job) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        case .failed:
            VStack(alignment: .trailing, spacing: 4) {
                Button("Try Again") { queue.retry(job) }
                HStack(spacing: 10) {
                    if let log = job.logURL {
                        Button("Show Details") { NSWorkspace.shared.open(log) }
                    }
                    Button("Remove") { queue.remove(job) }
                }
                .buttonStyle(.link)
            }
        case .stopped:
            VStack(alignment: .trailing, spacing: 4) {
                Button("Start Again") { queue.retry(job) }
                Button("Remove") { queue.remove(job) }
                    .buttonStyle(.link)
            }
        }
    }

    private var doneCaption: String {
        let took = clock(job.elapsed(until: job.finished ?? .now))
        guard job.fromHistory, let finished = job.finished else {
            return "Done in \(took). Saved next to the recording."
        }
        return "\(finished.formatted(date: .abbreviated, time: .shortened)) · took \(took)"
    }

    private func runningCaption(step: String, progress: Double, now: Date) -> String {
        let elapsed = job.elapsed(until: now)
        var text = "\(step) · \(clock(elapsed))"
        // Only estimate once there is enough progress for the estimate to be steady.
        if progress >= 0.08, elapsed >= 20 {
            let remaining = elapsed / progress - elapsed
            text += " · about \(roughDuration(remaining)) left"
        }
        return text
    }
}

func clock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

func roughDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes < 1 { return "a minute" }
    if minutes == 1 { return "1 minute" }
    if minutes < 60 { return "\(minutes) minutes" }
    return String(format: "%d h %02d min", minutes / 60, minutes % 60)
}
