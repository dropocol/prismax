import SwiftUI

/// The docked terminal panel shown at the bottom of a project workspace.
/// Owns its toolbar (status, restart, clear, tabs) and embeds the xterm.js view.
struct TerminalPanel: View {
    let project: Project
    let environment: EnvProfile
    var height: CGFloat = 240

    @Environment(TerminalManager.self) private var terminalManager
    @AppStorage("terminalMode") private var terminalModeRaw: String = TerminalMode.persistent.rawValue

    private var terminalMode: TerminalMode {
        TerminalMode(rawValue: terminalModeRaw) ?? .persistent
    }

    private var sessions: [TerminalSession] {
        terminalManager.sessions(for: project)
    }

    private var activeProcess: TerminalProcess {
        terminalManager.terminal(for: project)
    }

    var body: some View {
        let process = activeProcess
        return VStack(spacing: 0) {
            toolbar(process: process)
            // Tab strip — only when there's more than one session.
            if sessions.count > 1 {
                Divider()
                tabStrip
            }
            Divider()
            TerminalView(process: process)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.consoleBody)
        }
        .background(Theme.consoleBody)
        .onAppear {
            // Auto-start the shell when the panel appears.
            terminalManager.start(for: project, environment: environment)
        }
    }

    private func toolbar(process: TerminalProcess) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(process.isRunning ? Theme.success : Theme.warning)
                    .frame(width: 7, height: 7)
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 14)
            Text(project.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            HStack(spacing: 3) {
                Circle().fill(Color(hex: environment.colorHex)).frame(width: 6, height: 6)
                Text(environment.name)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Spacer()
            // New terminal tab (only meaningful in perCommand mode).
            if terminalMode == .perCommand {
                Button {
                    terminalManager.openSession(for: project, title: "Shell")
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("New terminal tab")
            }
            Button {
                process.send("clear\n")
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Clear")
            Button {
                terminalManager.restart(for: project, environment: environment)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Restart shell")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }

    /// Horizontal scrollable tab strip. One chip per session; click to activate,
    /// × to close. Active tab is highlighted with the accent.
    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(sessions) { session in
                    let isActive = sessions.first?.id == session.id
                    tabChip(session: session, isActive: isActive)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Theme.consoleBar.opacity(0.5))
    }

    private func tabChip(session: TerminalSession, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(session.process.isRunning ? Theme.success : Color.secondary.opacity(0.5))
                .frame(width: 5, height: 5)
            Text(session.title)
                .font(.system(size: 10.5, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
            if sessions.count > 1 {
                Button {
                    terminalManager.closeSession(project: project, session: session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Theme.accent.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isActive ? Theme.accent.opacity(0.3) : Color.clear, lineWidth: 0.5)
        )
        .foregroundStyle(isActive ? Theme.accent : .secondary)
        .contentShape(Rectangle())
        .onTapGesture {
            terminalManager.makeActive(project: project, session: session.id)
        }
    }
}

/// Shown when no project is selected (e.g. on the History view or empty state).
struct EmptyTerminalState: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.consoleBar.opacity(0.10))
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    )
                Image(systemName: "terminal")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            Text("No Terminal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Select a project to open its integrated terminal.\nThe active environment's variables are preloaded automatically.")
                .font(.rowSecondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.02))
    }
}
