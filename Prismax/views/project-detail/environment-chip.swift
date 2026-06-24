import SwiftUI

/// A compact colored pill showing the active environment.
struct EnvironmentChip: View {
    let environment: EnvProfile

    private var color: Color { Color(hex: environment.colorHex) }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            Text(environment.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(color.opacity(0.10))
        )
        .overlay(
            Capsule().strokeBorder(color.opacity(0.20), lineWidth: 0.5)
        )
    }
}
