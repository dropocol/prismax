import SwiftUI

/// Confirmation sheet shown before any restore. Lets the user pick the
/// destination (shown read-only), choose how the target is prepared
/// (`RestoreMode`), toggle parallel jobs, and read about the DB privileges
/// each mode needs — so restore isn't a blind, slow default. Defaults come
/// from Settings but can be overridden per-restore here.
struct RestoreConfirmationSheet: View {
    /// What's being restored.
    let backupFileName: String
    /// Where it's going (env name + whether it's the current env or another).
    let destinationName: String
    let isCrossEnvironment: Bool

    /// Pre-filled from Settings; the user can change them for this run only.
    @State var mode: RestoreMode
    @State var parallel: Bool

    var onConfirm: (RestoreMode, Bool) -> Void
    var onCancel: () -> Void

    @State private var showingPrivilegesHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            destinationCard

            modeSection

            parallelToggle

            Divider()

            // Privileges + troubleshooting help — collapsed by default so it
            // doesn't crowd the confirm flow, but one click away for anyone
            // whose restore is slow or failing on permissions.
            DisclosureGroup("DB privileges & slow restores", isExpanded: $showingPrivilegesHelp) {
                privilegesHelp
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Restore", role: .destructive) { onConfirm(mode, parallel) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.warning.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.warning)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore Backup")
                    .font(.appTitle)
                    .foregroundStyle(.primary)
                Text(backupFileName)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var destinationCard: some View {
        HStack(spacing: 8) {
            Image(systemName: isCrossEnvironment ? "arrow.left.arrow.right" : "arrow.uturn.backward")
                .foregroundStyle(.secondary)
            Text("Into")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("**\(destinationName)**")
                .font(.system(size: 12))
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03))
        )
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RESTORE MODE")
                .font(.micro)
                .tracking(0.4)
                .foregroundStyle(.tertiary)
            Picker("", selection: $mode) {
                ForEach(RestoreMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(mode.help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var parallelToggle: some View {
        Toggle("Parallel jobs", isOn: $parallel)
            .help("Restore compressed (.dump) backups using multiple parallel connections — 2–4x faster. Postgres .dump only.")
    }

    /// Plain-text help covering (a) what privileges each mode needs and (b)
    /// the most common cause of unexpectedly slow restores (high per-statement
    /// round-trip time to a remote DB), so users can self-diagnose.
    private var privilegesHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                Text("Required DB privileges:")
                    .font(.system(size: 11, weight: .semibold))
                Text("• Ownership recreation (ALTER … OWNER TO / SET ROLE) is skipped automatically — restores work even when the target user isn't the table owner or a superuser.")
                Text("• Drop & recreate: needs CREATE/DROP on the target schema.")
                Text("• Truncate: needs TRUNCATE on the tables; --disable-triggers needs superuser on the target.")
                Text("• Append: needs INSERT + CREATE on the target.")
                Text("• Parallel jobs: the DB must allow multiple concurrent connections (check max_connections).")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            Group {
                Text("Slow restore?")
                    .font(.system(size: 11, weight: .semibold))
                Text("A small database taking minutes usually means high latency to a remote DB (each statement is a network round-trip) — not the mode. Try Truncate or Append for fewer statements, and keep Parallel on. If your DB is local and it's still slow, check the live log in the restore panel for where it's stuck.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}
