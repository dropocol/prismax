import SwiftUI

/// A Xcode-style underline tab bar: neutral by default, accent + underline
/// when selected. More restrained than a filled-pill control.
struct TabBar: View {
    @Binding var selection: ProjectTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ProjectTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
        }
    }

    private func tabButton(_ tab: ProjectTab) -> some View {
        let isSelected = selection == tab
        return Button {
            withAnimation(.snappy(duration: 0.22)) { selection = tab }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: isSelected ? tab.symbolFilled : tab.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(tab.label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                }
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                .padding(.top, 6)
                // Matching underline indicator.
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "tabIndicator", in: ns)
                    } else {
                        Capsule().fill(.clear).frame(height: 2)
                    }
                }
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

extension ProjectTab {
    /// Filled variant of the SF Symbol for the selected state.
    var symbolFilled: String {
        switch self {
        case .commands: "terminal.fill"
        case .environments: "circle.hexagongrid.fill"
        case .backups: "externaldrive.fill"
        case .schema: "doc.text.magnifyingglass"
        }
    }
}
