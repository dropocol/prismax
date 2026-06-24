import SwiftUI
import SwiftData

struct BackupsTab: View {
    let project: Project
    let environment: EnvProfile

    @Environment(\.modelContext) private var modelContext
    @State private var backups: [BackupResult] = []
    @State private var isBackingUp = false
    @State private var isRestoring = false
    @State private var statusMessage: String?
    @State private var statusError = false
    @State private var restoreTarget: BackupResult?
    @State private var scheduleEnabled = false
    @State private var scheduleFrequency: BackupFrequency = .daily

    private var databaseURL: String? {
        environment.variables
            .first(where: { $0.key.uppercased() == "DATABASE_URL" })
            .flatMap { try? KeychainService.get(account: $0.keychainAccount) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                actionsSection
                schedulingSection
                Divider()
                listSection
            }
            .padding(16)
        }
        .onAppear { refresh() }
        .alert("Restore Backup?", isPresented: Binding(
            get: { restoreTarget != nil },
            set: { if !$0 { restoreTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { restoreTarget = nil }
            Button("Restore", role: .destructive) {
                if let target = restoreTarget { performRestore(target) }
                restoreTarget = nil
            }
        } message: {
            if let target = restoreTarget {
                Text("Restoring \(target.fileURL.lastPathComponent) will overwrite the current **\(environment.name)** database. This cannot be undone.")
            }
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 11, weight: .semibold))
                Text("BACKUP")
                    .font(.micro)
                    .tracking(0.5)
            }
            .foregroundStyle(.tertiary)

            if let url = databaseURL {
                HStack(spacing: 5) {
                    Image(systemName: "cylinder")
                        .font(.system(size: 10))
                    Text(providerLabel(for: url))
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(.secondary)

                Button {
                    performBackup()
                } label: {
                    HStack(spacing: 6) {
                        if isBackingUp {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(isBackingUp ? "Backing up…" : "Back up now")
                            .font(.rowPrimary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBackingUp)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No DATABASE_URL", systemImage: "exclamationmark.triangle")
                        .font(.rowPrimary)
                        .foregroundStyle(Theme.warning)
                    Text("Add a `DATABASE_URL` variable to **\(environment.name)** in the Environments tab.")
                        .font(.rowSecondary)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            }

            if let statusMessage {
                HStack(spacing: 5) {
                    Image(systemName: statusError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    Text(statusMessage)
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(statusError ? Theme.danger : Theme.success)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill((statusError ? Theme.danger : Theme.success).opacity(0.10))
                )
            }
        }
    }

    // MARK: Scheduling

    private var schedulingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $scheduleEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Schedule while app is open")
                        .font(.rowPrimary)
                }
            }
            .onChange(of: scheduleEnabled) { _, on in
                if on { BackupScheduler.shared.schedule(project: project, environment: environment, frequency: scheduleFrequency) }
                else { BackupScheduler.shared.cancel(project: project, environment: environment) }
            }

            if scheduleEnabled {
                Picker("Frequency", selection: $scheduleFrequency) {
                    ForEach(BackupFrequency.allCases) { freq in
                        Text(freq.label).tag(freq)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: scheduleFrequency) { _, freq in
                    BackupScheduler.shared.schedule(project: project, environment: environment, frequency: freq)
                }
                Text("Backups run automatically while Prismax is open. A background LaunchAgent is planned for a future update.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: List

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("HISTORY")
                    .font(.micro)
                    .tracking(0.5)
                Spacer()
                Text("\(backups.count) backups")
                    .font(.micro)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.tertiary)

            if backups.isEmpty {
                Text("No backups yet.")
                    .font(.rowPrimary)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
            } else {
                VStack(spacing: 6) {
                    ForEach(backups) { backup in
                        BackupRow(backup: backup,
                                  onRestore: { restoreTarget = backup },
                                  onReveal: { BackupService.reveal(fileURL: backup.fileURL) },
                                  onDelete: { delete(backup) })
                    }
                }
            }
        }
    }

    // MARK: Logic

    private func refresh() {
        backups = BackupService.backups(projectID: project.id, envID: environment.id)
    }

    private func providerLabel(for url: String) -> String {
        guard let parsed = URL(string: url), let scheme = parsed.scheme,
              let provider = BackupService.Provider(urlScheme: scheme) else {
            return "Unknown provider"
        }
        return "\(provider.label) detected"
    }

    private func performBackup() {
        guard let url = databaseURL else { return }
        isBackingUp = true
        statusMessage = nil
        Task {
            do {
                _ = try await BackupService.backup(
                    databaseURL: url,
                    project: project.id,
                    environment: environment.id,
                    environmentName: environment.name
                )
                await MainActor.run {
                    isBackingUp = false
                    statusMessage = "Backup complete."
                    statusError = false
                    refresh()
                }
            } catch {
                await MainActor.run {
                    isBackingUp = false
                    statusMessage = error.localizedDescription
                    statusError = true
                }
            }
        }
    }

    private func performRestore(_ backup: BackupResult) {
        guard let url = databaseURL else { return }
        isRestoring = true
        statusMessage = nil
        Task {
            do {
                _ = try await BackupService.restore(databaseURL: url, from: backup.fileURL)
                await MainActor.run {
                    isRestoring = false
                    statusMessage = "Restore complete."
                    statusError = false
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    statusMessage = error.localizedDescription
                    statusError = true
                }
            }
        }
    }

    private func delete(_ backup: BackupResult) {
        try? BackupService.delete(fileURL: backup.fileURL)
        refresh()
    }
}

private struct BackupRow: View {
    let backup: BackupResult
    let onRestore: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accent.opacity(0.08))
                    .frame(width: 28, height: 28)
                Image(systemName: "doc.zipper")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.fileURL.lastPathComponent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(backup.createdAt, format: .dateTime.month().day().hour().minute())
                    Text("·").foregroundStyle(.tertiary)
                    Text(backup.sizeBytes.formattedBytes)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore", systemImage: "arrow.uturn.backward", action: onRestore)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(action: onReveal) {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .cardStyle(cornerRadius: 8)
    }
}
