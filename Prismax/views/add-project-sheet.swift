import SwiftUI

struct AddProjectSheet: View {
    var prefilledURL: URL?
    /// Receives the chosen folder, the (possibly user-edited) detection, and the
    /// selected mode (`isBackupsOnly` true → backups-only, no Prisma tooling).
    var onAdd: (URL, PackageManagerDetector.Detection, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var path: String = ""
    @State private var name: String = ""
    @State private var detection: PackageManagerDetector.Detection?
    @State private var mode: ProjectMode = .prisma

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accent.opacity(0.10))
                        .frame(width: 28, height: 28)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            Text("Add Project")
                    .font(.appTitle)
                    .foregroundStyle(.primary)
            }

            // Mode picker. Backups-only projects skip Prisma command/schema
            // tooling entirely — they just need a folder + a DATABASE_URL (set
            // later via Environments). Drives the detection card visibility.
            VStack(alignment: .leading, spacing: 4) {
                Text("TYPE")
                    .font(.micro)
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                Picker("", selection: $mode) {
                    Text("Prisma Project").tag(ProjectMode.prisma)
                    Text("Backups Only").tag(ProjectMode.backupsOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if mode == .backupsOnly {
                    Text("Backups-only projects skip Prisma commands and schema tooling. Add a DATABASE_URL in Environments after creating.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("NAME")
                    .font(.micro)
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                TextField("Project name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.rowPrimary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("LOCATION")
                    .font(.micro)
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.tertiary)
                    TextField("Project path", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button("Choose…") { chooseFolder() }
                }
            }

            // The detection card is only relevant for Prisma projects.
            // Detection still runs in the background so the detection is ready
            // if the user switches mode back to Prisma, but we don't show it.
            if mode == .prisma, let detection {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text("Package manager: \(detection.packageManager.label)")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PRISMA FOLDER")
                            .font(.micro)
                            .tracking(0.4)
                            .foregroundStyle(.tertiary)
                        // The directory commands run from, relative to the
                        // project root. Empty = run from root. Editable so a
                        // wrong auto-detection (e.g. multiple prisma projects)
                        // can be corrected.
                        TextField("packages/db", text: Binding(
                            get: { detection.prismaDir },
                            set: { self.detection?.prismaDir = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SCHEMA")
                            .font(.micro)
                            .tracking(0.4)
                            .foregroundStyle(.tertiary)
                        TextField("prisma/schema.prisma", text: Binding(
                            get: { detection.schemaPath },
                            set: { self.detection?.schemaPath = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    let url = URL(fileURLWithPath: path)
                    // For backups-only projects, fall back to a default detection
                    // (the prisma-specific fields are inert for the backup flow)
                    // when nothing was detected yet — e.g. the folder had no
                    // lockfile. Prisma projects always have run detection on
                    // folder selection, so detection is non-nil there.
                    let resolved = detection ?? PackageManagerDetector.Detection(
                        packageManager: .npm,
                        prismaDir: "",
                        schemaPath: "prisma/schema.prisma"
                    )
                    onAdd(url, resolved, mode == .backupsOnly)
                    dismiss()
                }
                .disabled(path.isEmpty || name.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            if let prefilledURL { applyURL(prefilledURL) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Project Folder"
        if panel.runModal() == .OK, let url = panel.url {
            applyURL(url)
        }
    }

    private func applyURL(_ url: URL) {
        path = url.path
        if name.isEmpty { name = url.lastPathComponent }
        detection = PackageManagerDetector.detect(at: url.path)
    }
}

/// What kind of project is being added. Drives whether Prisma tooling
/// (commands, schema, detection) is set up, or whether the project exists only
/// to host scheduled backups.
enum ProjectMode: Hashable {
    case prisma
    case backupsOnly
}
