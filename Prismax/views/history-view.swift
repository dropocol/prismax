import SwiftUI
import SwiftData

/// Timeline of past command runs. Each row shows what ran, against which
/// environment, and the outcome. The rerun button re-dispatches the command
/// into the project's integrated terminal.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RunService.self) private var runService
    @Query(sort: \RunRecord.startedAt, order: .reverse) private var records: [RunRecord]

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Runs will appear here once you execute a command.")
                )
            } else {
                List {
                    ForEach(records) { record in
                        HStack(spacing: 8) {
                            RunRecordRow(record: record)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                runService.rerun(record, modelContext: modelContext)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Rerun")
                        }
                        .contextMenu {
                            Button("Rerun", systemImage: "arrow.clockwise") {
                                runService.rerun(record, modelContext: modelContext)
                            }
                            Button("Copy Output", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(record.output, forType: .string)
                            }
                            .disabled(record.output.isEmpty)
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                modelContext.delete(record)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct RunRecordRow: View {
    let record: RunRecord

    var body: some View {
        HStack(spacing: 11) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.commandName)
                        .font(.rowPrimary)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Text("prisma " + record.commandArgs)
                    .font(.mono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Image(systemName: "shippingbox").font(.system(size: 8.5))
                    Text(record.projectName).font(.system(size: 10.5))
                    Text("·").foregroundStyle(.tertiary)
                    Text(record.environmentName).font(.system(size: 10.5))
                    Text("·").foregroundStyle(.tertiary)
                    Text(record.status.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(statusColor)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.status {
        case .running:
            Image(systemName: "circle.dotted").foregroundStyle(Theme.running)
        case .dispatched:
            Image(systemName: "arrow.up.forward.app").foregroundStyle(Theme.running)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
        case .canceled:
            Image(systemName: "minus.circle.fill").foregroundStyle(Theme.warning)
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .running, .dispatched: Theme.running
        case .success: Theme.success
        case .failed: Theme.danger
        case .canceled: Theme.warning
        }
    }
}
