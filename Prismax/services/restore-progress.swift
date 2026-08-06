import Foundation
import SwiftUI

/// Live, observable state for an in-flight restore. The restore flow appends
/// output chunks and a final status; the progress panel reads these to render
/// a spinner + elapsed timer + live log. One instance per active restore.
@MainActor
@Observable
final class RestoreProgress {
    /// What's being restored and where, shown in the panel header.
    let backupFileName: String
    let destinationName: String

    /// Lines of tool output accumulated so far (stdout + stderr interleaved,
    /// as the tool emits them). Bounded so a runaway log can't grow forever.
    private(set) var logLines: [String] = []
    private let maxLines = 2000

    enum Phase: Equatable { case running, succeeded, failed(String) }
    private(set) var phase: Phase = .running

    /// Wall-clock start/finish for the elapsed timer.
    private(set) var startedAt: Date = .now
    private(set) var finishedAt: Date?

    /// “Now” ticked once per second by the panel's timer so elapsed stays live.
    var now: Date = .now

    init(backupFileName: String, destinationName: String) {
        self.backupFileName = backupFileName
        self.destinationName = destinationName
    }

    var elapsed: TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    var isFinished: Bool {
        if case .running = phase { return false }; return true
    }

    /// Appends a chunk of raw tool output, splitting it into lines. Lines that
    /// don't end in a newline are buffered until the next chunk completes them
    /// (tools often flush partial lines).
    private var partialLine = ""
    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        partialLine += text
        // Split on newlines, keeping any trailing partial line buffered.
        var lines = partialLine.components(separatedBy: "\n")
        partialLine = lines.removeLast()
        for line in lines where !line.isEmpty {
            logLines.append(line)
        }
        // Bound the log so very long restores don't accumulate unbounded UI.
        if logLines.count > maxLines {
            logLines.removeFirst(logLines.count - maxLines)
        }
    }

    func succeed() {
        guard !isFinished else { return }
        if !partialLine.isEmpty { logLines.append(partialLine); partialLine = "" }
        finishedAt = .now
        phase = .succeeded
    }

    func fail(_ message: String) {
        guard !isFinished else { return }
        if !partialLine.isEmpty { logLines.append(partialLine); partialLine = "" }
        finishedAt = .now
        phase = .failed(message)
    }
}
