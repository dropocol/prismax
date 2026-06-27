import SwiftUI

struct SchemaTab: View {
    let project: Project
    let environment: EnvProfile

    /// Parsed schema (models/enums/generators). Read from disk — local and
    /// near-instant, so it renders immediately on tab open / project switch.
    @State private var schema: SchemaParser.Schema?
    /// Migration status, which shells out `prisma migrate status` and may hit
    /// the network. Loaded independently so a slow/offline check never blocks
    /// the schema above it.
    @State private var migrateStatus: SchemaService.MigrateStatus?
    /// True only while `prisma migrate status` runs. Scoped to that section so
    /// its spinner stays local — the rest of the tab keeps showing.
    @State private var isLoadingStatus = false
    @State private var loadError: String?
    @State private var expandedModels: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                if let error = loadError {
                    errorView(error)
                } else {
                    if let schema {
                        schemaSummary(schema)
                        migrateStatusSection
                        modelsSection(schema)
                        enumsSection(schema)
                    } else {
                        ProgressView("Reading schema…")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
            }
            .padding(16)
        }
        .onAppear { loadIfNeeded() }
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
            Text("SCHEMA")
                .font(.micro)
                .tracking(0.5)
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { refreshStatus() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoadingStatus)
        }
        .foregroundStyle(.tertiary)
    }

    // MARK: Summary

    @ViewBuilder
    private func schemaSummary(_ schema: SchemaParser.Schema) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            StatCard(title: "Models", value: "\(schema.models.count)", symbol: "tablecells")
            StatCard(title: "Enums", value: "\(schema.enums.count)", symbol: "list.bullet")
            StatCard(title: "Generators", value: "\(schema.generators.count)", symbol: "wand.and.stars")
        }
    }

    // MARK: Migrate status

    @ViewBuilder
    private var migrateStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                sectionLabel("Migration Status", symbol: "arrow.triangle.swap")
                if isLoadingStatus {
                    ProgressView().controlSize(.small)
                }
            }

            if let status = migrateStatus {
                HStack(spacing: 8) {
                    StatusPill(label: "Applied", value: status.appliedCount, color: Theme.success)
                    StatusPill(label: "Pending", value: status.pendingCount, color: Theme.warning)
                    Spacer()
                }

                if let url = status.databaseURLMasked {
                    Label(url, systemImage: "link")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !status.output.isEmpty {
                    Text(status.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.consoleBody, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .textSelection(.enabled)
                }
            } else if !isLoadingStatus {
                Text("Migration status unavailable.")
                    .font(.rowSecondary)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Models

    @ViewBuilder
    private func modelsSection(_ schema: SchemaParser.Schema) -> some View {
        if schema.models.isEmpty { EmptyView() }
        else {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Models", symbol: "tablecells")
                VStack(spacing: 6) {
                    ForEach(schema.models) { model in
                        ModelRow(model: model, isExpanded: expandedModels.contains(model.id)) {
                            toggle(model.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: Enums

    @ViewBuilder
    private func enumsSection(_ schema: SchemaParser.Schema) -> some View {
        if schema.enums.isEmpty { EmptyView() }
        else {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Enums", symbol: "list.bullet")
                VStack(spacing: 6) {
                    ForEach(schema.enums) { e in
                        EnumRow(modelEnum: e)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(title.uppercased())
                .font(.micro)
                .tracking(0.5)
        }
        .foregroundStyle(.tertiary)
    }

    // MARK: Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.warning)
            Text("Could not read schema")
                .font(.rowPrimary)
                .foregroundStyle(.primary)
            Text(message)
                .font(.rowSecondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: Logic

    /// On first appear: read the schema from disk (instant) and kick off the
    /// migration status check in the background. The two run independently so a
    /// slow/offline status check never delays the schema rendering.
    private func loadIfNeeded() {
        if schema == nil { loadSchema() }
        if migrateStatus == nil { refreshStatus() }
    }

    /// Reads & parses `schema.prisma` off the main actor (it touches the
    /// filesystem) and shows it the moment it's ready.
    private func loadSchema() {
        let path = project.path
        let schemaPath = project.schemaPath
        Task {
            let parsed = await Task.detached(priority: .userInitiated) {
                SchemaService.readSchema(path: path, schemaPath: schemaPath)
            }.value
            await MainActor.run { schema = parsed }
        }
    }

    /// Runs `prisma migrate status` and updates only the migration status block.
    /// Its spinner is scoped to that section, so the schema above stays visible
    /// while this runs. A timeout in `ShellRunner` ensures an unreachable DB
    /// can't spin this forever.
    private func refreshStatus() {
        isLoadingStatus = true
        let snap = SchemaService.snapshot(project: project, environment: environment)
        Task {
            // `runMigrateStatus` re-reads the schema to mask the datasource URL;
            // cheap relative to the network call it wraps.
            let status = await SchemaService.runMigrateStatus(
                snapshot: snap,
                schema: SchemaService.readSchema(path: snap.path, schemaPath: snap.schemaPath)
            )
            await MainActor.run {
                migrateStatus = status
                isLoadingStatus = false
            }
        }
    }

    private func toggle(_ id: String) {
        if expandedModels.contains(id) { expandedModels.remove(id) } else { expandedModels.insert(id) }
    }
}

// MARK: - Subviews

private struct StatCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 18, weight: .bold))
                Text(title.uppercased())
                    .font(.micro)
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(12)
        .cardStyle()
    }
}

private struct StatusPill: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill").font(.system(size: 6))
            Text("\(value) \(label)")
                .font(.micro)
                .tracking(0.3)
        }
        .textCase(.uppercase)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundStyle(color)
    }
}

private struct ModelRow: View {
    let model: SchemaParser.Model
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: model.isView ? "eye" : "tablecells")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    Text(model.name)
                        .font(.rowPrimary)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(model.fields.count) fields")
                        .font(.micro)
                        .tracking(0.3)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.fields, id: \.self) { field in
                        FieldRow(field: field)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 3.5)
                    }
                }
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.02))
            }
        }
        .cardStyle()
    }
}

private struct FieldRow: View {
    let field: SchemaParser.Field

    var body: some View {
        HStack(spacing: 6) {
            Text(field.name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            Text(field.type + (field.isList ? "[]" : field.isRequired ? "" : "?"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.accent)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if field.isId { tag("id", .purple) }
                if field.isUnique { tag("unique", .blue) }
                if field.isRelation { tag("relation", .teal) }
                if !field.isRequired { tag("optional", .secondary) }
                if let dv = field.defaultValue {
                    tag("= \(dv)", .secondary)
                }
            }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }
}

private struct EnumRow: View {
    let modelEnum: SchemaParser.ModelEnum

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text(modelEnum.name)
                    .font(.rowPrimary)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(modelEnum.values.count)")
                    .font(.micro)
                    .tracking(0.3)
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(modelEnum.values, id: \.self) { value in
                        Text(value)
                            .font(.system(size: 10.5, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.accent.opacity(0.10)))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .padding(12)
        .cardStyle()
    }
}
