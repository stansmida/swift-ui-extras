import SwiftUI

/**
 - Note: Currently only top edge is supported.
 */
private struct Dropdown<DropdownContent>: ViewModifier where DropdownContent: View {

    init(
        offset: CGFloat,
        cornerRadius: CGFloat,
        @ViewBuilder dropdownContentBuilder: @escaping () -> DropdownContent
    ) {
        self.offset = offset
        self.cornerRadius = cornerRadius
        self.dropdownContentBuilder = dropdownContentBuilder
    }

    private let offset: CGFloat
    private let cornerRadius: CGFloat
    private let dropdownContentBuilder: () -> DropdownContent

    #warning("adjust, test...")
    /// This serves as kind of "max height". It offers 300 px height in opposite to `content` height.
    /// Typically the `content` is text field so height is rather small. This results in number of full text lines being truncated
    /// for small height. On the other side, if that text wrapper is `fixedSize()` the number of lines could outsize the 300px.
    /// So ideal solution is to let text wrapper trucate to fit but offer max height.
    private let idealMaxHeight = CGFloat(100)

    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        if case let dropdownContent = dropdownContentBuilder(), !(dropdownContent is EmptyView) {
            content
                .anchorPreference(key: DropdownBaseViewBounds.self, value: .bounds, transform: { $0 })
                .overlayPreferenceValue(DropdownBaseViewBounds.self) { bounds in
                    GeometryReader { geometryProxy in
                        dropdownContent
//                          .frame(width: geometryProxy[bounds!].width, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: cornerRadius)
                                    .stroke(Color(.separator), style: .init(lineWidth: 1 / displayScale))
                                    .background(RoundedRectangle(cornerRadius: cornerRadius).fill(.ultraThinMaterial))
                                    .shadow(color: Color(.separator), radius: offset * 2, x: .zero, y: -offset)
                            )

                        // Offer dropdownContent ideal max height so views with dynamic sizing like text wrappers can
                        // take the most of the space without need to fix size.
                            .frame(height: idealMaxHeight, alignment: .bottom)

                        // Take what is proposed, align by bottom so offset can be the height.
                            .offset(x: .zero, y: -geometryProxy[bounds!].height - offset)
                            .frame(width: geometryProxy[bounds!].width, height: geometryProxy[bounds!].height, alignment: .bottom)
                    }
                }
        } else {
            content
        }
    }
}

private enum DropdownBaseViewBounds: PreferenceKey {

    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

public extension View {

    func dropdown<DropdownContent>(
        offset: CGFloat = 4,
        cornerRadius: CGFloat,
        @ViewBuilder content: @escaping () -> DropdownContent
    ) -> some View where DropdownContent: View {
        modifier(
            Dropdown(
                offset: offset,
                cornerRadius: cornerRadius,
                dropdownContentBuilder: content
            )
        )
    }
}
