import AppKit
import SwiftUI

enum TokenEditorMode: Equatable {
    case shortcut
    case trailing
}

struct TokenIssue: Equatable {
    let token: String
    let range: Range<String.Index>?
    let message: String
}

enum TokenCodecError: Error, Equatable {
    case invalid([TokenIssue])
}

enum TokenStoredValue: Equatable {
    case shortcut(ShortcutDefinition)
    case trailing(TrailingKey?)
}

enum CompletionMove: Equatable {
    case up
    case down
}

struct TokenEditorDraft: Equatable {
    private(set) var text: String
    private(set) var issues: [TokenIssue] = []
    private(set) var completions: [String] = []
    private(set) var selectedCompletion = 0
    private(set) var value: TokenStoredValue
    private let baselineText: String
    let mode: TokenEditorMode

    var isDirty: Bool { text != baselineText }

    init(value: TokenStoredValue, mode: TokenEditorMode) {
        self.value = value
        self.mode = mode
        text = TokenShortcutCodec.format(value)
        baselineText = text
    }

    mutating func updateText(_ source: String) {
        text = source
        issues = []
        let fragment = source
            .split(separator: "+", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? ""
        completions = fragment.trimmingCharacters(in: .whitespaces).hasPrefix("{")
            ? TokenShortcutCodec.completions(for: fragment, mode: mode)
            : []
        selectedCompletion = 0
    }

    @discardableResult
    mutating func commit() -> Bool {
        let result = TokenShortcutCodec.validate(text, mode: mode)
        issues = result.issues
        guard let parsed = result.value,
              let canonical = result.canonicalText else {
            return false
        }
        value = parsed
        text = canonical
        completions = []
        selectedCompletion = 0
        return true
    }

    mutating func moveCompletion(_ move: CompletionMove) {
        guard !completions.isEmpty else { return }
        let delta = move == .down ? 1 : -1
        selectedCompletion = (
            selectedCompletion + delta + completions.count
        ) % completions.count
    }

    mutating func acceptCompletion() {
        guard completions.indices.contains(selectedCompletion) else { return }
        let prefix = text
            .split(separator: "+", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        text = (prefix + [completions[selectedCompletion]]).joined(separator: "+")
        completions = []
        selectedCompletion = 0
    }

    mutating func acceptCompletion(at index: Int) {
        guard completions.indices.contains(index) else { return }
        selectedCompletion = index
        acceptCompletion()
    }

    mutating func selectToken(_ token: String) {
        updateText(token)
        _ = commit()
    }

    mutating func applyRecorded(_ shortcut: ShortcutDefinition) {
        value = mode == .shortcut
            ? .shortcut(shortcut)
            : .trailing(TokenShortcutCodec.trailingValue(shortcut))
        text = TokenShortcutCodec.format(value)
        issues = []
        completions = []
        selectedCompletion = 0
    }

    mutating func clear() {
        value = mode == .shortcut
            ? .shortcut(.init(key: .empty, modifiers: []))
            : .trailing(nil)
        text = ""
        issues = []
        completions = []
        selectedCompletion = 0
    }
}

struct TokenValidation: Equatable {
    let source: String
    let canonicalText: String?
    let value: TokenStoredValue?
    let issues: [TokenIssue]
}

enum TokenShortcutCodec {
    private static let modifierAliases: [String: ModifierSet] = [
        "{KC_CTRL}": .control,
        "{KC_LCTL}": .control,
        "{KC_RCTL}": .control,
        "{KC_OPT}": .option,
        "{KC_LALT}": .option,
        "{KC_RALT}": .option,
        "{KC_SHIFT}": .shift,
        "{KC_LSFT}": .shift,
        "{KC_RSFT}": .shift,
        "{KC_CMD}": .command,
        "{KC_LCMD}": .command,
        "{KC_RCMD}": .command,
    ]

    private static let canonicalModifierTokens = [
        "{KC_CTRL}", "{KC_OPT}", "{KC_SHIFT}", "{KC_CMD}",
    ]

    static func validate(_ source: String, mode: TokenEditorMode) -> TokenValidation {
        if source.trimmingCharacters(in: .whitespaces).isEmpty {
            let value: TokenStoredValue = mode == .shortcut
                ? .shortcut(.init(key: .empty, modifiers: []))
                : .trailing(nil)
            return .init(
                source: source,
                canonicalText: "",
                value: value,
                issues: []
            )
        }

        let entries = MacKeyCodePolicy.tokenEntries(mode: mode)
        let pieces = source.split(separator: "+", omittingEmptySubsequences: false)
        var modifiers: ModifierSet = []
        var base: ShortcutKey?
        var baseToken: String?
        var baseRange: Range<String.Index>?
        var issues: [TokenIssue] = []

        for piece in pieces {
            let raw = String(piece)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let range = piece.startIndex..<piece.endIndex

            if let modifier = modifierAliases[trimmed.uppercased()] {
                modifiers.insert(modifier)
            } else if let entry = entries.first(where: { $0.matches(trimmed) }) {
                if base != nil {
                    issues.append(.init(
                        token: trimmed,
                        range: range,
                        message: "기준 키는 하나만 입력하세요"
                    ))
                } else {
                    base = entry.key
                    baseToken = entry.canonical
                    baseRange = range
                }
            } else {
                issues.append(.init(
                    token: trimmed,
                    range: range,
                    message: "지원하는 {KC_...} 토큰으로 수정하세요"
                ))
            }
        }

        if base == nil {
            issues.append(.init(
                token: source,
                range: nil,
                message: "기준 키를 입력하세요"
            ))
        }
        if mode == .shortcut, let base {
            if !isFunction(base, in: 13...20), modifiers.isEmpty {
                issues.append(.init(
                    token: baseToken ?? source,
                    range: baseRange,
                    message: "일반 키에는 보조 키를 하나 이상 추가하세요"
                ))
            }
        }

        guard issues.isEmpty, let base, let baseToken else {
            return .init(
                source: source,
                canonicalText: nil,
                value: nil,
                issues: issues
            )
        }

        let modifierText = canonicalModifiers(modifiers).joined(separator: "+")
        let canonical = [modifierText, baseToken]
            .filter { !$0.isEmpty }
            .joined(separator: "+")
        let value: TokenStoredValue
        if mode == .shortcut {
            value = .shortcut(.init(key: base, modifiers: modifiers))
        } else {
            value = .trailing(trailingValue(base: base, modifiers: modifiers))
        }
        return .init(
            source: source,
            canonicalText: canonical,
            value: value,
            issues: []
        )
    }

    static func parse(_ source: String, mode: TokenEditorMode) throws -> TokenValidation {
        let result = validate(source, mode: mode)
        guard result.issues.isEmpty else {
            throw TokenCodecError.invalid(result.issues)
        }
        return result
    }

    static func format(_ value: TokenStoredValue) -> String {
        switch value {
        case .shortcut(let shortcut):
            return canonicalText(key: shortcut.key, modifiers: shortcut.modifiers)
        case .trailing(nil):
            return ""
        case .trailing(.enter?):
            return "{KC_ENTER}"
        case .trailing(.space?):
            return "{KC_SPACE}"
        case .trailing(.tab?):
            return "{KC_TAB}"
        case .trailing(.custom(let keyCode?, let modifiers)?):
            let key = MacKeyCodePolicy.functionNumber(for: keyCode)
                .map(ShortcutKey.function) ?? .keyCode(keyCode)
            return canonicalText(key: key, modifiers: modifiers)
        case .trailing(.customFunction(let number)?):
            return canonicalText(key: .function(number), modifiers: [])
        case .trailing(.custom(keyCode: nil, modifiers: _)?):
            return ""
        }
    }

    static func completions(for fragment: String, mode: TokenEditorMode) -> [String] {
        let needle = fragment
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        return (canonicalModifierTokens
            + MacKeyCodePolicy.tokenEntries(mode: mode).map(\.canonical))
            .filter { $0.hasPrefix(needle) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func trailingValue(_ shortcut: ShortcutDefinition) -> TrailingKey? {
        trailingValue(base: shortcut.key, modifiers: shortcut.modifiers)
    }

    private static func canonicalModifiers(_ modifiers: ModifierSet) -> [String] {
        var tokens: [String] = []
        if modifiers.contains(.control) { tokens.append("{KC_CTRL}") }
        if modifiers.contains(.option) { tokens.append("{KC_OPT}") }
        if modifiers.contains(.shift) { tokens.append("{KC_SHIFT}") }
        if modifiers.contains(.command) { tokens.append("{KC_CMD}") }
        return tokens
    }

    private static func canonicalText(
        key: ShortcutKey,
        modifiers: ModifierSet
    ) -> String {
        let baseToken: String?
        switch key {
        case .empty:
            baseToken = nil
        case .letter(let letter):
            baseToken = MacKeyCodePolicy.keyCode(forLetter: letter)
                .flatMap { token(for: .keyCode($0), mode: .shortcut) }
        case .keyCode:
            baseToken = token(for: key, mode: .trailing)
                ?? token(for: key, mode: .shortcut)
        case .function(let number):
            baseToken = "{KC_F\(number)}"
        }
        return (canonicalModifiers(modifiers) + [baseToken].compactMap { $0 })
            .joined(separator: "+")
    }

    private static func token(for key: ShortcutKey, mode: TokenEditorMode) -> String? {
        MacKeyCodePolicy.tokenEntries(mode: mode)
            .first(where: { $0.key == key })?
            .canonical
    }

    private static func isFunction(
        _ key: ShortcutKey,
        in range: ClosedRange<Int>
    ) -> Bool {
        guard case .function(let number) = key else { return false }
        return range.contains(number)
    }

    private static func trailingValue(
        base: ShortcutKey,
        modifiers: ModifierSet
    ) -> TrailingKey? {
        let keyCode: UInt16?
        switch base {
        case .empty:
            return nil
        case .letter(let letter):
            keyCode = MacKeyCodePolicy.keyCode(forLetter: letter)
        case .keyCode(let value):
            keyCode = value
        case .function(let number):
            keyCode = MacKeyCodePolicy.keyCode(forFunction: number)
        }
        guard let keyCode else { return nil }
        if modifiers.isEmpty {
            switch keyCode {
            case 36: return .enter
            case 49: return .space
            case 48: return .tab
            default: break
            }
        }
        return .custom(keyCode: keyCode, modifiers: modifiers)
    }
}

protocol AccessibilityNotificationPosting {
    func postValueChanged(for element: NSView)
}

struct SystemAccessibilityNotificationPoster: AccessibilityNotificationPosting {
    func postValueChanged(for element: NSView) {
        NSAccessibility.post(element: element, notification: .valueChanged)
    }
}

enum KeyRecorderMode: CaseIterable {
    case shortcut
    case trailing
}

enum KeyRecorderDecision: Equatable {
    case keepValue
    case clear
    case resignFocus
    case record(ShortcutDefinition)
}

enum KeyRecorderTranslator {
    static func decision(
        keyCode: UInt16,
        modifiers: ModifierSet,
        isRepeat: Bool,
        mode: KeyRecorderMode
    ) -> KeyRecorderDecision {
        if isRepeat { return .keepValue }

        if mode == .shortcut {
            if keyCode == 53 { return .resignFocus }
            if keyCode == 51 || keyCode == 117 { return .clear }
        }

        let value: ShortcutDefinition?
        switch mode {
        case .shortcut:
            value = shortcut(keyCode: keyCode, modifiers: modifiers)
        case .trailing:
            value = trailingShortcut(keyCode: keyCode, modifiers: modifiers)
        }
        return value.map(KeyRecorderDecision.record) ?? .keepValue
    }

    static func shortcut(
        keyCode: UInt16,
        modifiers eventModifiers: NSEvent.ModifierFlags
    ) -> ShortcutDefinition? {
        shortcut(keyCode: keyCode, modifiers: ModifierSet(eventModifiers))
    }

    private static func shortcut(
        keyCode: UInt16,
        modifiers: ModifierSet
    ) -> ShortcutDefinition? {
        if let number = MacKeyCodePolicy.functionNumber(for: keyCode) {
            if number <= 12, modifiers.isEmpty { return nil }
            return ShortcutDefinition(key: .function(number), modifiers: modifiers)
        }
        guard MacKeyCodePolicy.isAllowedShortcutKeyCode(keyCode),
              !modifiers.isEmpty else { return nil }
        return ShortcutDefinition(key: .keyCode(keyCode), modifiers: modifiers)
    }

    static func trailingKey(
        keyCode: UInt16,
        modifiers eventModifiers: NSEvent.ModifierFlags
    ) -> TrailingKey? {
        trailingKey(keyCode: keyCode, modifiers: ModifierSet(eventModifiers))
    }

    private static func trailingKey(
        keyCode: UInt16,
        modifiers: ModifierSet
    ) -> TrailingKey? {
        guard MacKeyCodePolicy.isAllowedTrailingKeyCode(keyCode) else {
            return nil
        }
        return .custom(keyCode: keyCode, modifiers: modifiers)
    }

    private static func trailingShortcut(
        keyCode: UInt16,
        modifiers: ModifierSet
    ) -> ShortcutDefinition? {
        guard let trailingKey = trailingKey(
            keyCode: keyCode,
            modifiers: modifiers
        ) else { return nil }
        return ShortcutDefinition(trailingKey: trailingKey)
    }
}

struct KeyRecorder: NSViewRepresentable {
    @Binding var shortcut: ShortcutDefinition
    var prompt = "단축키 입력"
    var mode: KeyRecorderMode = .shortcut
    var accessibilityLabel: String?

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView(initialTokens: shortcut.tokens)
        view.onShortcut = { shortcut = $0 }
        view.mode = mode
        view.prompt = prompt
        view.recorderAccessibilityLabel = accessibilityLabel
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onShortcut = { shortcut = $0 }
        nsView.mode = mode
        nsView.prompt = prompt
        nsView.recorderAccessibilityLabel = accessibilityLabel
        nsView.tokens = shortcut.tokens
        nsView.needsDisplay = true
    }
}

final class RecorderView: NSView, NSAccessibilityButton {
    var onShortcut: ((ShortcutDefinition) -> Void)?
    var prompt = "단축키 입력" {
        didSet {
            updateAccessibilityLabel()
            updateAccessibilityValue()
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var recorderAccessibilityLabel: String? {
        didSet { updateAccessibilityLabel() }
    }
    var tokens: [String] {
        didSet {
            guard oldValue != tokens else { return }
            updateAccessibilityValue()
            invalidateIntrinsicContentSize()
            needsDisplay = true
            accessibilityNotifications.postValueChanged(for: self)
        }
    }
    var mode: KeyRecorderMode = .shortcut {
        didSet { updateAccessibilityHelp() }
    }

    private static let horizontalInset: CGFloat = 6
    private static let controlHeight: CGFloat = 26
    private let accessibilityNotifications: AccessibilityNotificationPosting
    private var pendingKeyEquivalentRelease: KeyGesture?

    override convenience init(frame frameRect: NSRect) {
        self.init(
            frame: frameRect,
            initialTokens: [],
            accessibilityNotifications: SystemAccessibilityNotificationPoster()
        )
    }

    convenience init(initialTokens: [String]) {
        self.init(
            frame: .zero,
            initialTokens: initialTokens,
            accessibilityNotifications: SystemAccessibilityNotificationPoster()
        )
    }

    convenience init(accessibilityNotifications: AccessibilityNotificationPosting) {
        self.init(
            frame: .zero,
            initialTokens: [],
            accessibilityNotifications: accessibilityNotifications
        )
    }

    init(
        frame frameRect: NSRect,
        initialTokens: [String],
        accessibilityNotifications: AccessibilityNotificationPosting
    ) {
        tokens = initialTokens
        self.accessibilityNotifications = accessibilityNotifications
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        tokens = []
        accessibilityNotifications = SystemAccessibilityNotificationPoster()
        super.init(coder: coder)
        configureAccessibility()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { true }
    var visibleLabel: String { prompt }
    override var intrinsicContentSize: NSSize {
        let width = visibleLabel.size(withAttributes: textAttributes).width
            + Self.horizontalInset * 2
        return NSSize(width: ceil(width), height: Self.controlHeight)
    }

    var showsFocusRing: Bool {
        window?.firstResponder === self
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { needsDisplay = true }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder {
            pendingKeyEquivalentRelease = nil
            needsDisplay = true
        }
        return resignedFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        pendingKeyEquivalentRelease = nil
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self) ?? false
    }

    override func keyDown(with event: NSEvent) {
        _ = handleRecorderEvent(event, deferringFocusAfterRecord: false)
    }

    override func keyUp(with event: NSEvent) {
        guard pendingKeyEquivalentRelease?.keyCode == event.keyCode else {
            super.keyUp(with: event)
            return
        }
        pendingKeyEquivalentRelease = nil
        window?.selectNextKeyView(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if pendingKeyEquivalentRelease != nil, event.type == .keyDown {
            return true
        }
        if handleRecorderEvent(event, deferringFocusAfterRecord: true) { return true }
        return super.performKeyEquivalent(with: event)
    }

    @discardableResult
    private func handleRecorderEvent(
        _ event: NSEvent,
        deferringFocusAfterRecord: Bool
    ) -> Bool {
        let modifiers = ModifierSet(event.modifierFlags)
        let decision = KeyRecorderTranslator.decision(
            keyCode: event.keyCode,
            modifiers: modifiers,
            isRepeat: event.isARepeat,
            mode: mode
        )
        switch decision {
        case .keepValue:
            if event.keyCode == 48, modifiers.isEmpty {
                window?.selectNextKeyView(self)
                return true
            }
            return false
        case .clear:
            onShortcut?(.init(key: .empty, modifiers: []))
            tokens = []
            return true
        case .resignFocus:
            window?.makeFirstResponder(nil)
            return true
        case .record(let shortcut):
            onShortcut?(shortcut)
            tokens = shortcut.tokens
            if deferringFocusAfterRecord {
                pendingKeyEquivalentRelease = KeyGesture(event)
            } else {
                window?.selectNextKeyView(self)
            }
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
        let size = visibleLabel.size(withAttributes: textAttributes)
        visibleLabel.draw(
            at: NSPoint(
                x: Self.horizontalInset,
                y: (bounds.height - size.height) / 2
            ),
            withAttributes: textAttributes
        )
        drawFocusRingIfNeeded()
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibilityLabel()
        updateAccessibilityValue()
        updateAccessibilityHelp()
    }

    private func updateAccessibilityLabel() {
        setAccessibilityLabel(recorderAccessibilityLabel ?? prompt)
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue(tokens.isEmpty ? "설정 안 됨" : tokens.joined(separator: ", "))
    }

    private func updateAccessibilityHelp() {
        let help = mode == .shortcut
            ? "클릭한 뒤 단축키를 누르세요. Delete 또는 Backspace로 지울 수 있습니다."
            : "클릭한 뒤 후속 키를 누르세요."
        setAccessibilityHelp(help)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        pendingKeyEquivalentRelease = nil
    }

    private func drawFocusRingIfNeeded() {
        guard showsFocusRing else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            xRadius: 4,
            yRadius: 4
        )
        path.lineWidth = 3
        path.stroke()
    }
}

private struct KeyGesture: Equatable {
    let keyCode: UInt16
    let modifiers: ModifierSet

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        modifiers = ModifierSet(event.modifierFlags)
    }
}

private extension ModifierSet {
    init(_ flags: NSEvent.ModifierFlags) {
        var result: ModifierSet = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}
