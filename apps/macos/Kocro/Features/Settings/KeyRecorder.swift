import AppKit
import SwiftUI

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
    private static let tokenHorizontalPadding: CGFloat = 12
    private static let tokenSpacing: CGFloat = 4
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
    override var intrinsicContentSize: NSSize {
        let width: CGFloat
        if tokens.isEmpty {
            width = prompt.size(withAttributes: textAttributes).width
                + Self.horizontalInset * 2
        } else {
            width = (tokenFrames(in: .init(
                x: 0,
                y: 0,
                width: .greatestFiniteMagnitude,
                height: Self.controlHeight
            )).last?.maxX ?? Self.horizontalInset) + Self.horizontalInset
        }
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
        guard !tokens.isEmpty else {
            let size = prompt.size(withAttributes: textAttributes)
            prompt.draw(
                at: NSPoint(
                    x: Self.horizontalInset,
                    y: (bounds.height - size.height) / 2
                ),
                withAttributes: textAttributes
            )
            drawFocusRingIfNeeded()
            return
        }

        for (token, badge) in zip(tokens, tokenFrames(in: bounds)) {
            let size = token.size(withAttributes: textAttributes)
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).stroke()
            token.draw(
                at: NSPoint(x: badge.minX + 6, y: (bounds.height - size.height) / 2),
                withAttributes: textAttributes
            )
        }
        drawFocusRingIfNeeded()
    }

    func tokenFrames(in bounds: NSRect) -> [NSRect] {
        var x = bounds.minX + Self.horizontalInset
        return tokens.map { token in
            let width = token.size(withAttributes: textAttributes).width
                + Self.tokenHorizontalPadding
            let frame = NSRect(x: x, y: bounds.minY + 3, width: width, height: bounds.height - 6)
            x = frame.maxX + Self.tokenSpacing
            return frame
        }
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
