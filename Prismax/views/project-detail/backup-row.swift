import SwiftUI

/// A single row in the Backups tab history list: file name, timestamp, size,
/// and per-backup actions. Restore is a single unified menu whose first item is
/// the current environment and whose submenu lists other environments, so users
/// always pick a destination explicitly.
struct BackupRow: View {
    let backup: BackupResult
    /// Name of the environment this row belongs to (the "this environment"
    /// restore target).
    let currentEnvironmentName: String
    let onRestore: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let crossDestinations: [EnvProfile]
    let onCrossEnvRestore: (EnvProfile) -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
            metadata
            Spacer()
            restoreMenu
            Button(action: onReveal) {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Delete backup")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .cardStyle(cornerRadius: 8)
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.accent.opacity(0.08))
                .frame(width: 28, height: 28)
            Image(systemName: "doc.zipper")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
    }

    private var metadata: some View {
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
    }

    /// One "Restore…" button that opens a menu: the current environment is the
    /// prominent first item, then (if any) a section of other environments.
    /// This makes "restore here" vs "restore elsewhere" two clear choices of a
    /// single action rather than two separate, easily-confused buttons.
    private var restoreMenu: some View {
        Menu {
            Button {
                onRestore()
            } label: {
                Label("Restore to \(currentEnvironmentName)", systemImage: "arrow.uturn.backward")
            }

            if !crossDestinations.isEmpty {
                Divider()
                ForEach(crossDestinations) { dest in
                    Button {
                        onCrossEnvRestore(dest)
                    } label: {
                        Label("Restore to \(dest.name)", systemImage: "arrow.left.arrow.right")
                    }
                }
            }
        } label: {
            Label("Restore", systemImage: "arrow.uturn.backward.circle")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Restore this backup into an environment")
    }
}
