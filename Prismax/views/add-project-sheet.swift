import SwiftUI

struct AddProjectSheet: View {
    var prefilledURL: URL?
    /// Receives the chosen folder plus the (possibly user-edited) detection.
    var onAdd: (URL, PackageManagerDetector.Detection) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var path: String = ""
    @State private var name: String = ""
    @State private var detection: PackageManagerDetector.Detection?

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

            if let detection {
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
                    // Carry the (possibly edited) detection so addProject
                    // doesn't re-run auto-detection and clobber the values.
                    if let detection {
                        onAdd(url, detection)
                    }
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
