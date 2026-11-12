import AppKit
import SwiftUI

/// Draws the window's content off screen, in light and dark, empty and with
/// sample rows, and writes one PNG per combination.
///
/// If the folder already holds `words.json` and `audio.wav` (a pipeline `--json`
/// file and its recording), the transcript view is drawn from them as well.
@MainActor
func writeSnapshots(to folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var cases: [(String, AnyView)] = [
        ("empty", AnyView(ContentView(queue: JobQueue()))),
        ("jobs", AnyView(ContentView(queue: .preview()))),
    ]
    if let model = TranscriptModel(
        wordsURL: folder.appendingPathComponent("words.json"), audioURL: folder.appendingPathComponent("audio.wav"))
    {
        // Also check that clicking a word really starts playback from there.
        model.play(word: min(40, model.words.count - 1))
        let from = model.time
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        print(String(format: "playback: started at %.2fs, now at %.2fs, word %d highlighted", from, model.time, model.currentWord ?? -1))
        model.togglePlay()
        cases.append(("transcript", AnyView(TranscriptView(model: model))))
    }
    for (name, view) in cases {
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let size = NSSize(width: 520, height: 520)
            let host = NSHostingView(rootView: view
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light))
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))  // let SwiftUI settle
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = bitmap.representation(using: .png, properties: [:])
            try? png?.write(to: folder.appendingPathComponent("\(name)-\(scheme).png"))
        }
    }
}
