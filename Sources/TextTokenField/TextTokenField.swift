import Combine
import Foundation
import SwiftUI
import UIKit

public struct TextTokenField: UIViewRepresentable {

    public init(manager: TextTokenFieldManager) {
        self.manager = manager
    }

    let manager: TextTokenFieldManager

    public func updateUIView(_ uiView: UITextView, context: UIViewRepresentableContext<Self>) {
        // The manager owns (and updates) the view by itself.
    }

    public func makeUIView(context: UIViewRepresentableContext<Self>) -> UITextView {
        manager.uiView.removeFromSuperview()
        return manager.uiView
    }
}

/// - Note: In this type, the documentation is using "TTI" acronym for "Text Token Input". Active TTI means
/// a mode when the component accepts `TextToken`s and is providing a character that triggered the active mode and
/// a phrase that was input during the active mode.
@MainActor
public final class TextTokenFieldManager: ObservableObject {

    private enum TriggerCancellationStrategy {
        case deleteTrigger
        case deleteTriggerAndPhrase
    }

    private enum TTIChange {
        case before(newValue: (trigger: AttributedString.Index, isExplicit: Bool)?)
        case after
    }

    deinit {
        contentSizeObservation.invalidate()
        contentSizeObservation = nil
    }

    public init(
        text: AttributedString = AttributedString(),
        triggers: Character...,
        triggerCancellers: CharacterSet = .newlines,
        defaultTypingAttributes: AttributeContainer? = nil,
        phraseMarkingColor: UIColor = .placeholderText,
        keyboardType: UIKeyboardType = .default
    ) {
        uiView = UITextView()
        uiView.attributedText = try? NSAttributedString(text, including: \.textTokenAttributes)
        uiView.keyboardType = keyboardType
        self.triggers = Set(triggers)
        self.triggerCancellers = triggerCancellers
        self.defaultTypingAttributes = defaultTypingAttributes ?? .init(uiView.typingAttributes)
        self.phraseMarkingColor = phraseMarkingColor
        uiViewDelegate = TextViewDelegate(manager: self)
        contentSizeObservation = uiView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
            if change.newValue != change.oldValue {
                Task { @MainActor [weak self] in
                    withAnimation {
                        self?.objectWillChange.send()
                    }
                }
            }
        }
    }

    // MARK: - Private properties

    fileprivate let uiView: UITextView
    private var uiViewDelegate: TextViewDelegate!
    private var contentSizeObservation: NSKeyValueObservation!

    /// The source of truth whether TTI is active or inactive. Apparently, `nil` value means inactive mode.
    /// `isExplicit` is a flag that controls active TTI cancellation behavior. Explicitly activated TTI means
    /// that it was activated "intentioanlly" (via (a control bound to the) `trigger(with:)`) and cancellation
    /// is more aggressive - deletes both the triggering character and the phrase. `false` value is set if
    /// a triggering character comes from the default input (i.e. a keyboard). In this case the cancellation
    /// is graceful and preserves both the triggering character and the phrase to allows users type arbitrary text.
    /// This property is private, clients shall access public (read-only) information from `isTextTokenInputActive`.
    @Published private var tti: (trigger: AttributedString.Index, isExplicit: Bool)? {
        willSet {
            setKeyboardBehavior(ttiChange: .before(newValue: newValue))
        }
        didSet {
            // When selection remains the same but triggering is cancelled - we want to clear
            // the phrase marking.
            updatePhraseMarking()
            setKeyboardBehavior(ttiChange: .after)
        }
    }

    // MARK: Transient flags

    private var isInputTriggerExplicit = false
    private var isPhraseMarkingUpdating = false

    // MARK: - Public API

    // MARK: Accessing properties

    public let triggers: Set<Character>
    public let triggerCancellers: CharacterSet
    public let defaultTypingAttributes: AttributeContainer
    public let phraseMarkingColor: UIColor

    // There are intermittent inconsistencies between `text` and `attributedText` in `UITextView`
    // (assuming mostly within a cycle when on of them gets updated). We rely on these to be same string
    // at any time - see unsafe operations below. Thus `attributedText` is chosen as the single source of
    // truth (obviously as we can go only from attributed string to string but no vice versa). Do not use
    // ``uiView.text``, but use this anytime you need to access string value.
    public var text: String {
        get { String(attributedText(withTextTokens: false).characters) }
    }

    /// `TextToken`s in `text`.
    public var tokens: [(any TextToken, Range<String.Index>)] {
        attributedText(withTextTokens: true)
            .runs
            .compactMap { run in
                if let textToken = run.textToken?.base {
                    return (textToken, range(for: run.range, in: text))
                } else {
                    return nil
                }
            }
    }

    public var isTextTokenInputActive: (trigger: Character, phrase: String)? {
        guard
            let triggeringIndex = tti?.trigger,
            case let text = attributedText(withTextTokens: false),
            isCharacterAtIndexTriggering(triggeringIndex, in: text)
        else {
            return nil
        }
        let trigger = text.characters[triggeringIndex]
        let caretEnd = selection(in: text).upperBound
        // TODO: Consider the more performant string reading. https://forums.swift.org/t/attributedstring-to-string/61667
        let phrase = String(text[text.index(afterCharacter: triggeringIndex)..<caretEnd].characters)
        return (trigger, phrase)
    }

    /// Estimation based on `defaultTypingAttributes` font.
    public func estimatedHeight(forNumberOfLines lines: Int) -> CGFloat {
        defaultTypingAttributes.uiKit.font!.lineHeight * CGFloat(lines)
        + uiView.textContainerInset.top
        + uiView.textContainerInset.bottom
    }

    public var contentSize: CGSize { uiView.contentSize }

    // MARK: Manipulation

    /// A method to preset a text with tokens.
    public func setText(_ text: String, with tokens: [(any TextToken, Range<String.Index>)] = []) {
        tti = nil
        var attributedString = AttributedString(text, attributes: defaultTypingAttributes)
        for t in tokens {
            guard
                let lowerBound = AttributedString.Index(t.1.lowerBound, within: attributedString),
                let upperBound = AttributedString.Index(t.1.upperBound, within: attributedString)
            else {
                continue
            }
            attributedString[lowerBound ..< upperBound].textToken = AnyTextToken(base: t.0)
            attributedString[lowerBound ..< upperBound].mergeAttributes(t.0.attributes)
        }
        uiView.attributedText = try! NSAttributedString(attributedString, including: \.textTokenAttributes)
        // If the text (selection) unintentionally triggered active TTI, we just deactivate it.
        tti = nil
    }

    /// Ignored if not in active TTI.
    public func insertToken(
        _ token: some TextToken,
        representedBy tokenText: String,
        appendCharacter: Character? = " ",
        continueTextTokenInput: Bool = false
    ) {
        let text = attributedText(withTextTokens: true)
        guard
            let tti = tti,
            case let triggeringIndex = tti.0,
            isCharacterAtIndexTriggering(triggeringIndex, in: text)
        else {
            // TTI is inactive, ignore the caller.
            return
        }
        self.tti = nil
        let triggeringCharacter = text.characters[triggeringIndex]
        let selection = selection(in: text)
        let insertionRange = triggeringIndex ..< max(triggeringIndex, selection.upperBound)
        var insertion = AttributedString(tokenText, attributes: defaultTypingAttributes.merging(token.attributes))
        if let appendCharacter {
            insertion += AttributedString(String(appendCharacter))
        }
        replaceSubrange(insertionRange, with: insertion, in: text)
        if continueTextTokenInput {
            // Once the user inserted a token, we take it as they are aware of the mode.
            trigger(with: triggeringCharacter, explicitly: true)
        }
    }

    /// Ignored if `character` isn't one of the initially configured triggers.
    public func trigger(with character: Character) {
        trigger(with: character, explicitly: true)
    }

    public func cancelTriggering() {
        guard let tti else {
            return
        }
        cancelTriggering(strategy: tti.isExplicit ? .deleteTriggerAndPhrase : nil)
    }

    // MARK: - Private API

    private func trigger(with character: Character, explicitly isExplicit: Bool) {
        guard triggers.contains(character) else {
            return
        }
        cancelTriggering()
        if case let text = attributedText(withTextTokens: false),
           case let selection = selection(in: text),
           selection.lowerBound > text.startIndex,
           case let indexBeforeCaret = text.index(beforeCharacter: selection.lowerBound),
           character == text.characters[indexBeforeCaret] {
            // We are at a position of an existing trigger, so we don't insert a new one but activate the existing.
            tti = (indexBeforeCaret, isExplicit)
        } else {
            // This is `UITextInput` interface, which means the same behavior as if it was input via a keyboard,
            // so we can run the same (reuse) behavior. Just scope it as explicit trigger.
            isInputTriggerExplicit = isExplicit
            uiView.insertText(String(character))
            // At this moment, the delegate (that reads the flag) already exited since it runs on the stack of
            // the method above, thus we reset the flag.
            isInputTriggerExplicit = false
        }
    }

    // MARK: - Conveniences & Utils

    /// This method turns off autocorrect for active TTI. Besides it is better UX, it also prevents code
    /// from crash. The problem is that exchanging a text token for a phrase while there is autocorrect suggestion
    /// for the phrase causes mismatch between current text and current selection. See "Potentionally unsafe
    /// conveniences" section where we do the "unsafe arithmetics" that can cause a crash.
    private func setKeyboardBehavior(ttiChange: TTIChange) {
        switch ttiChange {
            case .before(let newValue):
                if newValue != nil {
                    uiView.autocorrectionType = .no
                    uiView.reloadInputViews()
                }
            case .after:
                if tti == nil {
                    // After TTI is deactivated, we do the token insertion in the same cycle,
                    // and at that moment we still need the autocorrection to be off. Thus we reset
                    // it to default in next cycle.
                    Task {
                        if tti == nil { // If still is nil...
                            uiView.autocorrectionType = .default
                            uiView.reloadInputViews()
                        }
                    }
                }
        }
    }

    /// - Parameter strategy: `nil` to preserve triggering character and (if exists) text between the triggering
    /// character and the caret. You typically want to preserve the text if it is ambiguous whether TTI was
    /// activated intentionally or not. This decision is supposed to be made based on `tti.isExplicit`.
    /// This method allows for arbitrary argument though.
    private func cancelTriggering(strategy: TriggerCancellationStrategy?) {
        guard let tti else {
            return
        }
        self.tti = nil
        guard let strategy else {
            return
        }
        let triggeringIndex = tti.trigger
        let text = attributedText(withTextTokens: false)
        guard isCharacterAtIndexTriggering(triggeringIndex, in: text) else {
            return
        }
        let deleteRange: Range<AttributedString.Index>
        switch strategy {
            case .deleteTrigger:
                deleteRange = triggeringIndex ..< text.index(afterCharacter: triggeringIndex)
            case .deleteTriggerAndPhrase:
                deleteRange = triggeringIndex ..< max(text.index(afterCharacter: triggeringIndex), selection(in: text).upperBound)
        }
        replaceSubrange(deleteRange, with: AttributedString(), in: text)
    }

    /// Used primarily when the selection is changed. It preserves the ipnut text from inheriting attributes
    /// (e.g. text token colors, ...) from the text preceding the caret.
    private func resetTypingAttributes() { uiView.typingAttributes = .init(defaultTypingAttributes) }

    private func updatePhraseMarking() {
        var text = attributedText(withTextTokens: true)
        let markedRuns = rangeOfRuns(text.runs.filter { $0.backgroundColor == phraseMarkingColor })
        let phraseRange: Range<AttributedString.Index>?
        if let triggeringIndex = tti?.trigger,
           isCharacterAtIndexTriggering(triggeringIndex, in: text),
           case let selection = selection(in: text),
           case let phraseStartIndex = text.characters.index(after: triggeringIndex),
           selection.upperBound > phraseStartIndex {
            phraseRange = phraseStartIndex ..< selection.upperBound
        } else {
            phraseRange = nil
        }
        if markedRuns != phraseRange {
            if let markedRuns {
                text[markedRuns].uiKit.backgroundColor = nil
            }
            if let phraseRange {
                text[phraseRange].uiKit.backgroundColor = phraseMarkingColor
            }
            let currentSelection = uiView.selectedRange
            isPhraseMarkingUpdating = true
            uiView.attributedText = try! NSAttributedString(text, including: \.textTokenAttributes)
            uiView.selectedRange = currentSelection
            isPhraseMarkingUpdating = false
        }
    }

    /// `true` if `index` is a valid position of a triggering character.
    private func isCharacterAtIndexTriggering(
        _ index: AttributedString.Index,
        in text: AttributedString
    ) -> Bool {
        guard index >= text.startIndex, index < text.endIndex else {
            return false
        }
        return triggers.contains(text.characters[index])
    }

    private func textTokenRuns(
        at range: Range<AttributedString.Index>,
        in text: AttributedString
    ) -> [AttributedString.Runs.Element] {
        text.runs.filter { run in
            // Run is a token.
            run.textToken != nil
            // And the selection bounds intersects with the run bounds.
            && (
                // By either an overlap.
                run.range.overlaps(range)
                // Or zero length position is within the run bounds.
                || (
                    run.range.contains(range.lowerBound)
                    && run.range.lowerBound != range.lowerBound
                )
            )
        }
    }

    /// - Returns: Adjusted range for `selection` if it intersects tokens. `nil` if it doesn't intersect any text token.
    private func wholeTokensSelection(
        for selection: Range<AttributedString.Index>,
        in text: AttributedString
    ) -> Range<AttributedString.Index>? {
        let selectedTextTokenRuns = textTokenRuns(at: selection, in: text)
        guard let selectedTextTokenRunsRange = rangeOfRuns(selectedTextTokenRuns) else {
            // No portions of runs are selected, nothing to adjust.
            return nil
        }
        // The tokens may be inside the selection (strict subset) so we need to union it with
        // the selection to tell if it is different.
        let wholeTokensRange = unionRanges(selectedTextTokenRunsRange, selection)
        return wholeTokensRange != selection ? wholeTokensRange : nil
    }

    private func rangeOfRuns(
        _ runs: [AttributedString.Runs.Element],
        and range: Range<AttributedString.Index>
    ) -> Range<AttributedString.Index> {
        if let runsRange = rangeOfRuns(runs) {
            return unionRanges(runsRange, range)
        } else {
            return range
        }
    }

    private func containsTriggerCanceller(_ text: some AttributedStringProtocol) -> Bool {
        text.unicodeScalars.contains(where: { triggerCancellers.contains($0) })
    }

    private func containsTriggerCanceller(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: { triggerCancellers.contains($0) })
    }

    private func rangeOfRuns(_ runs: [AttributedString.Runs.Element]) -> Range<AttributedString.Index>? {
        runs.reduce(Range<AttributedString.Index>?.none) { partialResult, run in
            if let partialResult {
                return unionRanges(partialResult, run.range)
            } else {
                return run.range
            }
        }
    }

    private func unionRanges(
        _ lhs: Range<AttributedString.Index>,
        _ rhs: Range<AttributedString.Index>
    ) -> Range<AttributedString.Index> {
        min(lhs.lowerBound, rhs.lowerBound) ..< max(lhs.upperBound, rhs.upperBound)
    }

    // MARK: Potentionally unsafe conveniences
    // The methods below do force unwrapping and force try on standard library APIs, which are not documented
    // why they fail (to init or return without a throw). After quite testing, we suppose they don't fail in
    // static, coherent environment where attributed scope is known, and ranges exist in texts. We decided to
    // aggressively expect consistent results over trying to figure out handling arbitrary errors.
    // For this reason clients should monitor for crashes within this module as they might happen.
    // UPDATE: We discovered that the force unwprap can crash due to text and range mismatch when exchanging
    // a phrase for a text token while there is an active autocorrect suggestion for the phrase. For now we
    // are turning off the autocorrection during active TTI to avoid this source of crashing but we should perhaps
    // consider avoid force unwrapping completely and provide a gracefull solution insted.
    // TODO: Write a basic set of tests to perhaps discover crashes on different versions / systems.

    private func attributedText(withTextTokens: Bool) -> AttributedString {
        if withTextTokens {
            return try! AttributedString(uiView.attributedText, including: \.textTokenAttributes)
        } else {
            return AttributedString(uiView.attributedText)
        }
    }

    /// - Important: `text` must be the current `uiView`'s text.
    private func selection(in text: AttributedString) -> Range<AttributedString.Index> {
        // Calls the force unwrapping method below.
        range(for: uiView.selectedRange, in: text)
    }

    /// - Important: `nsRange` must be an actual range in the `text`.
    private func range(for nsRange: NSRange, in text: AttributedString) -> Range<AttributedString.Index> {
        Range(nsRange, in: text)!
    }

    /// - Important: `range` must be an actual range in the `text`.
    private func range(for range: Range<AttributedString.Index>, in text: String) -> Range<String.Index> {
        Range(range, in: text)!
    }

    private func replaceSubrange(
        _ inputRange: Range<AttributedString.Index>,
        with replacement: AttributedString,
        in text: AttributedString
    ) {
        try! uiView.replaceSubrange(inputRange, with: replacement, in: text, including: \.textTokenAttributes)
    }

    // MARK: - UITextView delegation handlers

    /// In this method, we are looking for these events to uptate the state:
    /// + Check if input range doesn't intersect any text token. If yes, we adjust selection to include
    /// whole tokens and do replacement manually.
    /// + Check for backward deletion of the triggering character. We decide whether it should be deleted
    /// based on if it was input explicitly.
    /// + Chcek for inputting a character that is the active text token input canceller and on such event
    /// cancel the active text token input.
    fileprivate func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {

        resetTypingAttributes()

        let insertion = text
        let text = attributedText(withTextTokens: true)
        let inputRange = self.range(for: range, in: text)

        if let wholeTokensRange = wholeTokensSelection(for: inputRange, in: text) {
            // The offered input range disruptes text tokens integrity as it intersecting some. We must
            // preserve the integrity, take tokens as whole, thus make manual edit instead of continue.
            let insertion = AttributedString(NSAttributedString(string: insertion, attributes: .init(defaultTypingAttributes)))
            replaceSubrange(wholeTokensRange, with: insertion, in: text)
            return false
        } else if let tti, !tti.isExplicit, insertion.isEmpty, range.length == 1, tti.trigger == inputRange.lowerBound {
            // If deleting the active trigger from an input (i.e. with backward delete) that is not activated exlicitly,
            // we rather just cancel TTI and preserve the triggering character, so users get a chance to use it as is.
            // They can do additional backward delete to delete it.
            cancelTriggering(strategy: nil)
            return false
        } else if let tti, containsTriggerCanceller(insertion) {
            cancelTriggering(strategy: tti.isExplicit ? .deleteTriggerAndPhrase : nil)
        }

        return true
    }

    /// In this method, we are looking for these events to update the state:
    /// + Selection intersects tokens. In this case we adjust the selection so all selected tokens are whole.
    /// + Caret positions changes in a way that we need to either trigger or cancel token input.
    fileprivate func textViewDidChangeSelection(_ textView: UITextView) {

        resetTypingAttributes()

        guard !isPhraseMarkingUpdating else {
            // The phrase marking
            return
        }

        let text = attributedText(withTextTokens: true)
        let selection = selection(in: text)

        if let adjustedSelection = wholeTokensSelection(for: selection, in: text) {
            textView.selectedRange = NSRange(adjustedSelection, in: text)
            // The above assignment caused this method to be called again, so we leave here to avoid
            // interfereing what was done in this stack.
            return
        }

        let newTTI: (trigger: AttributedString.Index, isExplicit: Bool)?
        if selection.lowerBound == text.startIndex {
            // No token input on caret at beginning of the text. This check is importatnt mainly
            // for next steps where we attempt to identify a triggering character in position one character
            // before the caret.
            newTTI = nil
        } else {
            let beforeCaretIndex = text.index(beforeCharacter: selection.lowerBound)
            if triggers.contains(text.characters[beforeCaretIndex]),
               !containsTriggerCanceller(text[selection]),
               // Either TTI is inactive, or preserve the current one. But we don't allow to override current
               // triggering character with another one. We want to allow those characters in phrases.
               tti == nil || tti!.trigger >= beforeCaretIndex {
                // The caret (selection) starts just behind a trigerring character and the selection doesn't contain
                // any cancelling character...
                newTTI = (beforeCaretIndex, tti?.isExplicit ?? isInputTriggerExplicit)
            } else if let tti,
                      beforeCaretIndex > tti.trigger,
                      case let phrase = text[text.index(afterCharacter: tti.trigger) ..< selection.upperBound],
                      !containsTriggerCanceller(phrase) {
                // Going behind the current trigger with carret is ok, everything in between trigger and the caret end
                // is meant to be a phrase (search text), unless there is a cancelling character in the range.
                newTTI = tti
            } else {
                newTTI = nil
            }
        }
        if newTTI?.trigger != tti?.trigger {
            tti = newTTI
        }

        updatePhraseMarking()
        objectWillChange.send()
    }
}

/// A private `UITextViewDelegate` handler type so `TextTokenFieldManager` doesn't need to be `NSObject` and publicly expose
/// required delegate methods.
private final class TextViewDelegate: NSObject, UITextViewDelegate {

    init(manager: TextTokenFieldManager) {
        self.manager = manager
        super.init()
        manager.uiView.delegate = self
    }

    private unowned let manager: TextTokenFieldManager

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        manager.textView(textView, shouldChangeTextIn: range, replacementText: text)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        manager.textViewDidChangeSelection(textView)
    }
}

private extension TextToken {

    var attributes: AttributeContainer { Self.attributes.textToken(AnyTextToken(base: self)) }
}

extension AttributedString {

    mutating func replaceSubrangeReturning(
        _ range: Range<AttributedString.Index>,
        with s: AttributedString
    ) -> Range<AttributedString.Index> {
        replaceSubrange(range, with: s)
        return range.lowerBound ..< index(range.lowerBound, offsetByUnicodeScalars: s.unicodeScalars.count)
    }
}

extension UITextView {

    /// A method that allows to mutate a subrange with a replacement and preserves caret.
    /// - Parameters:
    ///   - text: `attributedText` in value type if you already have it. It will be created if you don't.
    ///   It's just a small optimization.
    func replaceSubrange<Scope: AttributeScope>(
        _ inputRange: Range<AttributedString.Index>,
        with replacement: AttributedString,
        in text: AttributedString? = nil,
        including attributeScope: KeyPath<AttributeScopes, Scope.Type>
    ) throws {

        var text = try text ?? AttributedString(attributedText, including: attributeScope)

        let selectionOffset: (Int, length: Int)?
        if let currentSelection = Range(selectedRange, in: text), currentSelection.lowerBound > inputRange.upperBound {
            // Current selection is further from insertion. We want to preserve location and length.
            let offset = text.unicodeScalars.distance(from: inputRange.upperBound, to: currentSelection.lowerBound)
            let length = text.unicodeScalars.distance(from: currentSelection.lowerBound, to: currentSelection.upperBound)
            selectionOffset = (offset, length)
        } else {
            selectionOffset = nil
        }

        let insertionRange = text.replaceSubrangeReturning(inputRange, with: replacement)

        let newSelection: Range<AttributedString.Index>
        if let selectionOffset {
            let newSelectionStart = text.unicodeScalars.index(insertionRange.upperBound, offsetBy: selectionOffset.0)
            let newSelectionEnd = text.unicodeScalars.index(newSelectionStart, offsetBy: selectionOffset.length)
            newSelection = newSelectionStart ..< newSelectionEnd
        } else {
            newSelection = insertionRange.upperBound ..< insertionRange.upperBound
        }
        let nsNewSelection = NSRange(newSelection, in: text)
        // Setting just attributed string is messed (not sure what is going on but it somehow is being autocorrected
        // even during `autocorrectionType == .no`, and getting out of sync with `selectedRange`...). I observed
        // that setting `text` before remedies this.
        self.text = String(text.characters)
        attributedText = try NSAttributedString(text, including: attributeScope)
        if selectedRange != nsNewSelection {
            selectedRange = nsNewSelection
        }
    }
}
