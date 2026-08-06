import SwiftUI

/// Side inspector shown during a restore: spinner + elapsed timer + a live,
/// auto-scrolling log of the restore tool's output. Reads an observable
/// `RestoreProgress` that the restore flow updates as chunks arrive.
///
/// Deliberately shows no fake percentage — `pg_restore`/`psql` don't emit a
/// progress fraction, so we show what's actually happening (each line the tool
/// prints) plus honest elapsed time, and a clear succeeded/failed end state.
struct RestoreProgressPanel: View {
    @Bindable var progress: RestoreProgress
    var onDismiss: () -> Void

    @State private var elapsedTimer: Timer?
    /// Whether the log should auto-scroll to the newest line. Starts true; flips
    /// to false the moment the user scrolls up to read, and snaps back to true
    /// when they return to the bottom (or hit the "Jump to latest" button).
    @State private var sticksToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logView
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { startTimer() }
        .onDisappear { elapsedTimer?.invalidate() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.phase.isRunning ? "Restoring" : "Restore complete")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(progress.backupFileName)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            // Copy the entire log to the pasteboard — handy for sharing the full
            // pg_restore/psql output (often hundreds of lines) in a bug report.
            Button {
                let all = progress.logLines.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(all, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Copy entire log")
            // Elapsed timer, ticking once/sec via `progress.now`.
            Text(progress.elapsed, format: .number.precision(.fractionLength(0)).grouping(.never))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            + Text("s")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch progress.phase {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
        }
    }

    // MARK: Live log

    private var logView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    // A real terminal-feel log: monospaced, dense. Grows downward;
                    // we only auto-scroll while `sticksToBottom` is true.
                    VStack(alignment: .leading, spacing: 1) {
                        if progress.logLines.isEmpty {
                            Text("Waiting for output…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(progress.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(logColor(for: line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled) // click-drag to select a range
                                    .contextMenu {
                                        Button("Copy line") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(line, forType: .string)
                                        }
                                    }
                                    .id(idx)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.consoleBody)
                // Live scroll tracking: if the user isn't pinned to the bottom,
                // stop auto-scrolling so they can read undisturbed. When they
                // scroll back down, re-arm auto-scroll.
                .onScrollGeometryChange(for: Double.self) { geo in
                    // Distance from the bottom of the scrollable content. NSScrollView
                    // reports contentInsets in platform coords; we approximate
                    // "near the bottom" with a small tolerance.
                    let bottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                    return bottom
                } action: { oldValue, newValue in
                    let nearBottom = abs(newValue) < 24
                    if nearBottom != sticksToBottom {
                        sticksToBottom = nearBottom
                    }
                }
                .onChange(of: progress.logLines.count) { _, _ in
                    guard sticksToBottom else { return }
                    withAnimation(.snappy(duration: 0.15)) {
                        proxy.scrollTo(progress.logLines.count - 1, anchor: .bottom)
                    }
                }

                // Floating "jump to latest" button — appears only after the user
                // scrolls up, so they can snap back and re-arm auto-scroll.
                if !sticksToBottom && !progress.logLines.isEmpty {
                    Button {
                        sticksToBottom = true
                        withAnimation(.snappy(duration: 0.15)) {
                            proxy.scrollTo(progress.logLines.count - 1, anchor: .bottom)
                        }
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(10)
                }
            }
        }
    }

    /// Subtle color hinting: lines that look like errors/warnings stand out, so
    /// a failure in the middle of a long verbose log is easy to spot.
    private func logColor(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("fatal") { return Theme.danger }
        if lower.contains("warning") { return Theme.warning }
        return Color.primary.opacity(0.85)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if case .failed(let msg) = progress.phase {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(msg, forType: .string)
                } label: {
                    Label("Copy error", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
            if progress.isFinished {
                Button("Close", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Timer

    /// Ticks `progress.now` once per second so the elapsed counter advances
    /// without the restore flow having to touch the model on a cadence.
    private func startTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            progress.now = Date.now
        }
    }
}

private extension RestoreProgress.Phase {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
