import AppKit
import SwiftUI

enum MacroStatusBadge: Equatable {
    case inactive
    case unsaved
    case registered
    case conflict
    case registrationFailed

    var label: String {
        switch self {
        case .inactive: return "비활성"
        case .unsaved: return "저장 전"
        case .registered: return "등록됨"
        case .conflict: return "충돌"
        case .registrationFailed: return "등록 실패"
        }
    }

    static func resolve(
        isEnabled: Bool,
        isDirty: Bool,
        registration: RegistrationState?
    ) -> Self {
        if registration == .conflict { return .conflict }
        if registration == .registrationFailed { return .registrationFailed }
        if isDirty { return .unsaved }
        if !isEnabled { return .inactive }
        return registration == .registered ? .registered : .registrationFailed
    }
}

struct MacroCardAccessibilityLabels: Equatable {
    let enabled: String
    let title: String
    let delete: String
    let expand: String
    let reorder: String

    init(id: UUID) {
        let prefix = "매크로 \(id.uuidString)"
        enabled = "\(prefix) 활성화"
        title = "\(prefix) 제목"
        delete = "\(prefix) 삭제"
        expand = "\(prefix) 펼치기 또는 접기"
        reorder = "\(prefix) 순서 변경"
    }
}

struct CollapsedShortcutAccessibilityPresentation: Equatable {
    let label: String
    let value: String
}

struct MacroCard: View {
    @Binding var macro: MacroDefinition
    @ObservedObject var model: SettingsViewModel
    let errors: [String]
    let focusedField: FocusState<MacroFieldFocus?>.Binding

    private var isExpanded: Bool { model.expandedMacroID == macro.id }
    private var badge: MacroStatusBadge { model.badge(for: macro.id) }
    private var labels: MacroCardAccessibilityLabels {
        MacroCardAccessibilityLabels(id: macro.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(labels.reorder)
                    .accessibilityAction(named: Text("위로 이동")) {
                        model.move(id: macro.id, direction: .up)
                    }
                    .accessibilityAction(named: Text("아래로 이동")) {
                        model.move(id: macro.id, direction: .down)
                    }
                MacroActivationToggle(
                    isOn: $macro.isEnabled,
                    accessibilityLabel: labels.enabled
                )
                TextField(
                    "제목",
                    text: $macro.title,
                    prompt: Text(macro.settingsDisplayTitle)
                )
                .frame(minWidth: 48, idealWidth: 220)
                .accessibilityLabel(labels.title)
                .focused(focusedField, equals: .title(macro.id))
                let accessibility = model.collapsedShortcutAccessibilityPresentation(
                    for: macro.id
                )
                CollapsedShortcutBlocks(
                    tokens: model.collapsedShortcutTokens(for: macro.id),
                    accessibility: accessibility
                )
                .frame(maxWidth: 320, alignment: .leading)
                .clipped()
                .layoutPriority(1)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text(badge.label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        .accessibilityLabel(badge.label)
                    Button(role: .destructive) {
                        model.delete(id: macro.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(labels.delete)
                    Button {
                        model.expand(macro.id)
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(labels.expand)
                    .accessibilityValue(isExpanded ? "펼쳐짐" : "접힘")
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }
            .background {
                Button {
                    model.selectHeader(macro.id)
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(labels.expand), 헤더")
                .accessibilityValue(isExpanded ? "펼쳐짐" : "접힘")
            }

            if isExpanded {
                Divider()
                Text("실행 단축키").font(.headline)
                TokenEditor(
                    field: .shortcut(macro.id),
                    model: model,
                    accessibilityLabel: recorderAccessibilityLabels.shortcut,
                    focusedField: focusedField
                )

                Text("입력할 문자열").font(.headline)
                TextEditor(text: $macro.text)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                    .accessibilityLabel("매크로 \(macro.id.uuidString) 입력할 문자열")
                    .focused(focusedField, equals: .text(macro.id))
                Text("\(macro.text.count) / \(MacroDefinition.maximumTextCountText)")
                    .font(.caption)
                    .foregroundStyle(
                        macro.text.count > MacroDefinition.maximumTextCount ? .red : .secondary
                    )

                Text("후속 키").font(.headline)
                TokenEditor(
                    field: .trailing(macro.id),
                    model: model,
                    accessibilityLabel: recorderAccessibilityLabels.trailing,
                    focusedField: focusedField
                )

                ForEach(errors, id: \.self) { error in
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25))
        )
        .onChange(of: badge.label) { label in
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "\(macro.settingsDisplayTitle) 상태 \(label)",
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }

    private var recorderAccessibilityLabels: MacroRecorderAccessibilityLabels {
        MacroRecorderAccessibilityLabels(macro)
    }

}

private struct CollapsedShortcutBlocks: View {
    let tokens: [String]
    let accessibility: CollapsedShortcutAccessibilityPresentation

    var body: some View {
        Group {
            if tokens.isEmpty {
                Text("단축키 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                        Text(token)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.25))
                            )
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
    }
}

struct MacroActivationToggle: View {
    @Binding var isOn: Bool
    let accessibilityLabel: String

    var body: some View {
        Toggle("활성화", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(accessibilityLabel)
    }
}
