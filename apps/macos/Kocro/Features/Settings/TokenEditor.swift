import AppKit
import SwiftUI

struct TokenEditorAccessibilityState: Equatable {
    let label: String
    let value: String
    let help: String
    let announcement: String?

    init(fieldLabel: String, draft: TokenEditorDraft) {
        label = fieldLabel
        value = draft.text.isEmpty ? "설정 안 됨" : draft.text
        if let issue = draft.issues.first {
            let presentation = TokenIssuePresentation(issue: issue)
            help = presentation.accessibilityMessage
            announcement = presentation.accessibilityMessage
        } else if draft.completions.indices.contains(draft.selectedCompletion) {
            help = "자동완성 선택 \(draft.completions[draft.selectedCompletion])"
            announcement = help
        } else {
            help = "토큰을 직접 입력하거나 키로 기록하세요"
            announcement = nil
        }
    }
}

struct TokenIssuePresentation: Equatable {
    let message: String
    let accessibilityMessage: String

    init(issue: TokenIssue) {
        message = "\(issue.message) (문제 토큰: \(issue.token))"
        accessibilityMessage = message
    }
}

struct MacroRecorderAccessibilityLabels: Equatable {
    let shortcut: String
    let trailing: String

    init(_ macro: MacroDefinition) {
        let context = "\(macro.displayTitle) (\(macro.id.uuidString))"
        shortcut = "\(context) 단축키"
        trailing = "\(context) 후속 키"
    }
}

struct TokenEditor: View {
    let field: TokenField
    @ObservedObject var model: SettingsViewModel
    let accessibilityLabel: String
    let focusedField: FocusState<MacroFieldFocus?>.Binding

    private var draft: TokenEditorDraft { model.tokenDraft(for: field) }
    private var accessibilityState: TokenEditorAccessibilityState {
        .init(fieldLabel: accessibilityLabel, draft: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TokenTextField(
                    text: Binding(
                        get: { draft.text },
                        set: { model.updateTokenText($0, for: field) }
                    ),
                    accessibilityLabel: accessibilityLabel,
                    accessibilityValue: accessibilityState.value,
                    accessibilityHelp: accessibilityState.help,
                    hasCompletions: { !draft.completions.isEmpty },
                    onCommit: commit,
                    onMoveCompletion: moveCompletion,
                    onAcceptCompletion: acceptCompletion
                )
                .frame(minWidth: 220, minHeight: 26)
                .focused(focusedField, equals: field.focus)

                KeyRecorder(
                    shortcut: recordedShortcut,
                    prompt: "키로 기록",
                    mode: mode,
                    accessibilityLabel: "\(accessibilityLabel) 키로 기록"
                )
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 26)

                if mode == .trailing {
                    Button("지우기") {
                        model.mutateTokenDraft(field) { $0.clear() }
                    }
                }
            }

            if !draft.completions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(draft.completions.enumerated()), id: \.offset) { index, token in
                        Button(token) {
                            model.mutateTokenDraft(field) {
                                $0.acceptCompletion(at: index)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                        .background(
                            index == draft.selectedCompletion
                                ? Color.accentColor.opacity(0.2)
                                : Color.clear
                        )
                        .accessibilityValue(
                            index == draft.selectedCompletion ? "선택됨" : ""
                        )
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3))
                )
            }

            ForEach(Array(draft.issues.enumerated()), id: \.offset) { _, issue in
                let presentation = TokenIssuePresentation(issue: issue)
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(
                        "\(accessibilityLabel) 오류: \(presentation.accessibilityMessage)"
                    )
            }

            Text("macOS가 먼저 처리한 조합은 토큰으로 직접 입력하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: accessibilityState.announcement) { announcement in
            guard let announcement else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    private var mode: KeyInputMode {
        switch field {
        case .shortcut: return .shortcut
        case .step: return .trailing
        }
    }

    private var recordedShortcut: Binding<ShortcutDefinition> {
        Binding(
            get: {
                switch draft.value {
                case .shortcut(let shortcut):
                    return shortcut
                case .trailing(let trailingKey):
                    guard let combination = KeyCombination(trailingKey: trailingKey) else {
                        return .init(key: .empty, modifiers: [])
                    }
                    return ShortcutDefinition(trailingKey: combination.trailingKey)
                }
            },
            set: { shortcut in
                model.mutateTokenDraft(field) { $0.applyRecorded(shortcut) }
            }
        )
    }

    private func commit() {
        model.mutateTokenDraft(field) { _ = $0.commit() }
    }

    private func moveCompletion(_ move: CompletionMove) {
        model.mutateTokenDraft(field) { $0.moveCompletion(move) }
    }

    private func acceptCompletion() {
        model.mutateTokenDraft(field) { $0.acceptCompletion() }
    }
}

private struct TokenTextField: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityHelp: String
    let hasCompletions: () -> Bool
    let onCommit: () -> Void
    let onMoveCompletion: (CompletionMove) -> Void
    let onAcceptCompletion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.delegate = context.coordinator
        textField.placeholderString = "{KC_CMD}+{KC_F13}"
        textField.setAccessibilityLabel(accessibilityLabel)
        textField.setAccessibilityValue(accessibilityValue)
        textField.setAccessibilityHelp(accessibilityHelp)
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.setAccessibilityLabel(accessibilityLabel)
        nsView.setAccessibilityValue(accessibilityValue)
        nsView.setAccessibilityHelp(accessibilityHelp)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TokenTextField

        init(parent: TokenTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onCommit()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard parent.hasCompletions() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveCompletion(.up)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveCompletion(.down)
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                parent.onAcceptCompletion()
            default:
                return false
            }
            return true
        }
    }
}
