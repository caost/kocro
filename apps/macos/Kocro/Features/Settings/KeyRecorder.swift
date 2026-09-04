import AppKit
import SwiftUI

enum KeyRecorderTranslator {
    static func shortcut(
        keyCode: UInt16,
        modifiers eventModifiers: NSEvent.ModifierFlags
    ) -> ShortcutDefinition? {
        let modifiers = ModifierSet(eventModifiers)
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
        guard MacKeyCodePolicy.isAllowedTrailingKeyCode(keyCode) else {
            return nil
        }
        return .custom(keyCode: keyCode, modifiers: ModifierSet(eventModifiers))
    }
}

struct KeyRecorder: NSViewRepresentable {
    @Binding var shortcut: ShortcutDefinition
    var prompt = "단축키 입력"
    var allowsUnmodified = false

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onShortcut = { shortcut = $0 }
        view.allowsUnmodified = allowsUnmodified
        view.setAccessibilityLabel(prompt)
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onShortcut = { shortcut = $0 }
        nsView.allowsUnmodified = allowsUnmodified
        nsView.displayText = shortcut.key == .empty ? prompt : shortcut.displayName
        nsView.needsDisplay = true
    }
}

final class RecorderView: NSView {
    var onShortcut: ((ShortcutDefinition) -> Void)?
    var displayText = "단축키 입력"
    var allowsUnmodified = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        let shortcut: ShortcutDefinition?
        if allowsUnmodified,
           case .custom(let keyCode?, let modifiers) = KeyRecorderTranslator.trailingKey(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
           ) {
            shortcut = .init(key: .keyCode(keyCode), modifiers: modifiers)
        } else {
            shortcut = KeyRecorderTranslator.shortcut(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
            )
        }
        guard let shortcut else { return }
        onShortcut?(shortcut)
        displayText = shortcut.displayName
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = displayText.size(withAttributes: attributes)
        displayText.draw(
            at: NSPoint(x: 8, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
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
