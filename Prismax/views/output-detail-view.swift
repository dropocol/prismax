import SwiftUI

/// The docked terminal panel shown at the bottom of a project workspace.
/// Owns its toolbar (status, restart, clear) and embeds the xterm.js view.
struct TerminalPanel: View {
    let project: Project
    let environment: EnvProfile
    var height: CGFloat = 240

    @Environment(TerminalManager.self) private var terminalManager

    var body: some View {
        let process = terminalManager.terminal(for: project)
        return VStack(spacing: 0) {
            toolbar(process: process)
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
