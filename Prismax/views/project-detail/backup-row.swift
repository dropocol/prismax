import SwiftUI

/// A single row in the Backups tab history list: file name, timestamp, size,
/// and per-backup actions (restore, cross-environment restore, reveal, delete).
struct BackupRow: View {
    let backup: BackupResult
    let onRestore: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let crossDestinations: [EnvProfile]
    let onCrossEnvRestore: (EnvProfile) -> Void

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
            if !crossDestinations.isEmpty {
                Menu {
                    ForEach(crossDestinations) { dest in
                        Button(dest.name) { onCrossEnvRestore(dest) }
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Restore into another environment")
            }
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
