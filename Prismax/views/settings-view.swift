import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("includeSchemaArg") private var includeSchemaArg = false
    @AppStorage("terminalPlacement") private var placementRaw: String = TerminalPlacement.bottom.rawValue
    @AppStorage("terminalMode") private var terminalModeRaw: String = TerminalMode.persistent.rawValue
    @AppStorage("restoreMode") private var restoreModeRaw: String = RestoreMode.clean.rawValue
    @AppStorage("restoreParallel") private var restoreParallel = true

    /// App-wide default backup folder (mirrors `BackupSettings.globalLocationKey`).
    /// Held as State and refreshed on appear/change since the path is set via
    /// `BackupSettings.setGlobalDefault`, not directly through this @AppStorage.
    @State private var backupLocationURL: URL?

    private var placement: Binding<TerminalPlacement> {
        Binding(
            get: { TerminalPlacement(rawValue: placementRaw) ?? .bottom },
            set: { placementRaw = $0.rawValue }
        )
    }

    private var terminalMode: Binding<TerminalMode> {
        Binding(
            get: { TerminalMode(rawValue: terminalModeRaw) ?? .persistent },
            set: { terminalModeRaw = $0.rawValue }
        )
    }

    private var restoreMode: Binding<RestoreMode> {
        Binding(
            get: { RestoreMode(rawValue: restoreModeRaw) ?? .clean },
            set: { restoreModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Placement", selection: placement) {
                    ForEach(TerminalPlacement.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .help("Where the integrated terminal appears in the project workspace.")
                Picker("Command runs", selection: terminalMode) {
                    ForEach(TerminalMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Whether each command run opens a new terminal tab or reuses the project's single terminal.")
            }
            Section("Commands") {
                Toggle("Pass --schema to prisma commands", isOn: $includeSchemaArg)
                    .help("Include the detected schema path on every command run.")
            }
            Section("Backups") {
                backupsSection
            }
            Section("Restore") {
                Picker("Mode", selection: restoreMode) {
                    ForEach(RestoreMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .help(restoreMode.wrappedValue.help)
                Text(restoreMode.wrappedValue.help)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Toggle("Parallel jobs (compressed backups only)", isOn: $restoreParallel)
                    .help("Restore compressed (.dump) backups using multiple parallel connections — 2–4x faster. Only applies to Postgres .dump files.")
            }
        }
        .formStyle(.grouped)
        .onAppear { backupLocationURL = BackupSettings.globalDefaultURL() }
    }

    /// Global default backup location for all projects (overridable per-project).
    @ViewBuilder
    private var backupsSection: some View {
        if let url = backupLocationURL {
            VStack(alignment: .leading, spacing: 4) {
                Text(url.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Used by projects without their own override.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button("Change…") { chooseBackupFolder() }
            Button("Reset to default") {
                BackupSettings.setGlobalDefault(nil)
                backupLocationURL = nil
            }
        } else {
            Text("Default: \(BackupSettings.builtInDefaultRoot.path)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose Folder…") { chooseBackupFolder() }
                .help("Store all backups in a custom folder (e.g. your repo or an external drive).")
        }
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            BackupSettings.setGlobalDefault(url)
            backupLocationURL = url
        }
    }
}

private struct AboutSettingsView: View {
    @State private var appIcon: NSImage?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 0.5)
                    )
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Image(systemName: "hexagon.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .softShadow(radius: 10, y: 5, opacity: 0.10)
            Text("PrismaX")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Version 0.1.0")
                .font(.micro)
                .tracking(0.3)
                .foregroundStyle(.tertiary)
            Text("A native Prisma workflow manager for macOS.")
                .font(.rowSecondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .onAppear {
            loadAppIcon()
        }
    }

    private func loadAppIcon() {
        if let path = Bundle.main.path(forResource: "app_icon", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            self.appIcon = image
        } else {
            print("Failed to load app_icon.png from bundle")
        }
    }
}
