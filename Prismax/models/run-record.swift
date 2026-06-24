import Foundation
import SwiftData

/// A persisted record of a command execution.
@Model
final class RunRecord {
    @Attribute(.unique) var id: UUID

    var projectId: UUID
    var projectName: String

    var commandId: UUID?
    var commandName: String
    var commandArgs: String

    var environmentId: UUID?
    var environmentName: String

    var output: String
    var exitCode: Int?
    var statusRaw: String
    var startedAt: Date
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        projectId: UUID,
        projectName: String,
        commandId: UUID? = nil,
        commandName: String,
        commandArgs: String,
        environmentId: UUID? = nil,
        environmentName: String,
        output: String = "",
        exitCode: Int? = nil,
        status: RunStatus = .running,
        startedAt: Date = .now,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.commandId = commandId
        self.commandName = commandName
        self.commandArgs = commandArgs
        self.environmentId = environmentId
        self.environmentName = environmentName
        self.output = output
        self.exitCode = exitCode
        self.statusRaw = status.rawValue
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    var status: RunStatus {
        get { RunStatus(rawValue: statusRaw) ?? .running }
        set { statusRaw = newValue.rawValue }
    }
}

enum RunStatus: String, Codable {
    /// Dispatched into the integrated terminal and still running there.
    case running
    /// Launched but exited the foreground quickly (e.g. `studio` opens a server,
    /// `format` writes a file) — we don't wait for an exit code.
    case dispatched
    case success, failed, canceled

    var label: String {
        switch self {
        case .running: "Running"
        case .dispatched: "Dispatched"
        case .success: "Success"
        case .failed: "Failed"
        case .canceled: "Canceled"
        }
    }
}
