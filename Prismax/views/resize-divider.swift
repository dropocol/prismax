import SwiftUI

/// A draggable divider for resizing an adjacent panel.
/// - `.horizontal`: a thin horizontal bar; dragging up/down changes the
///   terminal height below it.
/// - `.vertical`: a thin vertical bar; dragging left/right changes the
///   terminal width to its left (i.e. the right-side panel grows leftward).
struct ResizeDivider: View {
    enum Orientation { case horizontal, vertical }
    let orientation: Orientation
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var dragStartValue: CGFloat = 0

    var body: some View {
        Group {
            if orientation == .horizontal {
                Capsule()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 5)
                    .frame(maxHeight: 11)
                    .background(Color.clear.contentShape(Rectangle()))
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
            } else {
                Capsule()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: 11)
                    .background(Color.clear.contentShape(Rectangle()))
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { event in
                    if event.translation == .zero {
                        dragStartValue = value
                    }
                    let delta: CGFloat
                    switch orientation {
                    case .horizontal: delta = -event.translation.height
                    case .vertical:   delta = -event.translation.width
                    }
                    let proposed = dragStartValue + delta
                    value = min(max(proposed, range.lowerBound), range.upperBound)
                }
        )
    }
}
