import Foundation

public protocol TextToken: Hashable {

    /// Attributes must be from ``UIKitAttributes`` scope since the underlying element that renders
    /// the text is from UIKit.
    /// - Important: Don't use ``backgroundColor`` attribute. For now, this attribute is used to mark current
    /// phrase. Using the attribute for tokens has undefined behavior. Generally, the recommended attribute for
    /// tokens is ``foregroundColor``.
    /// - Todo: Allows clients to use ``backgroundColor``. Consider options like restore original attributes
    /// when demarking, reset tokens runs on selection (phase) change, or mark without using attributes.
    static var attributes: AttributeContainer { get }

    var text: String { get }
}

// MARK: - TextTokenAttributes

extension AttributeScopes {

    var textTokenAttributes: TextTokenAttributes.Type { TextTokenAttributes.self }

    struct TextTokenAttributes: AttributeScope {

        enum TextToken: AttributedStringKey {

            typealias Value = AnyTextToken

            static let inheritedByAddedText = false
            static let name = "swift-ui-extras.TextToken"
        }

        let textToken: TextToken

        /// When converting `AttributedString` (which this library uses as base type to work with string attribution)
        /// from/to `String` or `NSAttributedString`, we use API to include an attribute scope. We need to preserve
        /// attributes from more scopes though. In addition to ``TextTokenAttributes`` (to store info about tokens),
        /// we need to preserve visual attributes that are compatible with underlying text field (currently
        /// `UIKitAttributes` for `UITextView` text field). We do this by nesting the scopes like this.
        /// See more in [AttributedString.init(_:including:)](https://developer.apple.com/documentation/foundation/attributedstring/3787693-init).
        let uiKitAttributes: UIKitAttributes
    }
}

extension AttributeDynamicLookup {

    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.TextTokenAttributes, T>) -> T {
        get { self[T.self] }
    }
}

// MARK: - AnyTextToken

struct AnyTextToken: Hashable {

    let base: any TextToken

    static func == (lhs: AnyTextToken, rhs: AnyTextToken) -> Bool {
        lhs.base.isEqual(to: rhs.base)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(base)
    }
}

private extension TextToken {

    func isEqual(to textToken: some TextToken) -> Bool {
        if let selfTypeInstance = textToken as? Self {
            return self == selfTypeInstance
        } else {
            return false
        }
    }
}
