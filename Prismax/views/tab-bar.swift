import SwiftUI

/// A Xcode-style underline tab bar: neutral by default, accent + underline
/// when selected. More restrained than a filled-pill control.
struct TabBar: View {
    @Binding var selection: ProjectTab
    /// Tabs to render. Defaults to all cases; callers pass a filtered list for
    /// projects that hide some tabs (e.g. backups-only hides Commands/Schema).
    var tabs: [ProjectTab] = ProjectTab.allCases
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        // Fixed height keeps the bar compact (it otherwise expands to fill any
        // vertical space the parent offers). The bottom hairline runs the full
        // width and the selected tab's underline sits directly on top of it, so
        // the indicator reads as touching the bottom edge with no gap.
        .frame(height: 30)
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
            // label row pinned to the top so the underline stays at the bottom.
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: isSelected ? tab.symbolFilled : tab.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(tab.label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                }
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                .padding(.top, 6)
                Spacer(minLength: 0)
                // Underline indicator. Drawn at 2pt and pulled down 0.5pt so
                // its bottom edge lands flush on the bar's bottom hairline,
                // making the selected tab read as connected to the divider.
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
                .offset(y: 0.5)
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
