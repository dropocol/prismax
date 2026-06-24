import SwiftUI
import SwiftData

struct CommandsTab: View {
    let project: Project
    let environment: EnvProfile
    let onRun: (Command) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var editingCommand: Command?
    @State private var showingAddCommand = false

    private var groupedCommands: [(CommandCategory, [Command])] {
        let sorted = project.commands.sorted(by: { $0.orderIndex < $1.orderIndex })
        return CommandCategory.allCases.compactMap { category in
            let items = sorted.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                prismaFolderSection
                ForEach(groupedCommands, id: \.0) { category, commands in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: category.symbol)
                                .font(.system(size: 10, weight: .semibold))
                            Text(category.label.uppercased())
                                .font(.micro)
                                .tracking(0.5)
                        }
                        .foregroundStyle(.tertiary)

                        VStack(spacing: 6) {
                            ForEach(commands) { command in
                                CommandRow(command: command, environment: environment) {
                                    onRun(command)
                                } onEdit: {
                                    editingCommand = command
                                } onDelete: {
                                    delete(command)
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Spacer()
                Button {
                    showingAddCommand = true
                } label: {
                    Label("Add Command", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.trailing, 18)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingAddCommand) {
            CommandEditorSheet(project: project, command: nil)
        }
        .sheet(item: $editingCommand) { command in
            CommandEditorSheet(project: project, command: command)
        }
    }

    private func delete(_ command: Command) {
        modelContext.delete(command)
        try? modelContext.save()
    }

    // MARK: Prisma folder

    /// Editable path to the folder commands run from, relative to the project
    /// root. Empty = run from the root. Auto-detected at add-time; editable here
    /// so an existing project (or a wrong detection) can be corrected.
    private var prismaFolderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                Text("PRISMA FOLDER")
                    .font(.micro)
                    .tracking(0.5)
                Spacer()
                Button("Re-detect", systemImage: "magnifyingglass") {
                    redetect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                TextField("packages/db", text: Binding(
                    get: { project.prismaDir ?? "" },
                    set: { project.prismaDir = $0.isEmpty ? nil : $0; try? modelContext.save() }
                ), prompt: Text("(project root)"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            Text("Directory commands run from (relative to the project root). Empty runs from the root. Schema: \(project.schemaPath.isEmpty ? "prisma/schema.prisma" : project.schemaPath)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    /// Re-runs auto-discovery on the existing project, updating the prisma
    /// folder, schema path, and package manager from the current filesystem.
    private func redetect() {
        let detection = PackageManagerDetector.detect(at: project.path)
        project.prismaDir = detection.prismaDir.isEmpty ? nil : detection.prismaDir
        project.schemaPath = detection.schemaPath
        project.packageManager = detection.packageManager
        try? modelContext.save()
    }
}

/// A single command as a clean row: icon · name · args … [▶ play button]
private struct CommandRow: View {
    let command: Command
    let environment: EnvProfile
    let onRun: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private var level: GuardrailLevel {
        command.guardrails.first(where: { $0.environment?.id == environment.id })?.level ?? .allowed
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accent.opacity(isHovering ? 0.14 : 0.08))
                    .frame(width: 28, height: 28)
                Image(systemName: command.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(.rowPrimary)
                    .foregroundStyle(.primary)
                Text("prisma " + command.prismaArgs)
                    .font(.mono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            levelBadge
            playButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Theme.cardFillStrong : Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .contextMenu {
            Button("Run", systemImage: "play") { onRun() }
            Button("Edit…", systemImage: "pencil") { onEdit() }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
        }
        .onHover { isHovering = $0 && level != .blocked }
        .help(level == .blocked ? "Blocked on \(environment.name) — adjust in Environments." : "Run")
        .opacity(level == .blocked ? 0.45 : 1)
        .animation(.snappy(duration: 0.15), value: isHovering)
    }

    private var playButton: some View {
        Button(action: onRun) {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(level == .blocked ? Color.secondary.opacity(0.25) : Theme.accent)
                )
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )
                .softShadow(radius: 2, y: 1, opacity: 0.12)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(level == .blocked)
    }

    @ViewBuilder
    private var levelBadge: some View {
        if level != .allowed {
            HStack(spacing: 3) {
                Image(systemName: level.symbol)
                    .font(.system(size: 8, weight: .semibold))
                Text(level.label)
                    .font(.micro)
                    .tracking(0.3)
            }
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(badgeColor.opacity(0.12)))
            .foregroundStyle(badgeColor)
        }
    }

    private var badgeColor: Color {
        switch level {
        case .allowed: .secondary
        case .confirm: Theme.warning
        case .blocked: Theme.danger
        }
    }
}

// MARK: - Command editor sheet

struct CommandEditorSheet: View {
    let project: Project
    var command: Command? // nil = creating new

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prismaArgs = ""
    @State private var category: CommandCategory = .custom
    @State private var symbolName = "terminal"

    private var isEditing: Bool { command != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !prismaArgs.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Command" : "New Command")
                .font(.appTitle)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 4) {
                Text("NAME").font(.micro).tracking(0.4).foregroundStyle(.tertiary)
                TextField("Migrate Diff", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.rowPrimary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("PRISMA ARGS").font(.micro).tracking(0.4).foregroundStyle(.tertiary)
                TextField("migrate diff", text: $prismaArgs)
                    .textFieldStyle(.roundedBorder)
                    .font(.rowPrimary)
                Text("Everything that comes after `prisma`.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CATEGORY").font(.micro).tracking(0.4).foregroundStyle(.tertiary)
                Picker("", selection: $category) {
                    ForEach(CommandCategory.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("ICON (SF SYMBOL)").font(.micro).tracking(0.4).foregroundStyle(.tertiary)
                HStack {
                    TextField("terminal", text: $symbolName)
                        .textFieldStyle(.roundedBorder)
                        .font(.rowPrimary)
                    Image(systemName: symbolName.isEmpty ? "terminal" : symbolName)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(isEditing ? "Save" : "Add") {
                    save()
                    dismiss()
                }
                .disabled(!canSave)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { populate() }
    }

    private func populate() {
        if let command {
            name = command.name
            prismaArgs = command.prismaArgs
            category = command.category
            symbolName = command.symbolName
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedArgs = prismaArgs.trimmingCharacters(in: .whitespaces)
        if let command {
            command.name = trimmedName
            command.prismaArgs = trimmedArgs
            command.category = category
            command.symbolName = symbolName.isEmpty ? "terminal" : symbolName
        } else {
            let orderIndex = (project.commands.map(\.orderIndex).max() ?? -1) + 1
            let newCommand = Command(
                name: trimmedName,
                prismaArgs: trimmedArgs,
                category: category,
                symbolName: symbolName.isEmpty ? "terminal" : symbolName,
                orderIndex: orderIndex
            )
            newCommand.project = project
            modelContext.insert(newCommand)
        }
        try? modelContext.save()
    }
}
