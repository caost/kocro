import AppKit
import SwiftUI

enum MacroStatusBadge: Equatable {
    case inactive, unsaved, registered, conflict, registrationFailed

    var label: String {
        switch self {
        case .inactive: return "비활성"
        case .unsaved: return "저장 전"
        case .registered: return "등록됨"
        case .conflict: return "충돌"
        case .registrationFailed: return "등록 실패"
        }
    }

    static func resolve(isEnabled: Bool, isDirty: Bool, registration: RegistrationState?) -> Self {
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
    private var labels: MacroCardAccessibilityLabels { .init(id: macro.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(labels.reorder)
                    .accessibilityAction(named: Text("위로 이동")) { model.move(id: macro.id, direction: .up) }
                    .accessibilityAction(named: Text("아래로 이동")) { model.move(id: macro.id, direction: .down) }
                MacroActivationToggle(isOn: $macro.isEnabled, accessibilityLabel: labels.enabled)
                TextField("제목", text: $macro.title, prompt: Text(macro.settingsDisplayTitle))
                    .frame(minWidth: 48, idealWidth: 220)
                    .accessibilityLabel(labels.title)
                    .focused(focusedField, equals: .title(macro.id))
                CollapsedShortcutBlocks(
                    tokens: model.collapsedShortcutTokens(for: macro.id),
                    accessibility: model.collapsedShortcutAccessibilityPresentation(for: macro.id)
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
                    Button(role: .destructive) { model.delete(id: macro.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(labels.delete)
                    Button { model.expand(macro.id) } label: {
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
                Button { model.selectHeader(macro.id) } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(labels.expand), 헤더")
                .accessibilityValue(isExpanded ? "펼쳐짐" : "접힘")
            }
            if isExpanded {
                Divider()
                Text("실행 단축키").font(.headline)
                TokenEditor(field: .shortcut(macro.id), model: model,
                            accessibilityLabel: MacroRecorderAccessibilityLabels(macro).shortcut,
                            focusedField: focusedField)
                Text("실행 순서").font(.headline)
                ForEach($macro.steps) { $step in
                    MacroStepRow(step: $step, macroID: macro.id, model: model,
                                 focusedField: focusedField)
                }
                HStack {
                    Button("문자열 추가") { model.addTextStep(macroID: macro.id) }
                        .accessibilityLabel("매크로 \(macro.id.uuidString) 문자열 추가")
                    Button("키 조합 추가") { model.addKeyStep(macroID: macro.id) }
                        .accessibilityLabel("매크로 \(macro.id.uuidString) 키 조합 추가")
                    Button("딜레이 추가") { model.addDelayStep(macroID: macro.id) }
                        .accessibilityLabel("매크로 \(macro.id.uuidString) 딜레이 추가")
                }
                Text("\(macro.combinedTextCount) / \(MacroDefinition.maximumTextCountText)")
                    .font(.caption)
                    .foregroundStyle(macro.combinedTextCount > MacroDefinition.maximumTextCount ? .red : .secondary)
                ForEach(errors, id: \.self) { error in
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .onChange(of: badge.label) { label in
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: "\(macro.settingsDisplayTitle) 상태 \(label)",
                           .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
}

private struct MacroStepRow: View {
    @Binding var step: MacroStep
    let macroID: UUID
    @ObservedObject var model: SettingsViewModel
    let focusedField: FocusState<MacroFieldFocus?>.Binding

    private var label: String { "매크로 \(macroID.uuidString) 단계 \(step.id.uuidString)" }
    private var focus: MacroFieldFocus { .step(macroID: macroID, stepID: step.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(step.displayName).lineLimit(1)
                Spacer()
                Button { model.moveStep(id: step.id, direction: .up) } label: {
                    Image(systemName: "arrow.up")
                }
                .accessibilityLabel("\(label) 위로 이동")
                Button { model.moveStep(id: step.id, direction: .down) } label: {
                    Image(systemName: "arrow.down")
                }
                .accessibilityLabel("\(label) 아래로 이동")
                Button(role: .destructive) { model.deleteStep(macroID: macroID, stepID: step.id) } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("\(label) 삭제")
            }
            switch step.kind {
            case .text:
                TextEditor(text: Binding(get: {
                    if case .text(let value) = step.kind { return value }
                    return ""
                }, set: { step.kind = .text($0) }))
                .font(.body.monospaced())
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("\(label) 입력할 문자열")
                .focused(focusedField, equals: focus)
            case .keys:
                TokenEditor(field: .step(macroID: macroID, stepID: step.id), model: model,
                            accessibilityLabel: "\(label) 키 조합", focusedField: focusedField)
            case .delay:
                HStack {
                    TextField("대기 시간", text: Binding(get: {
                        if case .delay(let ms) = step.kind { return String(ms) }
                        return ""
                    }, set: { value in
                        model.updateDelay(milliseconds: Int(value) ?? -1, macroID: macroID, stepID: step.id)
                    }))
                    .frame(width: 100)
                    .accessibilityLabel("\(label) 대기 시간 밀리초")
                    .focused(focusedField, equals: focus)
                    Text("ms (0~60,000)").foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityAction(named: Text("위로 이동")) { model.moveStep(id: step.id, direction: .up) }
        .accessibilityAction(named: Text("아래로 이동")) { model.moveStep(id: step.id, direction: .down) }
        .accessibilityAction(named: Text("삭제")) { model.deleteStep(macroID: macroID, stepID: step.id) }
    }
}

private struct CollapsedShortcutBlocks: View {
    let tokens: [String]
    let accessibility: CollapsedShortcutAccessibilityPresentation

    var body: some View {
        Group {
            if tokens.isEmpty {
                Text("단축키 없음").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                        Text(token)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
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
