import SwiftUI

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

    private var placement: Binding<TerminalPlacement> {
        Binding(
            get: { TerminalPlacement(rawValue: placementRaw) ?? .bottom },
            set: { placementRaw = $0.rawValue }
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
            }
            Section("Commands") {
                Toggle("Pass --schema to prisma commands", isOn: $includeSchemaArg)
                    .help("Include the detected schema path on every command run.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettingsView: View {
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
                Image(systemName: "hexagon.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .softShadow(radius: 10, y: 5, opacity: 0.10)
            Text("Prismax")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Version 1.0")
                .font(.micro)
                .tracking(0.3)
                .foregroundStyle(.tertiary)
            Text("A native Prisma workflow manager for macOS.")
                .font(.rowSecondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}
