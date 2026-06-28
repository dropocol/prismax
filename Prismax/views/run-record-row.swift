import SwiftUI

/// A single history-list row. Shows the run's status, command, the resolved
/// `prisma` invocation, and project / environment / outcome metadata.
/// `highlighted` drives a brief accent flash used when the user jumps to a
/// specific run from the sidebar's Recent Activity section.
struct RunRecordRow: View {
    let record: RunRecord
    var highlighted: Bool = false

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
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(highlighted ? Theme.accent.opacity(0.16) : Color.clear)
        )
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
