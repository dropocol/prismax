import SwiftUI

/// An info glyph that, when clicked, shows an instant popover with a longer
/// explanation. This avoids two problems with the native `.help()` tooltip:
///   1. Its ~2s hover delay is too slow for discovery.
///   2. When placed inside a Toggle's label, clicking the glyph toggles the
///      checkbox (the hit goes to the Toggle, not the icon).
/// The glyph consumes its own tap (Button), so it never toggles anything, and
/// the popover appears immediately on click.
struct InfoHint: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            // A fixed width (not maxWidth) forces the text to wrap at 300pt
            // instead of collapsing to one truncated line. The popover then
            // grows vertically to show every line.
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .frame(width: 300, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
    }
}
