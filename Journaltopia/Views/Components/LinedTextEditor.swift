import SwiftUI
import UIKit

private extension NSAttributedString.Key {
    static let notebookBold = NSAttributedString.Key("JournaltopiaNotebookBold")
    static let notebookItalic = NSAttributedString.Key("JournaltopiaNotebookItalic")
    static let notebookForegroundColorHex = NSAttributedString.Key("JournaltopiaNotebookForegroundColorHex")
    static let notebookTextStyle = NSAttributedString.Key("JournaltopiaNotebookTextStyle")
}

enum NotebookTextFormattingCommand: Equatable {
    case bold
    case italic
    case underline
    case strikethrough
    case bulletList
    case indent
    case outdent
    case textColor(String)
    /// Drops per-run colors so every run falls back to the page's text color.
    case resetTextColors
    case textStyle(NotebookTextRunStyle)
}

enum NotebookTextRunStyle: String, Codable, Equatable, CaseIterable {
    case body
    case heading1
    case heading2
    case heading3
    case heading4
    case heading5
    case heading6

    var fontScale: CGFloat {
        switch self {
        case .body:
            1
        case .heading1:
            1.45
        case .heading2:
            1.34
        case .heading3:
            1.23
        case .heading4:
            1.14
        case .heading5:
            1.08
        case .heading6:
            1.02
        }
    }

    var usesHeadingWeight: Bool {
        self != .body
    }
}

struct NotebookTextFormattingRun: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var isBold: Bool
    var isItalic: Bool
    var isUnderlined: Bool
    var isStrikethrough: Bool
    var textColorHex: String?
    var textStyleRawValue: String?

    init(
        location: Int,
        length: Int,
        isBold: Bool,
        isItalic: Bool,
        isUnderlined: Bool,
        isStrikethrough: Bool,
        textColorHex: String? = nil,
        textStyleRawValue: String? = nil
    ) {
        self.location = location
        self.length = length
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isStrikethrough = isStrikethrough
        self.textColorHex = textColorHex
        self.textStyleRawValue = textStyleRawValue
    }
}

struct NotebookRichTextDocument: Codable, Equatable, Sendable {
    var text: String
    var formattingRuns: [NotebookTextFormattingRun]

    init(text: String, formattingRuns: [NotebookTextFormattingRun] = []) {
        self.text = text
        self.formattingRuns = formattingRuns
    }

    init(attributedString: NSAttributedString) {
        text = attributedString.string
        var runs: [NotebookTextFormattingRun] = []

        attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: attributedString.length)
        ) { attributes, range, _ in
            let font = attributes[.font] as? UIFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let isBold = (attributes[.notebookBold] as? Bool) ?? false
            let isItalic = (attributes[.notebookItalic] as? Bool) ?? traits.contains(.traitItalic)
            let isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
            let isStrikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            let textColorHex = attributes[.notebookForegroundColorHex] as? String
            let textStyleRawValue = attributes[.notebookTextStyle] as? String
            let run = NotebookTextFormattingRun(
                location: range.location,
                length: range.length,
                isBold: isBold,
                isItalic: isItalic,
                isUnderlined: isUnderlined,
                isStrikethrough: isStrikethrough,
                textColorHex: textColorHex,
                textStyleRawValue: textStyleRawValue
            )

            if run.hasFormatting {
                runs.append(run)
            }
        }

        formattingRuns = runs
    }

    func normalized(for plainText: String) -> NotebookRichTextDocument {
        text == plainText ? self : NotebookRichTextDocument(text: plainText)
    }

    func updatingTextPreservingFormatting(for plainText: String) -> NotebookRichTextDocument {
        guard text != plainText else {
            return self
        }

        guard !formattingRuns.isEmpty else {
            return NotebookRichTextDocument(text: plainText)
        }

        let oldText = text as NSString
        let newText = plainText as NSString
        var sharedPrefixLength = 0
        let shortestLength = min(oldText.length, newText.length)

        while sharedPrefixLength < shortestLength,
              oldText.character(at: sharedPrefixLength) == newText.character(at: sharedPrefixLength) {
            sharedPrefixLength += 1
        }

        var sharedSuffixLength = 0
        while sharedSuffixLength < shortestLength - sharedPrefixLength,
              oldText.character(at: oldText.length - sharedSuffixLength - 1) == newText.character(at: newText.length - sharedSuffixLength - 1) {
            sharedSuffixLength += 1
        }

        let replacedOldUpperBound = oldText.length - sharedSuffixLength
        let replacementDelta = newText.length - oldText.length
        let updatedRuns = formattingRuns.compactMap { run -> NotebookTextFormattingRun? in
            let runUpperBound = run.location + run.length

            if runUpperBound <= sharedPrefixLength {
                return run
            }

            if run.location >= replacedOldUpperBound {
                return NotebookTextFormattingRun(
                    location: run.location + replacementDelta,
                    length: run.length,
                    isBold: run.isBold,
                    isItalic: run.isItalic,
                    isUnderlined: run.isUnderlined,
                    isStrikethrough: run.isStrikethrough,
                    textColorHex: run.textColorHex,
                    textStyleRawValue: run.textStyleRawValue
                )
            }

            let keptPrefixLength = max(0, sharedPrefixLength - run.location)
            let keptSuffixLength = max(0, runUpperBound - replacedOldUpperBound)
            let keptLength = keptPrefixLength + keptSuffixLength
            guard keptLength > 0 else {
                return nil
            }

            if keptPrefixLength > 0 {
                return NotebookTextFormattingRun(
                    location: run.location,
                    length: keptPrefixLength,
                    isBold: run.isBold,
                    isItalic: run.isItalic,
                    isUnderlined: run.isUnderlined,
                    isStrikethrough: run.isStrikethrough,
                    textColorHex: run.textColorHex,
                    textStyleRawValue: run.textStyleRawValue
                )
            }

            return NotebookTextFormattingRun(
                location: replacedOldUpperBound + replacementDelta,
                length: keptSuffixLength,
                isBold: run.isBold,
                isItalic: run.isItalic,
                isUnderlined: run.isUnderlined,
                isStrikethrough: run.isStrikethrough,
                textColorHex: run.textColorHex,
                textStyleRawValue: run.textStyleRawValue
            )
        }

        return NotebookRichTextDocument(text: plainText, formattingRuns: updatedRuns)
    }

    func trimmingCharacters(in characterSet: CharacterSet) -> NotebookRichTextDocument {
        let nsText = text as NSString
        var lowerBound = 0
        var upperBound = nsText.length

        while lowerBound < upperBound,
              let scalar = UnicodeScalar(Int(nsText.character(at: lowerBound))),
              characterSet.contains(scalar) {
            lowerBound += 1
        }

        while upperBound > lowerBound,
              let scalar = UnicodeScalar(Int(nsText.character(at: upperBound - 1))),
              characterSet.contains(scalar) {
            upperBound -= 1
        }

        let keptRange = NSRange(location: lowerBound, length: upperBound - lowerBound)
        let trimmedText = nsText.substring(with: keptRange)
        let trimmedRuns = formattingRuns.compactMap { run -> NotebookTextFormattingRun? in
            let runRange = NSRange(location: run.location, length: run.length)
            let intersection = NSIntersectionRange(runRange, keptRange)
            guard intersection.length > 0 else {
                return nil
            }

            return NotebookTextFormattingRun(
                location: intersection.location - lowerBound,
                length: intersection.length,
                isBold: run.isBold,
                isItalic: run.isItalic,
                isUnderlined: run.isUnderlined,
                isStrikethrough: run.isStrikethrough,
                textColorHex: run.textColorHex,
                textStyleRawValue: run.textStyleRawValue
            )
        }

        return NotebookRichTextDocument(text: trimmedText, formattingRuns: trimmedRuns)
    }

    func attributedString(
        textStyle: NotebookTextStyle,
        usesTexturedPaperEffect: Bool = false
    ) -> NSAttributedString {
        let attributedText = NSMutableAttributedString(
            string: text,
            attributes: NotebookMetrics.typingAttributes(
                for: textStyle,
                usesTexturedPaperEffect: usesTexturedPaperEffect
            )
        )
        let fullRange = NSRange(location: 0, length: attributedText.length)

        for run in formattingRuns {
            let range = NSRange(location: run.location, length: run.length)
            let safeRange = NSIntersectionRange(range, fullRange)
            guard safeRange.length > 0 else {
                continue
            }

            if let runStyle = run.textRunStyle {
                attributedText.setNotebookTextRunStyle(
                    runStyle,
                    textStyle: textStyle,
                    in: safeRange
                )
            }

            if run.isBold {
                attributedText.setNotebookFontStyle(
                    isBold: true,
                    isItalic: run.isItalic,
                    textStyle: textStyle,
                    in: safeRange
                )
            } else if run.isItalic {
                attributedText.setNotebookFontStyle(
                    isBold: false,
                    isItalic: true,
                    textStyle: textStyle,
                    in: safeRange
                )
            }

            if run.isUnderlined {
                attributedText.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: safeRange
                )
            }

            if run.isStrikethrough {
                attributedText.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: safeRange
                )
            }

            if let textColorHex = run.textColorHex,
               let color = UIColor(journaltopiaHexString: textColorHex) {
                attributedText.addAttribute(.foregroundColor, value: color, range: safeRange)
                attributedText.addAttribute(.notebookForegroundColorHex, value: textColorHex, range: safeRange)
            }
        }

        return attributedText
    }
}

private extension NotebookTextFormattingRun {
    var textRunStyle: NotebookTextRunStyle? {
        textStyleRawValue.flatMap(NotebookTextRunStyle.init(rawValue:))
    }

    var hasFormatting: Bool {
        isBold || isItalic || isUnderlined || isStrikethrough || textColorHex != nil || textStyleRawValue != nil
    }
}

struct NotebookTextFormattingRequest: Equatable {
    let id: Int
    let command: NotebookTextFormattingCommand
}

struct NotebookDictationTranscriptRequest: Equatable {
    let id: Int
    let transcript: String
}

struct NotebookTextSelectionState: Equatable {
    var hasSelection = false
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStrikethrough = false
    var textRunStyle: NotebookTextRunStyle = .body
}

enum NotebookMetrics {
    static let ruleSpacing: CGFloat = 32
    static let naturalBodyLineSpacing: CGFloat = 5
    static let bodyFontSize: CGFloat = 16
    static let titleFontSize: CGFloat = bodyFontSize * NotebookTextRunStyle.heading1.fontScale
    static let marginLeading: CGFloat = 30
    static let textLeadingInset: CGFloat = 5
    static let syntheticItalicObliqueness: CGFloat = 0.16

    static var titleFont: UIFont {
        UIFont.systemFont(ofSize: titleFontSize, weight: .bold)
    }

    static var bodyFont: UIFont {
        UIFont.systemFont(ofSize: bodyFontSize, weight: .medium)
    }

    static var ruleUIColor: UIColor {
        UIColor(red: 0.45, green: 0.58, blue: 0.78, alpha: 0.24)
    }

    static var bodyTextUIColor: UIColor {
        UIColor(red: 0.08, green: 0.07, blue: 0.22, alpha: 0.78)
    }

    static var typingParagraphStyle: NSParagraphStyle {
        typingParagraphStyle(alignment: .natural)
    }

    static func typingParagraphStyle(alignment: NSTextAlignment) -> NSParagraphStyle {
        typingParagraphStyle(alignment: alignment, lineHeight: ruleSpacing)
    }

    static func typingParagraphStyle(alignment: NSTextAlignment, lineHeight: CGFloat?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        if let lineHeight {
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
        }
        style.lineSpacing = lineHeight == nil ? naturalBodyLineSpacing : 0
        style.paragraphSpacing = 0
        style.lineBreakMode = .byWordWrapping
        style.alignment = alignment
        return style
    }

    static var typingAttributes: [NSAttributedString.Key: Any] {
        typingAttributes(for: .default)
    }

    static func titleFont(for style: NotebookTextStyle) -> Font {
        Font(uiFont(for: style, size: style.titleFontSize, isBold: true, isItalic: false))
    }

    static func bodyPlaceholderFont(for style: NotebookTextStyle) -> Font {
        if let customFontName = style.customFontName {
            return VariableFont.font(
                name: customFontName,
                size: style.scaledBodyFontSize,
                weight: style.customFontWeight,
                usesWeightAxis: style.customFontUsesVariableWeight,
                wghtOverride: style.customFontWght
            )
        }

        return .system(size: style.bodyFontSize, weight: style.bodyFontWeight, design: style.swiftUIDesign)
    }

    static func uiBodyFont(for style: NotebookTextStyle) -> UIFont {
        uiBodyFont(for: style, isBold: false, isItalic: false)
    }

    static func uiBodyFont(
        for style: NotebookTextStyle,
        isBold: Bool,
        isItalic: Bool
    ) -> UIFont {
        uiFont(for: style, size: style.scaledBodyFontSize, isBold: isBold, isItalic: isItalic)
    }

    /// Shared font construction for title, body, and headings so weight matches across SwiftUI and UIKit.
    static func uiFont(
        for style: NotebookTextStyle,
        size: CGFloat,
        isBold: Bool,
        isItalic: Bool
    ) -> UIFont {
        if let customFontName = style.customFontName,
           let customFont = VariableFont.uiFont(
               name: isBold ? style.customFontBoldName ?? customFontName : customFontName,
               size: size,
               weight: isBold ? style.customFontBoldWeight : style.customFontWeight,
               usesWeightAxis: style.customFontUsesVariableWeight,
               wghtOverride: isBold ? style.customFontBoldWght : style.customFontWght
           ) {
            return resolvedItalicFont(customFont, isItalic: isItalic)
        }

        let baseFont = UIFont.systemFont(
            ofSize: size,
            weight: isBold ? .bold : uiFontWeight(for: style.bodyFontWeight)
        )
        guard var descriptor = baseFont.fontDescriptor.withDesign(style.uiKitDesign) else {
            return resolvedItalicFont(baseFont, isItalic: isItalic)
        }

        // Weight already encodes bold — only layer italic here to avoid double-bold.
        if isItalic {
            var traits = descriptor.symbolicTraits
            traits.insert(.traitItalic)
            if let italicDescriptor = descriptor.withSymbolicTraits(traits) {
                descriptor = italicDescriptor
            }
        }

        return UIFont(descriptor: descriptor, size: size)
    }

    private static func uiFontWeight(for weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight:
            return .ultraLight
        case .thin:
            return .thin
        case .light:
            return .light
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        case .heavy:
            return .heavy
        case .black:
            return .black
        default:
            return .regular
        }
    }

    static func typingAttributes(
        for style: NotebookTextStyle,
        usesTexturedPaperEffect: Bool = false,
        isBold: Bool = false,
        isItalic: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: uiBodyFont(for: style, isBold: isBold, isItalic: isItalic),
            .foregroundColor: usesTexturedPaperEffect ? UIColor.clear : style.uiColor,
            .paragraphStyle: typingParagraphStyle(alignment: .natural, lineHeight: style.bodyLineHeight)
        ]

        if isBold {
            attributes[.notebookBold] = true

            if shouldUseSyntheticBold(for: style) {
                attributes[.strokeWidth] = -2
            }
        }

        if isItalic {
            attributes[.notebookItalic] = true

            if shouldUseSyntheticItalic(for: style) {
                attributes[.obliqueness] = syntheticItalicObliqueness
            }
        }

        return attributes
    }

    static func shouldUseSyntheticItalic(for style: NotebookTextStyle) -> Bool {
        style.customFontName != nil
    }

    static func shouldUseSyntheticBold(for style: NotebookTextStyle) -> Bool {
        style.customFontName != nil &&
            !style.customFontUsesVariableWeight &&
            style.customFontBoldName == nil &&
            style.customFontAllowsSyntheticBold
    }

    private static func resolvedItalicFont(_ font: UIFont, isItalic: Bool) -> UIFont {
        guard isItalic else {
            return font
        }

        var traits = font.fontDescriptor.symbolicTraits
        traits.insert(.traitItalic)

        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else {
            return font
        }

        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// Vertical inset so placeholder text matches the text view's first-line position.
    static func firstLineTextTopInset(for style: NotebookTextStyle) -> CGFloat {
        guard let bodyLineHeight = style.bodyLineHeight else {
            return 0
        }

        return max(0, (bodyLineHeight - uiBodyFont(for: style).lineHeight) / 2 + 8)
    }

    static var titleLineTextTopInset: CGFloat {
        max(0, (ruleSpacing - titleFont.lineHeight) / 2)
    }

    static let titleBodySpacing: CGFloat = 10
    static let contentTopPadding: CGFloat = 14
    static let contentBottomPadding: CGFloat = 18

    static var firstNotebookRuleY: CGFloat {
        contentTopPadding + (ruleSpacing * 2)
    }

    static func bodyAreaMinHeight(forPageHeight pageHeight: CGFloat, titleBodySpacing: CGFloat = 0) -> CGFloat {
        let availableHeight = pageHeight - contentTopPadding - contentBottomPadding - ruleSpacing - titleBodySpacing
        return max(ruleSpacing * 3, availableHeight)
    }

    static var ruleColor: Color {
        Color(red: 0.45, green: 0.58, blue: 0.78).opacity(0.24)
    }

    static var minimumBodyHeight: CGFloat {
        ruleSpacing * 8
    }
}

struct NotebookTextStyle: Equatable {
    var swiftUIDesign: Font.Design = .serif
    var uiKitDesign: UIFontDescriptor.SystemDesign = .serif
    var customFontName: String?
    var customFontBoldName: String?
    var customFontWeight: Font.Weight = .regular
    var customFontWght: CGFloat?
    var customFontBoldWeight: Font.Weight = .bold
    var customFontBoldWght: CGFloat?
    var customFontUsesVariableWeight: Bool = false
    var customFontAllowsSyntheticBold: Bool = true
    var customFontSizeScale: CGFloat = 1
    var bodyFontWeight: Font.Weight = .regular
    var bodyFontSize: CGFloat = NotebookMetrics.bodyFontSize
    var bodyLineHeight: CGFloat? = NotebookMetrics.ruleSpacing
    var color: Color = Color(NotebookMetrics.bodyTextUIColor)
    var uiColor: UIColor = NotebookMetrics.bodyTextUIColor

    static let `default` = NotebookTextStyle()

    var scaledBodyFontSize: CGFloat {
        bodyFontSize * customFontSizeScale
    }

    var titleFontSize: CGFloat {
        scaledBodyFontSize * NotebookTextRunStyle.heading1.fontScale
    }
}

enum TexturedPaperTextEffect {
    static func shouldMultiplyBlend(_ color: UIColor) -> Bool {
        relativeLuminance(of: color) < 0.55
    }

    static func inkShadow(for color: UIColor) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowOffset = CGSize(width: 0, height: -0.45)
        shadow.shadowBlurRadius = 0.45
        shadow.shadowColor = UIColor.black.withAlphaComponent(shouldMultiplyBlend(color) ? 0.16 : 0.1)
        return shadow
    }

    static func titleShadowColor(for color: UIColor) -> Color {
        Color.black.opacity(shouldMultiplyBlend(color) ? 0.16 : 0.1)
    }

    static func bodyShadowColor(for color: UIColor) -> UIColor {
        UIColor.black.withAlphaComponent(shouldMultiplyBlend(color) ? 0.28 : 0.18)
    }

    static func bodyHighlightColor(for color: UIColor) -> UIColor {
        UIColor.white.withAlphaComponent(shouldMultiplyBlend(color) ? 0.24 : 0.16)
    }

    private static func relativeLuminance(of color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return 0
        }

        return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    private static func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

final class LinedTextView: UITextView {
    private static let bulletPrefix = "• "
    private static let indentPrefix = "    "
    private static weak var attachedInstance: LinedTextView?

    @discardableResult
    static func becomeActiveFirstResponder() -> Bool {
        attachedInstance?.becomeFirstResponder() ?? false
    }

    func attachAsActiveEditor() {
        Self.attachedInstance = self
    }

    func detachIfActive() {
        if Self.attachedInstance === self {
            Self.attachedInstance = nil
        }
    }

    var ruleSpacing: CGFloat = NotebookMetrics.ruleSpacing
    var notebookTextStyle: NotebookTextStyle = .default {
        didSet {
            applyTextStyle()
        }
    }
    var textLeadingInset = NotebookMetrics.textLeadingInset {
        didSet {
            applyTextContainerInset()
        }
    }
    var drawsRuledLines = true
    var scrollsInternally = true {
        didSet {
            applyScrollBehavior()
        }
    }
    var usesTexturedPaperEffect = false {
        didSet {
            applyTextStyle()
        }
    }
    var keyboardInputMode: NotebookEditorInputMode = .systemKeyboard {
        didSet {
            guard oldValue != keyboardInputMode else {
                return
            }
            applyInputViews(reloadIfNeeded: true)
        }
    }
    var showsKeyboardAccessory = false {
        didSet {
            guard oldValue != showsKeyboardAccessory else {
                return
            }
            applyInputViews(reloadIfNeeded: true)
        }
    }
    var onEditingEnded: (() -> Void)?

    private let toolbarHost = NotebookAnyViewInputHost(fixedHeight: NotebookAnyViewInputHost.toolbarHeight)
    private let panelHost = NotebookAnyViewInputHost(fixedHeight: nil)
    private lazy var panelInputView = NotebookInputPanelView(contentHost: panelHost)
    private var isTypingBold = false
    private var isTypingItalic = false
    private var typingTextRunStyle: NotebookTextRunStyle = .body
    private var storedRichTextDocument = NotebookRichTextDocument(text: "")

    /// Dictation inserts at the caret like system keyboard dictation, instead of rewriting the whole string.
    private var isDictating = false
    private var isApplyingDictation = false
    private var dictationNeedsReanchor = false
    private var dictationLiveRange: NSRange?
    private var dictationCommittedTranscript = ""
    private var dictationLiveTranscript = ""
    private var dictationLastTranscript = ""

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configureNotebookAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureNotebookAppearance()
    }

    private func configureNotebookAppearance() {
        backgroundColor = .clear
        applyTextContainerInset()
        textContainer.lineFragmentPadding = 0
        applyTextStyle()
        returnKeyType = .default
        showsHorizontalScrollIndicator = false
        keyboardDismissMode = .interactive
        applyScrollBehavior()
        applyInputViews(reloadIfNeeded: false)
    }

    func setKeyboardAccessoryContent(_ view: AnyView) {
        toolbarHost.setRootView(view)
    }

    func setKeyboardPanelContent(_ view: AnyView) {
        panelHost.setRootView(view)
    }

    func releaseKeyboardChrome() {
        let wasFirstResponder = isFirstResponder

        inputAccessoryView = nil
        inputView = nil

        if wasFirstResponder {
            reloadInputViews()
        }
    }

    private func applyInputViews(reloadIfNeeded: Bool) {
        inputAccessoryView = showsKeyboardAccessory ? toolbarHost : nil

        switch keyboardInputMode {
        case .systemKeyboard:
            inputView = nil
        case .formattingPanel:
            inputView = panelInputView
        }

        toolbarHost.invalidateIntrinsicContentSize()

        if reloadIfNeeded, isFirstResponder {
            reloadInputViews()
        }
    }

    private func applyTextContainerInset() {
        textContainerInset = UIEdgeInsets(
            top: 0,
            left: textLeadingInset,
            bottom: 0,
            right: 0
        )
    }

    private func applyTextStyle() {
        let document = storedRichTextDocument.normalized(for: text ?? "")
        storedRichTextDocument = document
        let selectedRange = selectedRange
        font = NotebookMetrics.uiBodyFont(for: notebookTextStyle)
        textColor = usesTexturedPaperEffect ? .clear : notebookTextStyle.uiColor
        attributedText = document.attributedString(
            textStyle: notebookTextStyle,
            usesTexturedPaperEffect: usesTexturedPaperEffect
        )
        self.selectedRange = Self.clampedSelection(selectedRange, textLength: document.text.utf16.count)
        refreshTypingAttributes()
        layer.compositingFilter = nil
        setNeedsDisplay()
    }

    private func applyScrollBehavior() {
        isScrollEnabled = scrollsInternally
        alwaysBounceVertical = scrollsInternally
        showsVerticalScrollIndicator = scrollsInternally
    }

    override var intrinsicContentSize: CGSize {
        guard !scrollsInternally else {
            return super.intrinsicContentSize
        }

        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        return sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        let rect = super.caretRect(for: position)
        guard notebookTextStyle.bodyLineHeight == NotebookMetrics.ruleSpacing,
              let bodyLineHeight = notebookTextStyle.bodyLineHeight else {
            return rect
        }

        let font = activeCaretFont()
        let lineHeight = max(bodyLineHeight, font.lineHeight)
        let height = ceil(font.lineHeight)
        let textAlignedY = rect.minY + max(0, (lineHeight - font.lineHeight) / 2) + 6

        return CGRect(
            x: rect.minX,
            y: min(textAlignedY, rect.maxY - height),
            width: rect.width,
            height: height
        )
    }

    private func activeCaretFont() -> UIFont {
        if let typingFont = typingAttributes[.font] as? UIFont {
            return typingFont
        }

        var adjustedStyle = notebookTextStyle
        adjustedStyle.bodyFontSize = notebookTextStyle.bodyFontSize * typingTextRunStyle.fontScale
        return NotebookMetrics.uiBodyFont(
            for: adjustedStyle,
            isBold: isTypingBold || typingTextRunStyle.usesHeadingWeight,
            isItalic: isTypingItalic
        )
    }

    func refreshLayoutAfterContentChange() {
        setNeedsDisplay()
        guard !scrollsInternally else {
            return
        }

        invalidateIntrinsicContentSize()
    }

    func moveCaretToEndAndReveal() {
        let endLocation = (text as NSString?)?.length ?? 0
        let endRange = NSRange(location: endLocation, length: 0)
        selectedRange = endRange

        if scrollsInternally {
            scrollRangeToVisible(endRange)
            return
        }

        scrollCaretIntoEnclosingScrollViewIfNeeded()
    }

    func setDictating(_ dictating: Bool) {
        guard isDictating != dictating else {
            return
        }

        isDictating = dictating
        if dictating {
            beginDictationSession()
        } else {
            endDictationSession()
        }
    }

    func markDictationUserEdit() {
        guard isDictating, !isApplyingDictation else {
            return
        }

        dictationNeedsReanchor = true
    }

    func markDictationSelectionChange() {
        guard isDictating, !isApplyingDictation, let liveRange = dictationLiveRange else {
            return
        }

        let caret = selectedRange.location
        let liveEnd = liveRange.location + liveRange.length
        if selectedRange.length == 0, caret == liveEnd {
            return
        }

        dictationNeedsReanchor = true
    }

    func applyDictationTranscript(_ transcript: String) {
        guard isDictating else {
            return
        }

        let sanitized = Self.sanitizedDictationTranscript(transcript)
        guard !sanitized.isEmpty else {
            return
        }

        if dictationLiveRange == nil || dictationNeedsReanchor {
            reanchorDictationAtCaret()
        }

        let nextLiveTranscript = resolvedDictationLiveTranscript(from: sanitized)
        guard nextLiveTranscript != dictationLiveTranscript else {
            dictationLastTranscript = sanitized
            return
        }

        replaceDictationLiveText(with: nextLiveTranscript)
        dictationLiveTranscript = nextLiveTranscript
        dictationLastTranscript = sanitized
    }

    private func beginDictationSession() {
        dictationCommittedTranscript = ""
        dictationLiveTranscript = ""
        dictationLastTranscript = ""
        dictationNeedsReanchor = false
        dictationLiveRange = NSRange(location: selectedRange.location, length: 0)
    }

    private func endDictationSession() {
        dictationLiveRange = nil
        dictationCommittedTranscript = ""
        dictationLiveTranscript = ""
        dictationLastTranscript = ""
        dictationNeedsReanchor = false
        isApplyingDictation = false
    }

    private func reanchorDictationAtCaret() {
        // Keep already-inserted speech; only new words go in at the current caret
        // (e.g. after the user presses Return).
        dictationCommittedTranscript = dictationLastTranscript
        dictationLiveTranscript = ""
        let caret = max(0, min(selectedRange.location, (text as NSString?)?.length ?? 0))
        dictationLiveRange = NSRange(location: caret, length: 0)
        dictationNeedsReanchor = false
    }

    private func resolvedDictationLiveTranscript(from sessionTranscript: String) -> String {
        if dictationCommittedTranscript.isEmpty {
            return sessionTranscript
        }

        if let remainder = dictationTranscriptRemainder(of: sessionTranscript, after: dictationCommittedTranscript) {
            return remainder
        }

        if sessionTranscript.hasPrefix(dictationLastTranscript) {
            let previousLength = (dictationLastTranscript as NSString).length
            let delta = (sessionTranscript as NSString)
                .substring(from: previousLength)
                .strippingLeadingDictationWhitespace
            guard !delta.isEmpty else {
                return dictationLiveTranscript
            }

            return dictationLiveTranscript.isEmpty
                ? delta
                : dictationInsertion(delta, afterText: dictationLiveTranscript)
        }

        return dictationLiveTranscript
    }

    private func dictationTranscriptRemainder(of sessionTranscript: String, after committed: String) -> String? {
        guard sessionTranscript.hasPrefix(committed) else {
            return nil
        }

        let committedLength = (committed as NSString).length
        return (sessionTranscript as NSString)
            .substring(from: committedLength)
            .strippingLeadingDictationWhitespace
    }

    private func replaceDictationLiveText(with live: String) {
        guard let liveRange = dictationLiveRange else {
            return
        }

        let plain = text ?? ""
        let nsPlain = plain as NSString
        let textLength = nsPlain.length
        let location = max(0, min(liveRange.location, textLength))
        let length = max(0, min(liveRange.length, textLength - location))
        let safeRange = NSRange(location: location, length: length)
        let insertion = dictationInsertion(live, afterLocation: location)

        isApplyingDictation = true

        // Assigning `attributedText`/`selectedRange` bypasses UIKit's text input machinery,
        // so the keyboard keeps serving a stale document context and stops auto-shifting
        // after a typed "." or Return for the rest of the dictation session. Bracketing the
        // mutation with input-delegate callbacks makes it re-read the document.
        let keyboardInputDelegate = inputDelegate
        keyboardInputDelegate?.selectionWillChange(self)
        keyboardInputDelegate?.textWillChange(self)

        let mutableText = NSMutableAttributedString(attributedString: attributedText ?? NSAttributedString(string: plain))
        let attributedInsertion = NSAttributedString(
            string: insertion,
            attributes: currentTypingAttributes()
        )
        mutableText.replaceCharacters(in: safeRange, with: attributedInsertion)
        attributedText = mutableText
        updateStoredRichTextDocument()

        let insertedLength = (insertion as NSString).length
        dictationLiveRange = NSRange(location: location, length: insertedLength)
        selectedRange = NSRange(location: location + insertedLength, length: 0)
        typingAttributes = currentTypingAttributes()

        keyboardInputDelegate?.textDidChange(self)
        keyboardInputDelegate?.selectionDidChange(self)

        notifyTextDidChange()
        refreshLayoutAfterContentChange()
        scrollCaretIntoEnclosingScrollViewIfNeeded()
        isApplyingDictation = false
    }

    private func dictationInsertion(_ live: String, afterText preceding: String) -> String {
        guard !live.isEmpty else {
            return preceding
        }

        if preceding.isEmpty {
            return live
        }

        if preceding.last?.isWhitespace == true || live.startsWithAttachedDictationPunctuation {
            return preceding + live
        }

        return preceding + " " + live
    }

    private func dictationInsertion(_ live: String, afterLocation location: Int) -> String {
        guard !live.isEmpty else {
            return ""
        }

        guard location > 0, let plain = text, !plain.isEmpty else {
            return live.capitalizingFirstDictationLetter
        }

        let nsPlain = plain as NSString
        guard location <= nsPlain.length else {
            return live.capitalizingFirstDictationLetter
        }

        let body = dictationStartsSentence(in: nsPlain, before: location)
            ? live.capitalizingFirstDictationLetter
            : live

        let previous = nsPlain.character(at: location - 1)
        if let scalar = UnicodeScalar(Int(previous)),
           CharacterSet.whitespacesAndNewlines.contains(scalar)
            || live.startsWithAttachedDictationPunctuation {
            return body
        }

        return " " + body
    }

    /// Speech results are formatted in isolation, so the recognizer never sees a "." the
    /// user typed on the keyboard or a Return they pressed mid-session — it keeps
    /// transcribing as if the sentence continued. Ask the document instead.
    private func dictationStartsSentence(in plain: NSString, before location: Int) -> Bool {
        var index = location - 1

        while index >= 0 {
            guard let scalar = UnicodeScalar(plain.character(at: index)) else {
                return false
            }

            if CharacterSet.newlines.contains(scalar) {
                return true
            }

            if CharacterSet.whitespaces.contains(scalar) {
                index -= 1
                continue
            }

            let character = Character(scalar)
            if character == "." || character == "!" || character == "?" {
                return true
            }

            // Skip closing punctuation so `He said "stop."` still ends a sentence.
            if ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}"].contains(character) {
                index -= 1
                continue
            }

            return false
        }

        return true
    }

    private static func sanitizedDictationTranscript(_ transcript: String) -> String {
        let withoutLineBreaks = transcript
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")

        return withoutLineBreaks
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func scrollCaretIntoEnclosingScrollViewIfNeeded() {
        guard let selectedTextRange else {
            return
        }

        let caret = caretRect(for: selectedTextRange.start)
        var ancestor: UIView? = superview

        while let view = ancestor {
            defer { ancestor = view.superview }

            guard let scrollView = view as? UIScrollView, scrollView !== self else {
                continue
            }

            let caretInScroll = convert(caret, to: scrollView)
            let visibleMinY = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            let visibleMaxY = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
            let padding: CGFloat = 36

            var targetOffsetY = scrollView.contentOffset.y
            if caretInScroll.maxY > visibleMaxY - padding {
                targetOffsetY = caretInScroll.maxY - scrollView.bounds.height + scrollView.adjustedContentInset.bottom + padding
            } else if caretInScroll.minY < visibleMinY + padding {
                targetOffsetY = caretInScroll.minY - scrollView.adjustedContentInset.top - padding
            } else {
                return
            }

            let minOffsetY = -scrollView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            targetOffsetY = min(max(targetOffsetY, minOffsetY), maxOffsetY)

            guard abs(targetOffsetY - scrollView.contentOffset.y) > 0.5 else {
                return
            }

            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY),
                animated: true
            )
            return
        }
    }

    func setNotebookText(
        _ string: String,
        richText: NotebookRichTextDocument? = nil,
        moveCaretToEnd: Bool = false
    ) {
        let document = richText?.normalized(for: string) ?? NotebookRichTextDocument(text: string)
        storedRichTextDocument = document
        let textLength = (string as NSString).length

        if string.isEmpty {
            text = ""
            selectedRange = NSRange(location: 0, length: 0)
            refreshTypingAttributes()
            refreshLayoutAfterContentChange()
            return
        }

        let selectedRange = selectedRange
        attributedText = document.attributedString(
            textStyle: notebookTextStyle,
            usesTexturedPaperEffect: usesTexturedPaperEffect
        )
        if moveCaretToEnd {
            self.selectedRange = NSRange(location: textLength, length: 0)
        } else {
            self.selectedRange = Self.clampedSelection(selectedRange, textLength: textLength)
        }
        refreshTypingAttributes()
        refreshLayoutAfterContentChange()
    }

    fileprivate static func clampedSelection(_ range: NSRange, textLength: Int) -> NSRange {
        guard textLength >= 0, range.location != NSNotFound else {
            return NSRange(location: 0, length: 0)
        }

        let location = min(max(range.location, 0), textLength)
        let length = min(max(range.length, 0), textLength - location)
        return NSRange(location: location, length: length)
    }

    func normalizeAttributesPreservingSelection() {
        guard let text, !text.isEmpty else {
            return
        }

        let selectedRange = selectedRange
        let attributes = NotebookMetrics.typingAttributes(
            for: notebookTextStyle,
            usesTexturedPaperEffect: usesTexturedPaperEffect
        )
        attributedText = NSAttributedString(string: text, attributes: attributes)
        updateStoredRichTextDocument()
        self.selectedRange = Self.clampedSelection(selectedRange, textLength: (text as NSString).length)
        refreshTypingAttributes()
    }

    func applyFormattingCommand(_ command: NotebookTextFormattingCommand) {
        if command == .bulletList {
            applyBulletToCurrentLine()
            return
        }

        if command == .indent {
            applyIndentToSelectedLines()
            return
        }

        if command == .outdent {
            applyOutdentToSelectedLines()
            return
        }

        if command == .resetTextColors {
            removeAllTextColorRuns()
            return
        }

        if case .textStyle(let textRunStyle) = command {
            applyTextRunStyleToCurrentParagraph(textRunStyle)
            return
        }

        let range = selectedRange
        guard range.length > 0, range.location != NSNotFound else {
            toggleTypingFormatting(command)
            return
        }

        let mutableText = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutableText.length)
        guard NSIntersectionRange(range, fullRange).length == range.length else {
            return
        }

        switch command {
        case .bold:
            let shouldAddBold = !mutableText.containsNotebookStyle(.notebookBold, in: range)
            mutableText.setNotebookFontStyle(
                isBold: shouldAddBold,
                isItalic: nil,
                textStyle: notebookTextStyle,
                in: range
            )
            isTypingBold = shouldAddBold
        case .italic:
            let shouldAddItalic = !mutableText.containsNotebookStyle(.notebookItalic, in: range)
            mutableText.setNotebookFontStyle(
                isBold: nil,
                isItalic: shouldAddItalic,
                textStyle: notebookTextStyle,
                in: range
            )
            isTypingItalic = shouldAddItalic
        case .underline:
            mutableText.toggleIntegerStyle(.underlineStyle, in: range)
        case .strikethrough:
            mutableText.toggleIntegerStyle(.strikethroughStyle, in: range)
        case .bulletList:
            break
        case .indent, .outdent:
            break
        case .textColor(let hexString):
            mutableText.applyNotebookForegroundColor(hexString, in: range)
        case .resetTextColors, .textStyle:
            break
        }

        attributedText = mutableText
        updateStoredRichTextDocument()
        selectedRange = range
        refreshTypingAttributes()
        notifyTextDidChange()
        setNeedsDisplay()
    }

    func richTextDocument() -> NotebookRichTextDocument {
        storedRichTextDocument.normalized(for: text ?? "")
    }

    private func removeAllTextColorRuns() {
        guard let attributedText, attributedText.length > 0 else {
            refreshTypingAttributes()
            return
        }

        let selection = selectedRange
        let fullRange = NSRange(location: 0, length: attributedText.length)
        let mutableText = NSMutableAttributedString(attributedString: attributedText)
        mutableText.removeAttribute(.notebookForegroundColorHex, range: fullRange)
        mutableText.addAttribute(
            .foregroundColor,
            value: usesTexturedPaperEffect ? UIColor.clear : notebookTextStyle.uiColor,
            range: fullRange
        )

        self.attributedText = mutableText
        updateStoredRichTextDocument()
        selectedRange = Self.clampedSelection(selection, textLength: mutableText.length)
        refreshTypingAttributes()
        notifyTextDidChange()
        setNeedsDisplay()
    }

    private func applyTextRunStyleToCurrentParagraph(_ textRunStyle: NotebookTextRunStyle) {
        let range = selectedRange
        guard range.location != NSNotFound else {
            return
        }

        let plain = text ?? ""
        let nsPlain = plain as NSString
        let mutableText = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutableText.length)
        guard fullRange.length > 0 else {
            return
        }

        let paragraphRange = selectedParagraphRange(in: nsPlain, selectedRange: range)
        let stylingRange = paragraphRangeWithoutTrailingNewlines(paragraphRange, in: nsPlain)
        guard stylingRange.length > 0,
              NSIntersectionRange(stylingRange, fullRange).length == stylingRange.length else {
            return
        }

        mutableText.setNotebookTextRunStyle(
            textRunStyle,
            textStyle: notebookTextStyle,
            in: stylingRange
        )

        attributedText = mutableText
        updateStoredRichTextDocument()
        selectedRange = range
        typingTextRunStyle = textRunStyle
        refreshTypingAttributes()
        notifyTextDidChange()
        setNeedsDisplay()
    }

    private func selectedParagraphRange(in plainText: NSString, selectedRange: NSRange) -> NSRange {
        let textLength = plainText.length
        let safeLocation = min(max(selectedRange.location, 0), textLength)
        let startRange = plainText.lineRange(for: NSRange(location: safeLocation, length: 0))

        guard selectedRange.length > 0 else {
            return startRange
        }

        let selectionEnd = min(safeLocation + selectedRange.length, textLength)
        let lastSelectedLocation = max(safeLocation, selectionEnd - 1)
        let endRange = plainText.lineRange(for: NSRange(location: lastSelectedLocation, length: 0))
        return NSUnionRange(startRange, endRange)
    }

    private func paragraphRangeWithoutTrailingNewlines(_ range: NSRange, in plainText: NSString) -> NSRange {
        var length = min(range.length, plainText.length - range.location)

        while length > 0 {
            let character = plainText.character(at: range.location + length - 1)
            guard let scalar = UnicodeScalar(Int(character)),
                  CharacterSet.newlines.contains(scalar) else {
                break
            }

            length -= 1
        }

        return NSRange(location: range.location, length: length)
    }

    private func applyBulletToCurrentLine() {
        let cursor = selectedRange.location
        guard cursor != NSNotFound else {
            return
        }

        let plain = text ?? ""
        let nsPlain = plain as NSString
        let lineRange = nsPlain.lineRange(for: NSRange(location: cursor, length: 0))
        let lineText = nsPlain
            .substring(with: lineRange)
            .trimmingCharacters(in: .newlines)

        if lineText.hasPrefix(Self.bulletPrefix) {
            removeBulletFromLine(at: lineRange, cursor: cursor)
        } else {
            addBulletToLine(at: lineRange, cursor: cursor)
        }
    }

    private func addBulletToLine(at lineRange: NSRange, cursor: Int) {
        let attributes = currentTypingAttributes()
        let mutableText = NSMutableAttributedString(attributedString: attributedText)
        mutableText.insert(
            NSAttributedString(string: Self.bulletPrefix, attributes: attributes),
            at: lineRange.location
        )

        attributedText = mutableText
        updateStoredRichTextDocument()
        selectedRange = NSRange(
            location: cursor >= lineRange.location ? cursor + Self.bulletPrefix.count : cursor,
            length: 0
        )
        typingAttributes = attributes
        notifyTextDidChange()
        setNeedsDisplay()
    }

    private func removeBulletFromLine(at lineRange: NSRange, cursor: Int) {
        let attributes = currentTypingAttributes()
        let mutableText = NSMutableAttributedString(attributedString: attributedText)
        mutableText.deleteCharacters(in: NSRange(location: lineRange.location, length: Self.bulletPrefix.count))

        let newCursor: Int
        if cursor >= lineRange.location + Self.bulletPrefix.count {
            newCursor = cursor - Self.bulletPrefix.count
        } else if cursor > lineRange.location {
            newCursor = lineRange.location
        } else {
            newCursor = cursor
        }

        attributedText = mutableText
        updateStoredRichTextDocument()
        selectedRange = NSRange(location: newCursor, length: 0)
        typingAttributes = attributes
        notifyTextDidChange()
        setNeedsDisplay()
    }

    private func applyIndentToSelectedLines() {
        let range = selectedRange
        guard range.location != NSNotFound else {
            return
        }

        let plain = text ?? ""
        let nsPlain = plain as NSString
        let mutableText = NSMutableAttributedString(attributedString: attributedText)
        let paragraphRange = selectedParagraphRange(in: nsPlain, selectedRange: range)
        let lineStarts = selectedLineStartLocations(in: nsPlain, paragraphRange: paragraphRange)
        guard !lineStarts.isEmpty else {
            return
        }

        let attributes = currentTypingAttributes()
        for lineStart in lineStarts.reversed() {
            mutableText.insert(
                NSAttributedString(string: Self.indentPrefix, attributes: attributes),
                at: lineStart
            )
        }

        attributedText = mutableText
        updateStoredRichTextDocument()
        selectedRange = adjustedRangeAfterInsertions(
            at: lineStarts,
            insertedLength: Self.indentPrefix.count,
            originalRange: range
        )
        typingAttributes = attributes
        notifyTextDidChange()
        setNeedsDisplay()
    }

    private func applyOutdentToSelectedLines() {
        let range = selectedRange
        guard range.location != NSNotFound else {
            return
        }

        let plain = text ?? ""
        let nsPlain = plain as NSString
        let mutableText = NSMutableAttributedString(attributedString: attributedText)
        let paragraphRange = selectedParagraphRange(in: nsPlain, selectedRange: range)
        let deletionRanges = selectedLineStartLocations(in: nsPlain, paragraphRange: paragraphRange)
            .compactMap { outdentDeletionRange(in: nsPlain, lineStart: $0) }
        guard !deletionRanges.isEmpty else {
            return
        }

        for deletionRange in deletionRanges.reversed() {
            mutableText.deleteCharacters(in: deletionRange)
        }

        let attributes = currentTypingAttributes()
        attributedText = mutableText
        updateStoredRichTextDocument()
        selectedRange = adjustedRangeAfterDeletions(deletionRanges, originalRange: range)
        typingAttributes = attributes
        notifyTextDidChange()
        setNeedsDisplay()
    }

    private func selectedLineStartLocations(in plainText: NSString, paragraphRange: NSRange) -> [Int] {
        let upperBound = min(paragraphRange.location + paragraphRange.length, plainText.length)
        guard paragraphRange.location <= upperBound else {
            return []
        }

        var locations: [Int] = []
        var location = paragraphRange.location

        repeat {
            locations.append(location)
            guard location < upperBound else {
                break
            }

            let lineRange = plainText.lineRange(for: NSRange(location: location, length: 0))
            let nextLocation = lineRange.location + lineRange.length
            guard nextLocation > location else {
                break
            }

            location = nextLocation
        } while location < upperBound

        return locations
    }

    private func outdentDeletionRange(in plainText: NSString, lineStart: Int) -> NSRange? {
        guard lineStart < plainText.length else {
            return nil
        }

        let lineRange = plainText.lineRange(for: NSRange(location: lineStart, length: 0))
        let lineEnd = min(lineRange.location + lineRange.length, plainText.length)
        guard lineStart < lineEnd else {
            return nil
        }

        let firstCharacter = plainText.character(at: lineStart)
        if firstCharacter == 9 {
            return NSRange(location: lineStart, length: 1)
        }

        var spacesToRemove = 0
        while spacesToRemove < Self.indentPrefix.count,
              lineStart + spacesToRemove < lineEnd,
              plainText.character(at: lineStart + spacesToRemove) == 32 {
            spacesToRemove += 1
        }

        return spacesToRemove > 0 ? NSRange(location: lineStart, length: spacesToRemove) : nil
    }

    private func adjustedRangeAfterInsertions(
        at insertionLocations: [Int],
        insertedLength: Int,
        originalRange: NSRange
    ) -> NSRange {
        let originalStart = originalRange.location
        let originalEnd = originalRange.location + originalRange.length
        let adjustedStart = originalStart + insertionLocations.filter { $0 <= originalStart }.count * insertedLength
        let adjustedEnd = originalEnd + insertionLocations.filter { $0 < originalEnd || originalRange.length == 0 && $0 <= originalEnd }.count * insertedLength
        return NSRange(location: adjustedStart, length: max(0, adjustedEnd - adjustedStart))
    }

    private func adjustedRangeAfterDeletions(
        _ deletionRanges: [NSRange],
        originalRange: NSRange
    ) -> NSRange {
        let originalStart = originalRange.location
        let originalEnd = originalRange.location + originalRange.length
        let adjustedStart = adjustedPositionAfterDeletions(originalStart, deletionRanges: deletionRanges)
        let adjustedEnd = adjustedPositionAfterDeletions(originalEnd, deletionRanges: deletionRanges)
        return NSRange(location: adjustedStart, length: max(0, adjustedEnd - adjustedStart))
    }

    private func adjustedPositionAfterDeletions(
        _ position: Int,
        deletionRanges: [NSRange]
    ) -> Int {
        var deletedBeforePosition = 0

        for deletionRange in deletionRanges {
            let deletionEnd = deletionRange.location + deletionRange.length
            if position >= deletionEnd {
                deletedBeforePosition += deletionRange.length
                continue
            }

            if position > deletionRange.location {
                return max(0, deletionRange.location - deletedBeforePosition)
            }
        }

        return max(0, position - deletedBeforePosition)
    }

    func handleReturnKey(in range: NSRange) -> Bool {
        guard range.location != NSNotFound else {
            return true
        }

        let plain = text ?? ""
        let nsPlain = plain as NSString
        let lineRange = nsPlain.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = nsPlain
            .substring(with: lineRange)
            .trimmingCharacters(in: .newlines)

        guard lineText.hasPrefix(Self.bulletPrefix) else {
            return true
        }

        let attributes = currentTypingAttributes()
        let mutableText = NSMutableAttributedString(attributedString: attributedText)
        let contentAfterBullet = String(lineText.dropFirst(Self.bulletPrefix.count))

        if contentAfterBullet.trimmingCharacters(in: .whitespaces).isEmpty {
            mutableText.deleteCharacters(in: NSRange(location: lineRange.location, length: Self.bulletPrefix.count))

            var insertLocation = range.location
            if insertLocation >= lineRange.location + Self.bulletPrefix.count {
                insertLocation -= Self.bulletPrefix.count
            } else if insertLocation > lineRange.location {
                insertLocation = lineRange.location
            }

            mutableText.replaceCharacters(
                in: NSRange(location: insertLocation, length: 0),
                with: NSAttributedString(string: "\n", attributes: attributes)
            )
            attributedText = mutableText
            updateStoredRichTextDocument()
            selectedRange = NSRange(location: insertLocation + 1, length: 0)
        } else {
            let insertString = "\n" + Self.bulletPrefix
            mutableText.replaceCharacters(
                in: range,
                with: NSAttributedString(string: insertString, attributes: attributes)
            )
            attributedText = mutableText
            updateStoredRichTextDocument()
            selectedRange = NSRange(location: range.location + insertString.count, length: 0)
        }

        typingAttributes = attributes
        notifyTextDidChange()
        setNeedsDisplay()
        return false
    }

    private func notifyTextDidChange() {
        delegate?.textViewDidChange?(self)
    }

    func refreshStoredRichTextDocumentFromTextStorage() {
        updateStoredRichTextDocument()
    }

    private func updateStoredRichTextDocument() {
        storedRichTextDocument = NotebookRichTextDocument(
            attributedString: attributedText ?? NSAttributedString(string: text ?? "")
        )
    }

    private func toggleTypingFormatting(_ command: NotebookTextFormattingCommand) {
        switch command {
        case .bold:
            isTypingBold.toggle()
        case .italic:
            isTypingItalic.toggle()
        case .underline, .strikethrough, .bulletList, .indent, .outdent, .textColor, .resetTextColors, .textStyle:
            return
        }

        refreshTypingAttributes()
    }

    private func currentTypingAttributes() -> [NSAttributedString.Key: Any] {
        var adjustedStyle = notebookTextStyle
        adjustedStyle.bodyFontSize = notebookTextStyle.bodyFontSize * typingTextRunStyle.fontScale

        var attributes = NotebookMetrics.typingAttributes(
            for: adjustedStyle,
            usesTexturedPaperEffect: usesTexturedPaperEffect,
            isBold: isTypingBold,
            isItalic: isTypingItalic
        )

        if typingTextRunStyle != .body {
            attributes[.notebookTextStyle] = typingTextRunStyle.rawValue
            attributes[.font] = NotebookMetrics.uiBodyFont(
                for: adjustedStyle,
                isBold: isTypingBold || typingTextRunStyle.usesHeadingWeight,
                isItalic: isTypingItalic
            )

            if (isTypingBold || typingTextRunStyle.usesHeadingWeight),
               NotebookMetrics.shouldUseSyntheticBold(for: adjustedStyle) {
                attributes[.strokeWidth] = -2
            } else if !isTypingBold {
                attributes.removeValue(forKey: .strokeWidth)
            }
        }

        return attributes
    }

    private func refreshTypingAttributes() {
        typingAttributes = currentTypingAttributes()
    }

    func refreshTypingAttributesFromSelection() {
        guard let attributedText, attributedText.length > 0 else {
            typingTextRunStyle = .body
            isTypingBold = false
            isTypingItalic = false
            refreshTypingAttributes()
            return
        }

        let textLength = attributedText.length
        let clampedLocation = min(max(selectedRange.location, 0), textLength)
        let attributeLocation: Int

        if selectedRange.length > 0 {
            attributeLocation = min(clampedLocation, textLength - 1)
        } else if clampedLocation > 0,
                  (clampedLocation == textLength || isNewlineCharacter(at: clampedLocation, in: attributedText.string as NSString)) {
            attributeLocation = clampedLocation - 1
        } else if clampedLocation < textLength {
            attributeLocation = clampedLocation
        } else {
            attributeLocation = textLength - 1
        }

        let attributes = attributedText.attributes(at: attributeLocation, effectiveRange: nil)
        let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        typingTextRunStyle = (attributes[.notebookTextStyle] as? String)
            .flatMap(NotebookTextRunStyle.init(rawValue:)) ?? .body
        isTypingBold = (attributes[.notebookBold] as? Bool) ?? false
        isTypingItalic = (attributes[.notebookItalic] as? Bool) ?? traits.contains(.traitItalic)
        refreshTypingAttributes()
    }

    func currentSelectionState() -> NotebookTextSelectionState {
        let range = selectedRange
        let hasSelection = range.location != NSNotFound && range.length > 0
        guard hasSelection,
              let attributedText,
              attributedText.length > 0,
              NSIntersectionRange(range, NSRange(location: 0, length: attributedText.length)).length == range.length else {
            return NotebookTextSelectionState(
                hasSelection: false,
                isBold: isTypingBold,
                isItalic: isTypingItalic,
                textRunStyle: typingTextRunStyle
            )
        }

        return NotebookTextSelectionState(
            hasSelection: true,
            isBold: attributedText.selectionContainsNotebookStyle(.notebookBold, in: range),
            isItalic: attributedText.selectionContainsNotebookStyle(.notebookItalic, in: range),
            isUnderlined: attributedText.selectionContainsAttribute(.underlineStyle, in: range),
            isStrikethrough: attributedText.selectionContainsAttribute(.strikethroughStyle, in: range),
            textRunStyle: selectedTextRunStyle(in: range, attributedText: attributedText)
        )
    }

    private func selectedTextRunStyle(
        in range: NSRange,
        attributedText: NSAttributedString
    ) -> NotebookTextRunStyle {
        var selectedStyle: NotebookTextRunStyle?
        var isMixed = false

        attributedText.enumerateAttribute(.notebookTextStyle, in: range) { value, _, stop in
            let style = (value as? String).flatMap(NotebookTextRunStyle.init(rawValue:)) ?? .body
            if let selectedStyle, selectedStyle != style {
                isMixed = true
                stop.pointee = true
            } else {
                selectedStyle = style
            }
        }

        return isMixed ? .body : selectedStyle ?? .body
    }

    private func isNewlineCharacter(at location: Int, in plainText: NSString) -> Bool {
        guard location < plainText.length,
              let scalar = UnicodeScalar(Int(plainText.character(at: location))) else {
            return false
        }

        return CharacterSet.newlines.contains(scalar)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        if drawsRuledLines {
            drawRuledLines(in: rect)
        }
        super.draw(rect)
    }

    private func drawRuledLines(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }

        context.saveGState()
        context.translateBy(x: 0, y: -contentOffset.y)
        context.setStrokeColor(NotebookMetrics.ruleUIColor.cgColor)
        context.setLineWidth(1)

        let width = bounds.width
        var y = ruleSpacing
        let maxY = max(contentSize.height, bounds.height + contentOffset.y)

        while y <= maxY {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
            y += ruleSpacing
        }

        context.strokePath()
        context.restoreGState()
    }
}

struct LinedTextEditor: UIViewRepresentable {
    @Binding var text: String
    var richText: Binding<NotebookRichTextDocument?>? = nil
    var focusRequestID: Int = 0
    var blurRequestID: Int = 0
    var formattingRequest: NotebookTextFormattingRequest? = nil
    var followTextEndRequestID: Int = 0
    var isDictating: Bool = false
    var dictationTranscriptRequest: NotebookDictationTranscriptRequest? = nil
    var scrollsInternally: Bool = true
    var drawsRuledLines: Bool? = nil
    var minimumHeight: CGFloat = NotebookMetrics.minimumBodyHeight
    var tintUIColor: UIColor = .systemBlue
    var textStyle: NotebookTextStyle = .default
    var textLeadingInset = NotebookMetrics.textLeadingInset
    var showsKeyboardAccessory = false
    var keyboardInputMode: NotebookEditorInputMode = .systemKeyboard
    var keyboardAccessoryContent: AnyView? = nil
    var keyboardPanelContent: AnyView? = nil
    var usesTexturedPaperEffect = false
    var onSelectionStateChange: ((NotebookTextSelectionState) -> Void)? = nil
    var onEditingEnded: (() -> Void)? = nil
    var onEditingBegan: (() -> Void)? = nil

    private var shouldDrawRuledLines: Bool {
        drawsRuledLines ?? scrollsInternally
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> LinedTextView {
        let textView = LinedTextView()
        textView.scrollsInternally = scrollsInternally
        textView.drawsRuledLines = shouldDrawRuledLines
        textView.delegate = context.coordinator
        textView.tintColor = tintUIColor
        textView.notebookTextStyle = textStyle
        textView.textLeadingInset = textLeadingInset
        textView.showsKeyboardAccessory = showsKeyboardAccessory
        textView.keyboardInputMode = keyboardInputMode
        textView.usesTexturedPaperEffect = usesTexturedPaperEffect
        textView.onEditingEnded = onEditingEnded
        if let keyboardAccessoryContent {
            textView.setKeyboardAccessoryContent(keyboardAccessoryContent)
        }
        if let keyboardPanelContent {
            textView.setKeyboardPanelContent(keyboardPanelContent)
        }
        textView.setNotebookText(text, richText: richText?.wrappedValue)
        textView.attachAsActiveEditor()
        context.coordinator.currentRichTextDocument = textView.richTextDocument()
        context.coordinator.onSelectionStateChange = onSelectionStateChange
        context.coordinator.onEditingEnded = onEditingEnded
        context.coordinator.onEditingBegan = onEditingBegan
        context.coordinator.onTextChange = { newText in
            text = newText
        }
        context.coordinator.onRichTextChange = { newRichText in
            context.coordinator.currentRichTextDocument = newRichText
            context.coordinator.isWaitingForRichTextBindingSync = true
            richText?.wrappedValue = newRichText
        }
        return textView
    }

    func updateUIView(_ textView: LinedTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectionStateChange = onSelectionStateChange
        coordinator.onEditingEnded = onEditingEnded
        coordinator.onEditingBegan = onEditingBegan
        textView.onEditingEnded = onEditingEnded
        coordinator.onTextChange = { newText in
            text = newText
        }
        coordinator.onRichTextChange = { newRichText in
            coordinator.currentRichTextDocument = newRichText
            coordinator.isWaitingForRichTextBindingSync = true
            richText?.wrappedValue = newRichText
        }

        if richText?.wrappedValue?.normalized(for: text) == coordinator.currentRichTextDocument {
            coordinator.isWaitingForRichTextBindingSync = false
        }

        if textView.scrollsInternally != scrollsInternally {
            textView.scrollsInternally = scrollsInternally
        }

        if textView.drawsRuledLines != shouldDrawRuledLines {
            textView.drawsRuledLines = shouldDrawRuledLines
        }

        let didChangeTextStyle = textView.notebookTextStyle != textStyle
        if didChangeTextStyle {
            textView.notebookTextStyle = textStyle
        }

        if textView.textLeadingInset != textLeadingInset {
            textView.textLeadingInset = textLeadingInset
        }

        if let keyboardAccessoryContent {
            coordinator.pendingKeyboardAccessoryContent = keyboardAccessoryContent
            coordinator.scheduleKeyboardAccessoryRefresh(for: textView)
        }
        if let keyboardPanelContent {
            coordinator.pendingKeyboardPanelContent = keyboardPanelContent
            coordinator.scheduleKeyboardPanelRefresh(for: textView)
        }

        if textView.showsKeyboardAccessory != showsKeyboardAccessory {
            textView.showsKeyboardAccessory = showsKeyboardAccessory
        }

        if textView.keyboardInputMode != keyboardInputMode {
            textView.keyboardInputMode = keyboardInputMode
        }

        let didChangeTexturedPaperEffect = textView.usesTexturedPaperEffect != usesTexturedPaperEffect
        if didChangeTexturedPaperEffect {
            textView.usesTexturedPaperEffect = usesTexturedPaperEffect
        }

        // Only treat the binding as caught up when it matches the live text view
        // (or the last value we pushed). A stale intermediate binding must NOT clear
        // the waiting flag — that previously rewrote the text view mid-keystroke and
        // jumped the caret.
        if text == textView.text || text == coordinator.lastTextPushedToBinding {
            coordinator.isWaitingForTextBindingSync = false
            coordinator.isUpdatingFromTextView = false
            coordinator.lastTextPushedToBinding = textView.text
        }

        let shouldFollowTextEnd = followTextEndRequestID != coordinator.handledFollowTextEndRequestID

        // While the text view is first responder it owns the document. SwiftUI bindings
        // are outbound only during typing. Explicit follow-to-end requests are the
        // one inbound exception (e.g. programmatic inserts that should move the caret).
        let canApplyBindingText = !coordinator.isUpdatingFromTextView
            && (!textView.isFirstResponder || shouldFollowTextEnd)
            && !(textView.isFirstResponder && coordinator.isWaitingForTextBindingSync)

        if canApplyBindingText {
            if textView.text != text {
                // While dictating, the text view owns in-flight speech inserts at the caret.
                // Don't let a stale SwiftUI binding rewrite that work.
                if !isDictating {
                    textView.setNotebookText(
                        text,
                        richText: richText?.wrappedValue,
                        moveCaretToEnd: shouldFollowTextEnd
                    )
                    coordinator.currentRichTextDocument = textView.richTextDocument()
                    coordinator.lastTextPushedToBinding = text
                    coordinator.isWaitingForTextBindingSync = false
                }
            } else if !didChangeTextStyle,
                      !didChangeTexturedPaperEffect,
                      let richText = richText?.wrappedValue,
                      !textView.isFirstResponder,
                      !coordinator.isWaitingForRichTextBindingSync,
                      richText.normalized(for: text) != textView.richTextDocument() {
                textView.setNotebookText(text, richText: richText)
                coordinator.currentRichTextDocument = textView.richTextDocument()
            }
        }

        if didChangeTextStyle || didChangeTexturedPaperEffect {
            let refreshedRichText = textView.richTextDocument()
            coordinator.currentRichTextDocument = refreshedRichText
            coordinator.isWaitingForRichTextBindingSync = true
            DispatchQueue.main.async {
                richText?.wrappedValue = refreshedRichText
            }
        }

        var didHandleBlurRequest = false
        if blurRequestID != coordinator.handledBlurRequestID {
            coordinator.handledBlurRequestID = blurRequestID
            didHandleBlurRequest = true
            coordinator.isProgrammaticallyEndingEditing = true
            DispatchQueue.main.async {
                textView.resignFirstResponder()
                coordinator.isProgrammaticallyEndingEditing = false
            }
        }

        if focusRequestID != coordinator.handledFocusRequestID {
            coordinator.handledFocusRequestID = focusRequestID
            if !didHandleBlurRequest, !textView.isFirstResponder {
                textView.attachAsActiveEditor()
                if !textView.becomeFirstResponder() {
                    DispatchQueue.main.async {
                        guard !textView.isFirstResponder else {
                            return
                        }
                        textView.becomeFirstResponder()
                    }
                }
            }
        }

        if shouldFollowTextEnd, textView.text == text {
            coordinator.handledFollowTextEndRequestID = followTextEndRequestID
            textView.layoutIfNeeded()
            textView.moveCaretToEndAndReveal()
        }

        textView.setDictating(isDictating)

        if let dictationTranscriptRequest,
           dictationTranscriptRequest.id != coordinator.handledDictationTranscriptRequestID {
            coordinator.handledDictationTranscriptRequestID = dictationTranscriptRequest.id
            textView.applyDictationTranscript(dictationTranscriptRequest.transcript)
        }

        if let formattingRequest,
           formattingRequest.id != coordinator.handledFormattingRequestID {
            coordinator.handledFormattingRequestID = formattingRequest.id
            DispatchQueue.main.async {
                textView.applyFormattingCommand(formattingRequest.command)
                coordinator.onSelectionStateChange?(textView.currentSelectionState())
            }
        }
    }

    static func dismantleUIView(_ uiView: LinedTextView, coordinator: Coordinator) {
        uiView.setDictating(false)
        uiView.resignFirstResponder()
        uiView.releaseKeyboardChrome()
        uiView.detachIfActive()
        uiView.delegate = nil
        uiView.onEditingEnded = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LinedTextView, context: Context) -> CGSize? {
        guard !scrollsInternally else {
            return nil
        }

        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else {
            return nil
        }

        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(
            width: width,
            height: max(fitted.height, minimumHeight)
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var isUpdatingFromTextView = false
        var isProgrammaticallyEndingEditing = false
        var handledFocusRequestID = 0
        var handledBlurRequestID = 0
        var handledFormattingRequestID = 0
        var handledFollowTextEndRequestID = 0
        var handledDictationTranscriptRequestID = 0
        var currentRichTextDocument: NotebookRichTextDocument?
        var isWaitingForTextBindingSync = false
        var isWaitingForRichTextBindingSync = false
        /// Last value pushed from the text view into the SwiftUI binding.
        var lastTextPushedToBinding: String?
        var onTextChange: ((String) -> Void)?
        var onRichTextChange: ((NotebookRichTextDocument) -> Void)?
        var onSelectionStateChange: ((NotebookTextSelectionState) -> Void)?
        var onEditingEnded: (() -> Void)?
        var onEditingBegan: (() -> Void)?
        var pendingKeyboardAccessoryContent: AnyView?
        var pendingKeyboardPanelContent: AnyView?
        private var isKeyboardAccessoryRefreshScheduled = false
        private var isKeyboardPanelRefreshScheduled = false

        private func dispatchToSwiftUI(_ action: @escaping () -> Void) {
            DispatchQueue.main.async(execute: action)
        }

        func scheduleKeyboardAccessoryRefresh(for textView: LinedTextView) {
            guard !isKeyboardAccessoryRefreshScheduled else {
                return
            }

            isKeyboardAccessoryRefreshScheduled = true
            dispatchToSwiftUI { [weak self, weak textView] in
                guard let self, let textView else {
                    return
                }

                self.isKeyboardAccessoryRefreshScheduled = false
                if let pendingKeyboardAccessoryContent = self.pendingKeyboardAccessoryContent {
                    textView.setKeyboardAccessoryContent(pendingKeyboardAccessoryContent)
                }
            }
        }

        func scheduleKeyboardPanelRefresh(for textView: LinedTextView) {
            guard !isKeyboardPanelRefreshScheduled else {
                return
            }

            isKeyboardPanelRefreshScheduled = true
            dispatchToSwiftUI { [weak self, weak textView] in
                guard let self, let textView else {
                    return
                }

                self.isKeyboardPanelRefreshScheduled = false
                if let pendingKeyboardPanelContent = self.pendingKeyboardPanelContent {
                    textView.setKeyboardPanelContent(pendingKeyboardPanelContent)
                }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            if let linedTextView = textView as? LinedTextView {
                linedTextView.markDictationUserEdit()
            }

            isUpdatingFromTextView = true
            isWaitingForTextBindingSync = true
            lastTextPushedToBinding = textView.text
            onTextChange?(textView.text)
            if let linedTextView = textView as? LinedTextView {
                linedTextView.refreshStoredRichTextDocumentFromTextStorage()
                onRichTextChange?(linedTextView.richTextDocument())
            }

            if let linedTextView = textView as? LinedTextView {
                linedTextView.refreshLayoutAfterContentChange()
                let selectionState = linedTextView.currentSelectionState()
                dispatchToSwiftUI { [weak self] in
                    self?.onSelectionStateChange?(selectionState)
                }
            }

            // Fallback only: the waiting flags are normally cleared in updateUIView once
            // the SwiftUI binding catches up. Avoid clearing immediately, which opened a
            // race where a stale binding could rewrite the text view and jump the caret.
            dispatchToSwiftUI { [weak self] in
                guard let self else {
                    return
                }
                if !self.isWaitingForTextBindingSync {
                    self.isUpdatingFromTextView = false
                }
            }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n", let linedTextView = textView as? LinedTextView else {
                return true
            }

            return linedTextView.handleReturnKey(in: range)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            scrollView.setNeedsDisplay()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let linedTextView = textView as? LinedTextView else {
                return
            }

            linedTextView.markDictationSelectionChange()
            linedTextView.refreshTypingAttributesFromSelection()
            let selectionState = linedTextView.currentSelectionState()
            dispatchToSwiftUI { [weak self] in
                self?.onSelectionStateChange?(selectionState)
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            dispatchToSwiftUI { [weak self] in
                self?.onEditingBegan?()
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard !isProgrammaticallyEndingEditing else {
                return
            }

            dispatchToSwiftUI { [weak self] in
                self?.onEditingEnded?()
                (textView as? LinedTextView)?.onEditingEnded?()
            }
        }
    }
}

private extension String {
    var startsWithAttachedDictationPunctuation: Bool {
        guard let first else {
            return false
        }

        return [".", ",", "!", "?", ";", ":", ")", "]", "}", "%"].contains(first)
    }

    var strippingLeadingDictationWhitespace: String {
        String(drop(while: { $0.isWhitespace || $0.isNewline }))
    }

    var capitalizingFirstDictationLetter: String {
        guard let first, first.isLowercase else {
            return self
        }

        return first.uppercased() + dropFirst()
    }
}

private extension NSAttributedString {
    func selectionContainsNotebookStyle(_ key: NSAttributedString.Key, in range: NSRange) -> Bool {
        var containsStyle = true

        enumerateAttributes(in: range) { attributes, _, stop in
            let explicitValue = attributes[key] as? Bool
            let hasFallbackTrait: Bool
            if explicitValue == nil, let font = attributes[.font] as? UIFont {
                if key == .notebookItalic {
                    hasFallbackTrait = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
                } else {
                    hasFallbackTrait = false
                }
            } else {
                hasFallbackTrait = false
            }

            if explicitValue != true && !hasFallbackTrait {
                containsStyle = false
                stop.pointee = true
            }
        }

        return containsStyle
    }

    func selectionContainsAttribute(_ key: NSAttributedString.Key, in range: NSRange) -> Bool {
        var containsStyle = true

        enumerateAttribute(key, in: range) { value, _, stop in
            if value == nil {
                containsStyle = false
                stop.pointee = true
            }
        }

        return containsStyle
    }
}

private extension NSMutableAttributedString {
    func applyNotebookForegroundColor(_ hexString: String, in range: NSRange) {
        guard let color = UIColor(journaltopiaHexString: hexString) else {
            return
        }

        addAttribute(.foregroundColor, value: color, range: range)
        addAttribute(.notebookForegroundColorHex, value: hexString, range: range)
    }

    func setNotebookTextRunStyle(
        _ runStyle: NotebookTextRunStyle,
        textStyle: NotebookTextStyle,
        in range: NSRange
    ) {
        enumerateAttributes(in: range) { attributes, subrange, _ in
            let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let isBold = (attributes[.notebookBold] as? Bool) ?? false
            let isItalic = (attributes[.notebookItalic] as? Bool) ?? traits.contains(.traitItalic)
            let font = notebookFont(
                textStyle: textStyle,
                runStyle: runStyle,
                isBold: isBold,
                isItalic: isItalic
            )

            addAttribute(.font, value: font, range: subrange)

            if runStyle == .body {
                removeAttribute(.notebookTextStyle, range: subrange)
            } else {
                addAttribute(.notebookTextStyle, value: runStyle.rawValue, range: subrange)
            }

            applySyntheticBoldIfNeeded(
                isBold: isBold || runStyle.usesHeadingWeight,
                textStyle: textStyle,
                range: subrange
            )
            applySyntheticItalicIfNeeded(
                isItalic: isItalic,
                textStyle: textStyle,
                range: subrange
            )
        }
    }

    func setNotebookFontStyle(
        isBold: Bool?,
        isItalic: Bool?,
        textStyle: NotebookTextStyle,
        in range: NSRange
    ) {
        enumerateAttributes(in: range) { attributes, subrange, _ in
            let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let resolvedBold = isBold ?? ((attributes[.notebookBold] as? Bool) ?? false)
            let resolvedItalic = isItalic ?? ((attributes[.notebookItalic] as? Bool) ?? traits.contains(.traitItalic))
            let runStyle = (attributes[.notebookTextStyle] as? String)
                .flatMap(NotebookTextRunStyle.init(rawValue:)) ?? .body
            let font = notebookFont(
                textStyle: textStyle,
                runStyle: runStyle,
                isBold: resolvedBold,
                isItalic: resolvedItalic
            )

            addAttribute(.font, value: font, range: subrange)
            setBooleanAttribute(.notebookBold, isEnabled: resolvedBold, range: subrange)
            setBooleanAttribute(.notebookItalic, isEnabled: resolvedItalic, range: subrange)
            applySyntheticBoldIfNeeded(
                isBold: resolvedBold || runStyle.usesHeadingWeight,
                textStyle: textStyle,
                range: subrange
            )
            applySyntheticItalicIfNeeded(
                isItalic: resolvedItalic,
                textStyle: textStyle,
                range: subrange
            )
        }
    }

    private func notebookFont(
        textStyle: NotebookTextStyle,
        runStyle: NotebookTextRunStyle,
        isBold: Bool,
        isItalic: Bool
    ) -> UIFont {
        var adjustedStyle = textStyle
        adjustedStyle.bodyFontSize = textStyle.bodyFontSize * runStyle.fontScale

        return NotebookMetrics.uiBodyFont(
            for: adjustedStyle,
            isBold: isBold || runStyle.usesHeadingWeight,
            isItalic: isItalic
        )
    }

    func toggleIntegerStyle(_ key: NSAttributedString.Key, in range: NSRange) {
        if containsAttribute(key, in: range) {
            removeAttribute(key, range: range)
        } else {
            addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range)
        }
    }

    func containsNotebookStyle(_ key: NSAttributedString.Key, in range: NSRange) -> Bool {
        var containsStyle = true

        enumerateAttributes(in: range) { attributes, _, stop in
            let explicitValue = attributes[key] as? Bool
            let hasFallbackTrait: Bool
            if explicitValue == nil, let font = attributes[.font] as? UIFont {
                if key == .notebookItalic {
                    hasFallbackTrait = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
                } else {
                    hasFallbackTrait = false
                }
            } else {
                hasFallbackTrait = false
            }

            if explicitValue != true && !hasFallbackTrait {
                containsStyle = false
                stop.pointee = true
            }
        }

        return containsStyle
    }

    private func containsAttribute(_ key: NSAttributedString.Key, in range: NSRange) -> Bool {
        var containsStyle = true

        enumerateAttribute(key, in: range) { value, _, stop in
            if value == nil {
                containsStyle = false
                stop.pointee = true
            }
        }

        return containsStyle
    }

    private func setBooleanAttribute(
        _ key: NSAttributedString.Key,
        isEnabled: Bool,
        range: NSRange
    ) {
        if isEnabled {
            addAttribute(key, value: true, range: range)
        } else {
            removeAttribute(key, range: range)
        }
    }

    private func applySyntheticBoldIfNeeded(
        isBold: Bool,
        textStyle: NotebookTextStyle,
        range: NSRange
    ) {
        guard isBold, NotebookMetrics.shouldUseSyntheticBold(for: textStyle) else {
            removeAttribute(.strokeWidth, range: range)
            return
        }

        addAttribute(.strokeWidth, value: -2, range: range)
    }

    private func applySyntheticItalicIfNeeded(
        isItalic: Bool,
        textStyle: NotebookTextStyle,
        range: NSRange
    ) {
        guard isItalic, NotebookMetrics.shouldUseSyntheticItalic(for: textStyle) else {
            removeAttribute(.obliqueness, range: range)
            return
        }

        addAttribute(.obliqueness, value: NotebookMetrics.syntheticItalicObliqueness, range: range)
    }
}

private extension UIColor {
    convenience init?(journaltopiaHexString: String) {
        var hex = journaltopiaHexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        guard hex.count == 6,
              let value = Int(hex, radix: 16) else {
            return nil
        }

        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

private final class TexturedPaperBodyTextView: UIView {
    var text = "" {
        didSet {
            updateTextStorage()
        }
    }
    var richText: NotebookRichTextDocument? {
        didSet {
            updateTextStorage()
        }
    }
    var textStyle: NotebookTextStyle = .default {
        didSet {
            updateTextStorage()
        }
    }
    var textLeadingInset = NotebookMetrics.textLeadingInset {
        didSet {
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureTextSystem()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTextSystem()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textContainer.size = CGSize(
            width: max(0, bounds.width - textLeadingInset),
            height: .greatestFiniteMagnitude
        )
    }

    override func draw(_ rect: CGRect) {
        guard !text.isEmpty, let context = UIGraphicsGetCurrentContext() else {
            return
        }

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        guard glyphRange.length > 0 else {
            return
        }

        let inkColor = textStyle.uiColor.withAlphaComponent(0.9)
        let darkEdge = TexturedPaperTextEffect.bodyShadowColor(for: textStyle.uiColor)
        let lightEdge = TexturedPaperTextEffect.bodyHighlightColor(for: textStyle.uiColor)

        context.saveGState()
        drawGlyphs(glyphRange, color: darkEdge, offset: CGSize(width: -0.7, height: -0.2))
        drawGlyphs(glyphRange, color: darkEdge, offset: CGSize(width: 0, height: -1.1))
        drawGlyphs(glyphRange, color: lightEdge, offset: CGSize(width: 0.8, height: 0.25))
        drawGlyphs(glyphRange, color: lightEdge, offset: CGSize(width: 0, height: 1.15))
        drawGlyphs(glyphRange, color: inkColor, offset: .zero, honorsRunForegroundColors: true)
        context.restoreGState()
    }

    private func configureTextSystem() {
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    private func updateTextStorage() {
        let attributedText = richText?
            .normalized(for: text)
            .attributedString(textStyle: textStyle)
            ?? NSAttributedString(
                string: text,
                attributes: NotebookMetrics.typingAttributes(for: textStyle)
            )
        textStorage.setAttributedString(attributedText)
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func drawGlyphs(
        _ glyphRange: NSRange,
        color: UIColor,
        offset: CGSize,
        honorsRunForegroundColors: Bool = false
    ) {
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )

        guard honorsRunForegroundColors else {
            textStorage.addAttribute(.foregroundColor, value: color, range: characterRange)
            layoutManager.drawGlyphs(
                forGlyphRange: glyphRange,
                at: CGPoint(
                    x: textLeadingInset + offset.width,
                    y: offset.height
                )
            )
            return
        }

        textStorage.enumerateAttribute(.notebookForegroundColorHex, in: characterRange) { value, subrange, _ in
            let runColor = (value as? String)
                .flatMap { UIColor(journaltopiaHexString: $0) }?
                .withAlphaComponent(color.cgColor.alpha)
                ?? color
            let runGlyphRange = layoutManager.glyphRange(
                forCharacterRange: subrange,
                actualCharacterRange: nil
            )

            guard runGlyphRange.length > 0 else {
                return
            }

            textStorage.addAttribute(.foregroundColor, value: runColor, range: subrange)
            layoutManager.drawGlyphs(
                forGlyphRange: runGlyphRange,
                at: CGPoint(
                    x: textLeadingInset + offset.width,
                    y: offset.height
                )
            )
        }
    }
}

private struct TexturedPaperBodyTextOverlay: UIViewRepresentable {
    let text: String
    let richText: NotebookRichTextDocument?
    let textStyle: NotebookTextStyle
    let textLeadingInset: CGFloat

    func makeUIView(context: Context) -> TexturedPaperBodyTextView {
        let view = TexturedPaperBodyTextView()
        view.text = text
        view.richText = richText
        view.textStyle = textStyle
        view.textLeadingInset = textLeadingInset
        return view
    }

    func updateUIView(_ view: TexturedPaperBodyTextView, context: Context) {
        if view.text != text {
            view.text = text
        }

        if view.richText != richText {
            view.richText = richText
        }

        if view.textStyle != textStyle {
            view.textStyle = textStyle
        }

        if view.textLeadingInset != textLeadingInset {
            view.textLeadingInset = textLeadingInset
        }
    }
}

private final class NotebookTitleFieldView: UITextField {
    private let toolbarHost = NotebookAnyViewInputHost(fixedHeight: NotebookAnyViewInputHost.toolbarHeight)
    private let panelHost = NotebookAnyViewInputHost(fixedHeight: nil)
    private lazy var panelInputView = NotebookInputPanelView(contentHost: panelHost)

    var showsKeyboardAccessory = false {
        didSet {
            guard oldValue != showsKeyboardAccessory else {
                return
            }

            applyInputViews(reloadIfNeeded: true)
        }
    }

    var keyboardInputMode: NotebookEditorInputMode = .systemKeyboard {
        didSet {
            guard oldValue != keyboardInputMode else {
                return
            }

            applyInputViews(reloadIfNeeded: true)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        borderStyle = .none
        backgroundColor = .clear
        returnKeyType = .next
        autocorrectionType = .yes
        autocapitalizationType = .sentences
        spellCheckingType = .yes
        clearButtonMode = .never
        applyInputViews(reloadIfNeeded: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setKeyboardAccessoryContent(_ view: AnyView) {
        toolbarHost.setRootView(view)
    }

    func setKeyboardPanelContent(_ view: AnyView) {
        panelHost.setRootView(view)
    }

    func releaseKeyboardChrome() {
        let wasFirstResponder = isFirstResponder
        inputAccessoryView = nil
        inputView = nil
        if wasFirstResponder {
            reloadInputViews()
        }
    }

    private func applyInputViews(reloadIfNeeded: Bool) {
        inputAccessoryView = showsKeyboardAccessory ? toolbarHost : nil

        switch keyboardInputMode {
        case .systemKeyboard:
            inputView = nil
        case .formattingPanel:
            inputView = panelInputView
        }

        toolbarHost.invalidateIntrinsicContentSize()
        if reloadIfNeeded, isFirstResponder {
            reloadInputViews()
        }
    }
}

private struct NotebookTitleTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var textStyle: NotebookTextStyle
    var placeholderUIColor = UIColor(red: 0.39, green: 0.39, blue: 0.46, alpha: 0.46)
    var showsKeyboardAccessory: Bool
    var keyboardAccessoryContent: AnyView?
    var keyboardInputMode: NotebookEditorInputMode = .systemKeyboard
    var keyboardPanelContent: AnyView?
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> NotebookTitleFieldView {
        let field = NotebookTitleFieldView()
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyStyle(to: field)
        field.text = text
        if let keyboardAccessoryContent {
            field.setKeyboardAccessoryContent(keyboardAccessoryContent)
        }
        if let keyboardPanelContent {
            field.setKeyboardPanelContent(keyboardPanelContent)
        }
        field.showsKeyboardAccessory = showsKeyboardAccessory
        field.keyboardInputMode = keyboardInputMode
        bindCallbacks(to: context.coordinator)
        context.coordinator.lastRequestedFocus = isFocused
        return field
    }

    func updateUIView(_ field: NotebookTitleFieldView, context: Context) {
        let coordinator = context.coordinator
        bindCallbacks(to: coordinator)

        if field.text != text {
            field.text = text
        }

        applyStyle(to: field)

        if let keyboardAccessoryContent {
            field.setKeyboardAccessoryContent(keyboardAccessoryContent)
        }

        if let keyboardPanelContent {
            field.setKeyboardPanelContent(keyboardPanelContent)
        }

        if field.showsKeyboardAccessory != showsKeyboardAccessory {
            field.showsKeyboardAccessory = showsKeyboardAccessory
        }

        if field.keyboardInputMode != keyboardInputMode {
            field.keyboardInputMode = keyboardInputMode
        }

        // Focus is only pushed into UIKit on a change of the binding. Comparing against the
        // responder state instead would fight the field's own tap-to-focus handling.
        guard coordinator.lastRequestedFocus != isFocused else {
            return
        }

        coordinator.lastRequestedFocus = isFocused

        if isFocused {
            if !field.isFirstResponder {
                field.becomeFirstResponder()
            }
        } else if field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    private func bindCallbacks(to coordinator: Coordinator) {
        coordinator.onTextChange = { text = $0 }
        coordinator.onSubmit = onSubmit
        coordinator.onFocusChange = { isEditing in
            coordinator.lastRequestedFocus = isEditing
            if isFocused != isEditing {
                isFocused = isEditing
            }
        }
    }

    static func dismantleUIView(_ uiView: NotebookTitleFieldView, coordinator: Coordinator) {
        uiView.releaseKeyboardChrome()
        uiView.delegate = nil
    }

    private func applyStyle(to field: NotebookTitleFieldView) {
        let font = NotebookMetrics.uiFont(for: textStyle, size: textStyle.titleFontSize, isBold: true, isItalic: false)
        if field.font != font {
            field.font = font
        }
        if field.textColor != textStyle.uiColor {
            field.textColor = textStyle.uiColor
        }
        field.tintColor = textStyle.uiColor
        field.attributedPlaceholder = NSAttributedString(
            string: "Add a title",
            attributes: [
                .font: font,
                .foregroundColor: placeholderUIColor
            ]
        )
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onTextChange: ((String) -> Void)?
        var onSubmit: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var lastRequestedFocus = false

        func textFieldDidBeginEditing(_ textField: UITextField) {
            onFocusChange?(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            onFocusChange?(false)
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            onTextChange?(textField.text ?? "")
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit?()
            return false
        }
    }
}

struct NotebookEditorContent: View {
    @Binding var storyTitle: String
    @Binding var entryText: String
    var entryRichText: Binding<NotebookRichTextDocument?>? = nil
    @Binding var isTitleFocused: Bool
    var editorFocusRequestID: Int
    var editorBlurRequestID: Int = 0
    var formattingRequest: NotebookTextFormattingRequest? = nil
    var followTextEndRequestID: Int = 0
    var isDictating: Bool = false
    var dictationTranscriptRequest: NotebookDictationTranscriptRequest? = nil
    var bodyPlaceholder: String
    var scrollsInternally: Bool = true
    var pageHeight: CGFloat?
    var textStyle: NotebookTextStyle = .default
    var placeholderColor = Color.storyGray.opacity(0.46)
    var showsTitleRule = true
    var leadingContentPadding = NotebookMetrics.marginLeading
    var leadingTextPadding = NotebookMetrics.textLeadingInset
    var showsKeyboardAccessory = false
    var keyboardInputMode: NotebookEditorInputMode = .systemKeyboard
    var keyboardAccessoryContent: AnyView? = nil
    var keyboardPanelContent: AnyView? = nil
    var titleKeyboardAccessoryContent: AnyView? = nil
    var titleKeyboardInputMode: NotebookEditorInputMode = .systemKeyboard
    var titleKeyboardPanelContent: AnyView? = nil
    var usesTexturedPaperEffect = false
    var onBodyTap: (() -> Void)? = nil
    var onSelectionStateChange: ((NotebookTextSelectionState) -> Void)? = nil
    var onEditingEnded: (() -> Void)? = nil
    var onEditingBegan: (() -> Void)? = nil
    var onTitleSubmit: () -> Void

    private var bodyMinHeight: CGFloat {
        guard let pageHeight else {
            return NotebookMetrics.minimumBodyHeight
        }

        return NotebookMetrics.bodyAreaMinHeight(forPageHeight: pageHeight, titleBodySpacing: titleBodySpacing)
    }

    private var titleBodySpacing: CGFloat {
        textStyle.bodyLineHeight == nil ? NotebookMetrics.titleBodySpacing : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow

            bodyEditor
                .padding(.top, titleBodySpacing)
        }
        .padding(.leading, leadingContentPadding)
        .padding(.trailing, 18)
        .padding(.top, NotebookMetrics.contentTopPadding)
        .padding(.bottom, NotebookMetrics.contentBottomPadding)
    }

    private var titleRow: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                if showsTitleRule {
                    Rectangle()
                        .fill(NotebookMetrics.ruleColor)
                        .frame(height: 1)
                        .padding(.leading, -leadingContentPadding)
                        .padding(.trailing, -18)
                }
            }

            NotebookTitleTextField(
                text: $storyTitle,
                isFocused: $isTitleFocused,
                textStyle: textStyle,
                placeholderUIColor: UIColor(placeholderColor),
                showsKeyboardAccessory: titleKeyboardAccessoryContent != nil,
                keyboardAccessoryContent: titleKeyboardAccessoryContent,
                keyboardInputMode: titleKeyboardInputMode,
                keyboardPanelContent: titleKeyboardPanelContent,
                onSubmit: onTitleSubmit
            )
            .shadow(
                color: usesTexturedPaperEffect ? TexturedPaperTextEffect.titleShadowColor(for: textStyle.uiColor) : .clear,
                radius: usesTexturedPaperEffect ? 0.45 : 0,
                x: 0,
                y: usesTexturedPaperEffect ? -0.45 : 0
            )
            .blendMode(
                usesTexturedPaperEffect && TexturedPaperTextEffect.shouldMultiplyBlend(textStyle.uiColor)
                    ? .multiply
                    : .normal
            )
            .padding(.leading, leadingTextPadding)
            .padding(.top, NotebookMetrics.titleLineTextTopInset)
            .contentShape(Rectangle())
            // Claims the tap so an enclosing page tap can't treat it as a dismiss.
            .onTapGesture {
                isTitleFocused = true
            }
        }
        .frame(height: NotebookMetrics.ruleSpacing)
    }

    @ViewBuilder
    private var bodyEditor: some View {
        let editor = ZStack(alignment: .topLeading) {
            LinedTextEditor(
                text: $entryText,
                richText: entryRichText,
                focusRequestID: editorFocusRequestID,
                blurRequestID: editorBlurRequestID,
                formattingRequest: formattingRequest,
                followTextEndRequestID: followTextEndRequestID,
                isDictating: isDictating,
                dictationTranscriptRequest: dictationTranscriptRequest,
                scrollsInternally: scrollsInternally,
                drawsRuledLines: false,
                minimumHeight: bodyMinHeight,
                textStyle: textStyle,
                textLeadingInset: leadingTextPadding,
                showsKeyboardAccessory: showsKeyboardAccessory,
                keyboardInputMode: keyboardInputMode,
                keyboardAccessoryContent: keyboardAccessoryContent,
                keyboardPanelContent: keyboardPanelContent,
                usesTexturedPaperEffect: usesTexturedPaperEffect,
                onSelectionStateChange: onSelectionStateChange,
                onEditingEnded: onEditingEnded,
                onEditingBegan: onEditingBegan
            )
            .overlay(alignment: .topLeading) {
                if usesTexturedPaperEffect && !entryText.isEmpty {
                    TexturedPaperBodyTextOverlay(
                        text: entryText,
                        richText: entryRichText?.wrappedValue,
                        textStyle: textStyle,
                        textLeadingInset: leadingTextPadding
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                }
            }
            .padding(.bottom, 28)

            if entryText.isEmpty {
                Text(bodyPlaceholder)
                    .font(NotebookMetrics.bodyPlaceholderFont(for: textStyle))
                    .foregroundStyle(placeholderColor)
                    .padding(.leading, leadingTextPadding)
                    .padding(.top, NotebookMetrics.firstLineTextTopInset(for: textStyle))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)

        if scrollsInternally {
            editor.frame(maxHeight: .infinity)
        } else if let onBodyTap {
            editor
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        onBodyTap()
                    }
                )
        } else {
            editor
        }
    }
}

struct NotebookPageChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(
                HStack {
                    Rectangle()
                        .fill(Color.storyBorder.opacity(0.72))
                        .frame(width: 1)

                    Spacer()

                    Rectangle()
                        .fill(Color.storyBorder.opacity(0.72))
                        .frame(width: 1)
                }
            )
    }
}

extension View {
    func notebookPageChrome() -> some View {
        modifier(NotebookPageChrome())
    }
}
