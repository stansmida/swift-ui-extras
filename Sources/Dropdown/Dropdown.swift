import SwiftUI

private struct Dropdown<DropdownContent>: ViewModifier where DropdownContent: View {

    init(
        isPresented: Bool,
        offset: CGFloat,
        maxLength: CGFloat,
        cornerRadius: CGFloat,
        @ViewBuilder dropdownContentBuilder: @escaping () -> DropdownContent
    ) {
        self.isPresented = isPresented
        self.offset = offset
        self.maxLength = maxLength
        self.cornerRadius = cornerRadius
        self.dropdownContentBuilder = dropdownContentBuilder
    }

    private let isPresented: Bool
    private let offset: CGFloat
    private let maxLength: CGFloat
    private let cornerRadius: CGFloat
    private let dropdownContentBuilder: () -> DropdownContent

    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .anchorPreference(key: DropdownBaseViewBounds.self, value: .bounds, transform: { $0 })
            .overlayPreferenceValue(DropdownBaseViewBounds.self) { bounds in
                // We condition presence of the dropdown here, with the very same, stable `content` (above),
                // to preserve identity and state of sensitive views in `content`, like for instance text field, that
                // would control presence of this dropdown.
                if isPresented {
                    GeometryReader { geometryProxy in

                        dropdownContentBuilder()

                            // Stretch `dropdownContent` to width od the casting view.
                            .frame(maxWidth: .infinity, alignment: .leading)

                            .background(
                                RoundedRectangle(cornerRadius: cornerRadius)
                                    .stroke(Color(.separator), style: .init(lineWidth: 1 / displayScale))
                                    .background(RoundedRectangle(cornerRadius: cornerRadius).fill(.ultraThinMaterial))
                                    .shadow(color: Color(.separator), radius: offset * 2, x: .zero, y: -offset)
                            )

                            // Set the limit for `dropdownContent` size. This sets the cast frame, casted from the
                            // base frame defined below.
                            .frame(height: maxLength, alignment: .bottom)

                            // The two lines below make the base frame that we cast from.
                            .offset(x: .zero, y: -geometryProxy[bounds!].height - offset)
                            .frame(width: geometryProxy[bounds!].width, height: geometryProxy[bounds!].height, alignment: .bottom)
                    }
                }
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

    /// Casts content in "dropdown" container.
    /// - Note: Currently only casting upwards (from the top edge) is supported.
    /// - Parameters:
    ///   - isPresented: Controls presence of the dropdown.
    ///   - offset: Spacing from the view that casts the dropdown.
    ///   - maxLength: Limit the size of the dropdown, length on axis of the cast direction.
    ///   - cornerRadius: Round corner radius of the dropdown.
    ///   - content: Content in the dropdown.
    @ViewBuilder func dropdown<DropdownContent>(
        isPresented: Bool,
        offset: CGFloat = 4,
        maxLength: CGFloat = 100,
        cornerRadius: CGFloat,
        @ViewBuilder content: @escaping () -> DropdownContent
    ) -> some View where DropdownContent: View {
        modifier(
            Dropdown(
                isPresented: isPresented,
                offset: offset,
                maxLength: maxLength,
                cornerRadius: cornerRadius,
                dropdownContentBuilder: content
            )
        )
    }
}
