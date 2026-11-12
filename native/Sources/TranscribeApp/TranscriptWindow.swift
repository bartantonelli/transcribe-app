// The transcript view: read a finished transcript, click any word to hear the
// recording from that point, and follow along as the spoken word is highlighted.
import AVFoundation
import AppKit
import SwiftUI

/// One word of the transcript with where it sits in the recording and in the text.
struct TimedWord {
    var start: Double  // seconds
    var end: Double
    var range: NSRange  // in the displayed text
}

/// What the pipeline's --json file holds: [word, start_ms, end_ms, speaker] rows.
struct WordsFile: Decodable {
    struct Row: Decodable {
        var text: String
        var start: Double
        var end: Double
        var speaker: Int

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            text = try c.decode(String.self)
            start = try c.decode(Double.self) / 1000
            end = try c.decode(Double.self) / 1000
            speaker = try c.decode(Int.self)
        }
    }

    var duration: Double
    var words: [Row]
}

@MainActor
final class TranscriptModel: ObservableObject {
    let title: String
    let text: NSAttributedString
    let words: [TimedWord]
    let hasAudio: Bool
    let duration: Double

    @Published var isPlaying = false
    @Published var time: Double = 0
    /// Index into `words` of the word being spoken, if any.
    @Published var currentWord: Int?

    private let player: AVPlayer?
    private var observer: Any?

    convenience init?(job: Job) {
        self.init(wordsURL: job.wordsURL, audioURL: job.url)
    }

    init?(wordsURL: URL, audioURL: URL) {
        guard let data = try? Data(contentsOf: wordsURL),
              let file = try? JSONDecoder().decode(WordsFile.self, from: data) else { return nil }
        title = audioURL.lastPathComponent
        duration = file.duration
        (text, words) = Self.layOut(file.words)

        hasAudio = FileManager.default.fileExists(atPath: audioURL.path)
        player = hasAudio ? AVPlayer(url: audioURL) : nil
        observer = player?.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    /// Same layout as the .txt file: a paragraph per speaker turn.
    private static func layOut(_ rows: [WordsFile.Row]) -> (NSAttributedString, [TimedWord]) {
        let body = NSFont.systemFont(ofSize: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 14
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let palette: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal]

        let text = NSMutableAttributedString()
        var words: [TimedWord] = []
        var speaker: Int?
        for row in rows {
            if row.speaker != speaker {
                if speaker != nil { text.append(NSAttributedString(string: "\n", attributes: bodyAttributes)) }
                speaker = row.speaker
                text.append(NSAttributedString(
                    string: "Speaker \(row.speaker)  ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: palette[abs(row.speaker) % palette.count],
                        .paragraphStyle: paragraph,
                    ]))
            } else {
                text.append(NSAttributedString(string: " ", attributes: bodyAttributes))
            }
            let word = row.text.trimmingCharacters(in: .whitespaces)
            words.append(TimedWord(
                start: row.start, end: row.end,
                range: NSRange(location: text.length, length: (word as NSString).length)))
            text.append(NSAttributedString(string: word, attributes: bodyAttributes))
        }
        return (text, words)
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if time >= duration - 0.2 { seek(to: 0) }
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), duration)
        time = target
        currentWord = wordIndex(at: target)
        player?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Clicking a word plays from just before it, so its first sound isn't clipped.
    func play(word index: Int) {
        guard player != nil, words.indices.contains(index) else { return }
        seek(to: words[index].start - 0.15)
        currentWord = index
        if !isPlaying { togglePlay() }
    }

    func stop() {
        player?.pause()
        isPlaying = false
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
    }

    func wordIndex(atCharacter location: Int) -> Int? {
        words.firstIndex { NSLocationInRange(location, $0.range) }
    }

    private func tick(_ seconds: Double) {
        guard isPlaying, seconds.isFinite else { return }
        time = seconds
        let index = wordIndex(at: seconds)
        if index != currentWord { currentWord = index }
        if seconds >= duration - 0.05 {
            player?.pause()
            isPlaying = false
        }
    }

    /// The last word that has started by `seconds` (binary search; words are in time order).
    private func wordIndex(at seconds: Double) -> Int? {
        var low = 0, high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid].start <= seconds { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}

struct TranscriptView: View {
    @ObservedObject var model: TranscriptModel

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            TranscriptText(model: model)
        }
    }

    @ViewBuilder private var controls: some View {
        if model.hasAudio {
            HStack(spacing: 12) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18, height: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                Text(clock(model.time)).monospacedDigit().foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { model.time }, set: { model.seek(to: $0) }),
                    in: 0...max(model.duration, 1))
                Text(clock(model.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .overlay(alignment: .bottom) {
                Text("Click any word to listen from there.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .offset(y: 14)
            }
            .padding(.bottom, 12)
        } else {
            Label(
                "The recording has been moved or deleted, so it can't be played. The transcript is still here.",
                systemImage: "speaker.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The transcript as selectable text. A plain click on a word plays from it;
/// dragging still selects text for copying.
struct TranscriptText: NSViewRepresentable {
    @ObservedObject var model: TranscriptModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.textStorage?.setAttributedString(model.text)
        scroll.drawsBackground = false
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        textView.addGestureRecognizer(click)
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.highlight(model.currentWord, follow: model.isPlaying)
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: TranscriptModel
        weak var textView: NSTextView?
        private var highlighted: Int?

        init(model: TranscriptModel) { self.model = model }

        @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            var point = recognizer.location(in: textView)
            point.x -= textView.textContainerOrigin.x
            point.y -= textView.textContainerOrigin.y
            var fraction: CGFloat = 0
            let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
            // Ignore clicks in the margins or past the end of a line.
            guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return }
            let character = layout.characterIndexForGlyph(at: glyph)
            if let index = model.wordIndex(atCharacter: character) {
                model.play(word: index)
            }
        }

        func highlight(_ index: Int?, follow: Bool) {
            guard index != highlighted, let textView, let layout = textView.layoutManager else { return }
            if let old = highlighted, model.words.indices.contains(old) {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: model.words[old].range)
            }
            highlighted = index
            guard let index, model.words.indices.contains(index) else { return }
            let range = model.words[index].range
            layout.addTemporaryAttribute(
                .backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.3), forCharacterRange: range)
            // Keep the spoken word on screen while playing, without fighting manual scrolling much.
            if follow, let container = textView.textContainer {
                var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                rect.origin.y += textView.textContainerOrigin.y
                if !textView.visibleRect.insetBy(dx: 0, dy: 30).intersects(rect) {
                    textView.scrollToVisible(rect.insetBy(dx: 0, dy: -120))
                }
            }
        }
    }
}

/// One transcript window per recording; opening it again brings it forward.
@MainActor
final class TranscriptWindows: NSObject, NSWindowDelegate {
    static let shared = TranscriptWindows()
    private var open: [UUID: (window: NSWindow, model: TranscriptModel)] = [:]

    func open(_ job: Job) {
        if let existing = open[job.id] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = TranscriptModel(job: job) else {
            // No word timings (they were cleared): fall back to the text file.
            NSWorkspace.shared.open(job.transcriptURL)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = model.title
        window.contentMinSize = NSSize(width: 420, height: 320)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TranscriptView(model: model))
        window.identifier = NSUserInterfaceItemIdentifier(job.id.uuidString)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        open[job.id] = (window, model)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = window.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        open[id]?.model.stop()
        open[id] = nil
    }
}
