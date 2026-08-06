import SwiftUI
import SwiftData

struct EnvironmentsTab: View {
    let project: Project
    let environment: EnvProfile

    @Environment(\.modelContext) private var modelContext
    @State private var showingAddVariable = false
    @State private var showingImportEnv = false
    @State private var showingAddEnvironment = false
    @State private var revealedKeys: Set<UUID> = []

    private var sortedVariables: [EnvVariable] {
        environment.variables.sorted(by: { $0.key < $1.key })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                envFileSection
                variablesSection
                // Guardrails gate Prisma command execution against this
                // environment — meaningless for backups-only projects (which
                // have no commands), so hide the section there.
                if !project.isBackupsOnly {
                    Divider()
                    GuardrailsSection(project: project, environment: environment)
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showingAddVariable) {
            AddVariableSheet(environment: environment) { key, value in
                addVariable(key: key, value: value)
            }
        }
        .sheet(isPresented: $showingImportEnv) {
            ImportEnvSheet(environment: environment) { pairs in
                importVariables(pairs: pairs)
            }
        }
        .sheet(isPresented: $showingAddEnvironment) {
            AddEnvironmentSheet(project: project)
        }
        .onReceive(NotificationCenter.default.publisher(for: .addEnvironment)) { note in
            if note.object as? UUID == project.id { showingAddEnvironment = true }
        }
    }

    // MARK: Variables section

    private var variablesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                Text("VARIABLES")
                    .font(.micro)
                    .tracking(0.5)
                Spacer()
                Button("Import .env", systemImage: "square.and.arrow.down") {
                    showingImportEnv = true
                }
                Button("Add", systemImage: "plus") { showingAddVariable = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .foregroundStyle(.tertiary)

            if sortedVariables.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No variables yet.")
                        .font(.rowPrimary)
                        .foregroundStyle(.secondary)
                    Text("Add DATABASE_URL and any others Prisma needs, or import a `.env` file.")
                        .font(.rowSecondary)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            } else {
                VStack(spacing: 6) {
                    ForEach(sortedVariables) { variable in
                        VariableRow(variable: variable,
                                    revealed: revealedKeys.contains(variable.id)) {
                            toggleReveal(variable.id)
                        } onDelete: {
                            deleteVariable(variable)
                        }
                    }
                }
            }
        }
    }

    // MARK: Env file section

    private var envFileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11, weight: .semibold))
                Text("ENV FILE")
                    .font(.micro)
                    .tracking(0.5)
            }
            .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                TextField(".env path (relative)", text: Binding(
                    get: { environment.envFilePath ?? "" },
                    set: { environment.envFilePath = $0.isEmpty ? nil : $0; try? modelContext.save() }
                ), prompt: Text(".env.production"))
                    .textFieldStyle(.roundedBorder)
                    .font(.rowPrimary)
                Button("Browse…") { chooseEnvFile() }
            }
            Text("If set, this file is loaded (like `dotenv -e`) before commands run. Keychain variables take precedence over it.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func chooseEnvFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.path)
        panel.prompt = "Select .env File"
        if panel.runModal() == .OK, let url = panel.url {
            // Store as a path relative to the project root when possible.
            let projectPath = project.path
            let absolute = url.path
            if absolute.hasPrefix(projectPath) {
                environment.envFilePath = String(absolute.dropFirst(projectPath.count + 1))
            } else {
                environment.envFilePath = absolute
            }
            try? modelContext.save()
        }
    }

    // MARK: Actions

    private func toggleReveal(_ id: UUID) {
        if revealedKeys.contains(id) { revealedKeys.remove(id) } else { revealedKeys.insert(id) }
    }

    private func addVariable(key: String, value: String) {
        let account = keychainAccount(project: project, environment: environment, key: key)
        do {
            try KeychainService.set(account: account, value: value)
        } catch {
            print("Keychain error: \(error)")
            return
        }
        let variable = EnvVariable(key: key, keychainAccount: account)
        variable.environment = environment
        modelContext.insert(variable)
        try? modelContext.save()
    }

    private func importVariables(pairs: [EnvFileImporter.Pair]) {
        for pair in pairs {
            addVariable(key: pair.key, value: pair.value)
        }
    }

    private func deleteVariable(_ variable: EnvVariable) {
        try? KeychainService.delete(account: variable.keychainAccount)
        modelContext.delete(variable)
        try? modelContext.save()
    }

    private func keychainAccount(project: Project, environment: EnvProfile, key: String) -> String {
        "prismax:\(project.id.uuidString):\(environment.id.uuidString):\(key)"
    }
}

private struct VariableRow: View {
    let variable: EnvVariable
    let revealed: Bool
    let onToggleReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.tertiary)
                .font(.system(size: 10))
            Text(variable.key)
                .font(.rowPrimary)
                .foregroundStyle(.primary)
            Spacer()
            Text(revealed
                 ? (try? KeychainService.get(account: variable.keychainAccount)) ?? "—"
                 : KeychainService.maskedValue(account: variable.keychainAccount))
                .foregroundStyle(.secondary)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onToggleReveal) {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .cardStyle(cornerRadius: 8)
    }
}

// MARK: - Sheets

private struct AddVariableSheet: View {
    let environment: EnvProfile
    let onAdd: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Variable").font(.appTitle).foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 4) {
                Text("KEY").font(.micro).tracking(0.4).foregroundStyle(.tertiary)
                TextField("Key", text: $key, prompt: Text("DATABASE_URL"))
                    .textFieldStyle(.roundedBorder)
                    .font(.rowPrimary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("VALUE").font(.micro).tracking(0.4).foregroundStyle(.tertiary)
                SecureField("Value", text: $value, prompt: Text("postgresql://…"))
                    .textFieldStyle(.roundedBorder)
                    .font(.rowPrimary)
            }
            Label("Stored in the macOS Keychain — never written to disk.",
                  systemImage: "lock.shield")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    onAdd(key.trimmingCharacters(in: .whitespaces), value)
                    dismiss()
                }
                .disabled(key.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct ImportEnvSheet: View {
    let environment: EnvProfile
    let onImport: ([EnvFileImporter.Pair]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var detected: [EnvFileImporter.Pair] { EnvFileImporter.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from .env").font(.appTitle).foregroundStyle(.primary)
            Text("Paste the contents of a `.env` file. Each KEY=VALUE pair becomes a Keychain entry for this environment.")
                .font(.rowSecondary)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(Theme.consoleBody.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                )

            HStack {
                Text("\(detected.count) variables detected")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Import") {
                    onImport(detected)
                    dismiss()
                }
                .disabled(detected.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct AddEnvironmentSheet: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var colorHex = "#5B5ECC"

    private let palette = ["#5B5ECC", "#34C759", "#FF9500", "#FF3B30", "#AF52DE", "#5856D6", "#FFCC00", "#8E8E93"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Environment").font(.appTitle).foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text("NAME").font(.micro).tracking(0.4).foregroundStyle(.tertiary)
                TextField("Name", text: $name, prompt: Text("staging"))
                    .textFieldStyle(.roundedBorder)
                    .font(.rowPrimary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("COLOR").font(.micro).tracking(0.4).foregroundStyle(.tertiary)
                HStack(spacing: 10) {
                    ForEach(palette, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().strokeBorder(.white.opacity(colorHex == hex ? 0.95 : 0), lineWidth: 2)
                            )
                            .overlay(
                                Circle().strokeBorder(Theme.hairline, lineWidth: 0.5)
                            )
                            .softShadow(radius: colorHex == hex ? 3 : 0, y: 1, opacity: 0.2)
                            .scaleEffect(colorHex == hex ? 1.1 : 1)
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.15)) { colorHex = hex }
                            }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    add()
                    dismiss()
                }
                .disabled(name.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func add() {
        let orderIndex = (project.environments.map(\.orderIndex).max() ?? -1) + 1
        let env = EnvProfile(name: name, colorHex: colorHex, orderIndex: orderIndex)
        env.project = project
        modelContext.insert(env)
        try? modelContext.save()
    }
}
