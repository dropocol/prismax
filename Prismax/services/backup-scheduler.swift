import Foundation
import SwiftUI

/// How often an automatic backup should run (while the app is open).
enum BackupFrequency: String, CaseIterable, Identifiable {
    case hourly, daily, weekly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .hourly: 3600
        case .daily: 86_400
        case .weekly: 604_800
        }
    }
}

/// Schedules recurring backups per (project, environment) using `Timer`.
/// Backups run only while Prismax is open; a background LaunchAgent is planned.
@MainActor
final class BackupScheduler {
    static let shared = BackupScheduler()

    private struct Key: Hashable {
        let projectID: UUID
        let envID: UUID
    }

    private var timers: [Key: Timer] = [:]

    func schedule(project: Project, environment: EnvProfile, frequency: BackupFrequency) {
        let key = Key(projectID: project.id, envID: environment.id)
        cancel(project: project, environment: environment)

        let timer = Timer.scheduledTimer(withTimeInterval: frequency.interval, repeats: true) { _ in
            Task { @MainActor in
                self.runBackup(project: project, environment: environment)
            }
        }
        timers[key] = timer
    }

    func cancel(project: Project, environment: EnvProfile) {
        let key = Key(projectID: project.id, envID: environment.id)
        timers[key]?.invalidate()
        timers.removeValue(forKey: key)
    }

    func cancelAll() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
    }

    private func runBackup(project: Project, environment: EnvProfile) {
        guard let url = environment.variables
            .first(where: { $0.key.uppercased() == "DATABASE_URL" })
            .flatMap({ try? KeychainService.get(account: $0.keychainAccount) }) else {
            return
        }
        Task {
            _ = try? await BackupService.backup(
                databaseURL: url,
                project: project.id,
                environment: environment.id,
                environmentName: environment.name
            )
        }
    }
}
