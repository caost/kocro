import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case macros
    case general

    var id: String { rawValue }

    var label: String {
        switch self {
        case .macros: return "매크로"
        case .general: return "일반"
        }
    }
}

enum TokenField: Hashable {
    case shortcut(UUID)
    case trailing(UUID)
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            if !isLoadingDraft { isDirty = true }
        }
    }
    @Published var showsReplaceWarning = false
    @Published var saveErrorMessage: String?
    @Published var registration: [UUID: RegistrationState] = [:]
    @Published var selectedSection: SettingsSection = .macros
    @Published private(set) var isDirty = false
    @Published private(set) var tokenDrafts: [TokenField: TokenEditorDraft]

    let validator: SettingsValidator
    var onSave: ((AppSettings) -> Void)?

    private var hasLoadedDraft: Bool
    private var isLoadingDraft = false
    private var savedSettings: AppSettings

    init(settings: AppSettings, validator: SettingsValidator) {
        self.settings = settings
        self.validator = validator
        savedSettings = settings
        tokenDrafts = Self.makeTokenDrafts(for: settings)
        hasLoadedDraft = !settings.macros.isEmpty
    }

    func add() {
        let macro = MacroDefinition.newDraft()
        settings.macros.append(macro)
        tokenDrafts[.shortcut(macro.id)] = Self.shortcutDraft(for: macro)
        tokenDrafts[.trailing(macro.id)] = Self.trailingDraft(for: macro)
        recomputeDirty()
    }

    func delete(at offsets: IndexSet) {
        settings.macros.remove(atOffsets: offsets)
    }

    func move(from offsets: IndexSet, to destination: Int) {
        settings.macros.move(fromOffsets: offsets, toOffset: destination)
    }

    func tokenDraft(for field: TokenField) -> TokenEditorDraft {
        tokenDrafts[field]!
    }

    func updateTokenText(_ text: String, for field: TokenField) {
        tokenDrafts[field]!.updateText(text)
        recomputeDirty()
    }

    func mutateTokenDraft(
        _ field: TokenField,
        _ body: (inout TokenEditorDraft) -> Void
    ) {
        body(&tokenDrafts[field]!)
        recomputeDirty()
    }

    func collapsedShortcutText(for id: UUID) -> String {
        tokenDrafts[.shortcut(id)]?.text ?? ""
    }

    @discardableResult
    func prepareTokenEditsForSave() -> Bool {
        for index in settings.macros.indices {
            let id = settings.macros[index].id
            let shortcutField = TokenField.shortcut(id)
            let trailingField = TokenField.trailing(id)
            guard commitTokenDraft(shortcutField),
                  commitTokenDraft(trailingField) else {
                recomputeDirty()
                return false
            }
            apply(tokenDrafts[shortcutField]!.value, at: index)
            apply(tokenDrafts[trailingField]!.value, at: index)
        }
        recomputeDirty()
        return true
    }

    func characterCount(for id: UUID) -> Int? {
        settings.macros.first(where: { $0.id == id })?.text.count
    }

    func errors(for id: UUID) -> [String] {
        guard let macro = settings.macros.first(where: { $0.id == id }) else {
            return ["항목을 찾을 수 없습니다"]
        }

        var errors = validator.issues(for: macro, in: settings).map(message(for:))
        if let registrationState = registration[id], registrationState != .registered {
            errors.append(registrationMessage(registrationState))
        }
        return errors
    }

    private func message(for issue: ValidationError) -> String {
        switch issue {
        case .duplicateID:
            return "항목 ID가 중복됩니다"
        case .textTooLong:
            return "문자열은 \(MacroDefinition.maximumTextCountText)자 이하여야 합니다"
        case .emptyText:
            return "활성 매크로의 문자열이 비어 있습니다"
        case .emptyShortcut, .modifierRequired, .unsupportedFunction,
             .unsupportedModifiers, .hidOnlyKeyRejectsModifiers:
            return "단축키를 수정하세요"
        case .duplicateShortcut:
            return "활성 단축키가 중복됩니다"
        case .invalidTrailing:
            return "후속 키를 수정하세요"
        }
    }

    func save() {
        guard prepareTokenEditsForSave() else {
            saveErrorMessage = "표시된 토큰 오류를 수정하세요"
            return
        }
        do {
            _ = try validator.validate(settings)
        } catch {
            isDirty = true
            saveErrorMessage = "표시된 항목을 수정한 뒤 다시 저장하세요"
            return
        }
        saveErrorMessage = nil
        onSave?(settings)
    }

    func loadDraftIfNeeded(from app: AppController) {
        guard !hasLoadedDraft, !isDirty else { return }
        guard app.loadError == nil || app.showsReplaceWarning else { return }
        isLoadingDraft = true
        settings = app.draft
        tokenDrafts = Self.makeTokenDrafts(for: settings)
        savedSettings = settings
        isLoadingDraft = false
        hasLoadedDraft = true
        isDirty = false
        synchronizeStatus(from: app)
    }

    func synchronizeStatus(from app: AppController) {
        showsReplaceWarning = app.showsReplaceWarning
        registration = app.registration
        if let error = app.saveError {
            saveErrorMessage = "설정을 저장하지 못했습니다 (\(String(describing: type(of: error))))"
        }
    }

    func markSaved(_ value: AppSettings) {
        isLoadingDraft = true
        settings = value
        tokenDrafts = Self.makeTokenDrafts(for: value)
        savedSettings = value
        isLoadingDraft = false
        hasLoadedDraft = true
        isDirty = false
        saveErrorMessage = nil
    }

    private func registrationMessage(_ state: RegistrationState) -> String {
        switch state {
        case .registered:
            return ""
        case .registrationFailed:
            return "다른 앱 또는 macOS가 이 단축키를 사용하고 있습니다"
        case .inputMonitoringRequired:
            return "F21~F24 사용에는 Input Monitoring 권한이 필요합니다"
        case .hidStartFailed:
            return "F21~F24 모니터를 시작하지 못했습니다"
        }
    }

    private func commitTokenDraft(_ field: TokenField) -> Bool {
        tokenDrafts[field]!.commit()
    }

    private func apply(_ value: TokenStoredValue, at index: Int) {
        switch value {
        case .shortcut(let shortcut):
            settings.macros[index].shortcut = shortcut
        case .trailing(let trailingKey):
            settings.macros[index].trailingKey = trailingKey
        }
    }

    private func recomputeDirty() {
        isDirty = settings != savedSettings
            || tokenDrafts.values.contains(where: \.isDirty)
    }

    private static func makeTokenDrafts(
        for settings: AppSettings
    ) -> [TokenField: TokenEditorDraft] {
        var drafts: [TokenField: TokenEditorDraft] = [:]
        for macro in settings.macros {
            drafts[.shortcut(macro.id)] = shortcutDraft(for: macro)
            drafts[.trailing(macro.id)] = trailingDraft(for: macro)
        }
        return drafts
    }

    private static func shortcutDraft(for macro: MacroDefinition) -> TokenEditorDraft {
        TokenEditorDraft(value: .shortcut(macro.shortcut), mode: .shortcut)
    }

    private static func trailingDraft(for macro: MacroDefinition) -> TokenEditorDraft {
        TokenEditorDraft(value: .trailing(macro.trailingKey), mode: .trailing)
    }
}

@MainActor
struct GeneralSettingsViewModel {
    private let app: AppController
    private let login: LoginItemController
    private let draft: AppSettings

    init(app: AppController, login: LoginItemController, draft: AppSettings? = nil) {
        self.app = app
        self.login = login
        self.draft = draft ?? app.draft
    }

    var loginEnabled: Bool { login.isEnabled }
    var loginErrorMessage: String? { login.errorMessage }
    var accessibilityGranted: Bool { app.permissionState.accessibility }
    var inputMonitoringGranted: Bool? { app.permissionState.inputMonitoring }
    var showsInputMonitoring: Bool {
        needsInputMonitoring(app.runtime) || needsInputMonitoring(draft)
    }

    func setLoginEnabled(_ enabled: Bool) {
        login.setEnabledReportingError(enabled)
    }

    func requestAccessibility() { app.requestAccessibility() }
    func openAccessibilitySettings() { app.openPrivacySettings(.accessibility) }
    func requestInputMonitoring() { app.requestInputMonitoring() }
    func openInputMonitoringSettings() { app.openPrivacySettings(.inputMonitoring) }
    func refreshPermissions() {
        app.refreshPermissions(forDraft: draft, reconcileShortcuts: false)
    }

    private func needsInputMonitoring(_ settings: AppSettings) -> Bool {
        settings.macros.contains { $0.isEnabled && $0.shortcut.isHIDOnly }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var app: AppController
    @ObservedObject var login: LoginItemController
    let prepare: () -> Void

    var body: some View {
        TabView(selection: $model.selectedSection) {
            macrosSection
                .tabItem { Text(SettingsSection.macros.label) }
                .tag(SettingsSection.macros)
            GeneralSettingsView(
                model: .init(app: app, login: login, draft: model.settings)
            )
            .tabItem { Text(SettingsSection.general.label) }
            .tag(SettingsSection.general)
        }
        .padding()
        .frame(minWidth: 1_100, minHeight: 560)
        .onAppear(perform: prepare)
    }

    private var macrosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kocro 설정")
                .font(.title2)

            if model.showsReplaceWarning {
                Text("기존 설정 파일을 읽을 수 없습니다. 저장하면 새 설정으로 교체합니다.")
                    .foregroundStyle(.orange)
            }
            if let message = model.saveErrorMessage {
                Text(message)
                    .foregroundStyle(.red)
            }
            Text("비밀번호, API 키와 인증 토큰을 저장하지 마세요.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($model.settings.macros) { $macro in
                    MacroRow(
                        macro: $macro,
                        model: model,
                        errors: model.errors(for: macro.id)
                    )
                }
                .onDelete(perform: model.delete)
                .onMove(perform: model.move)
            }

            HStack {
                Button("추가", action: model.add)
                Spacer()
                if model.isDirty {
                    Text("저장하지 않은 변경 사항")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("저장", action: model.save)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.top, 8)
    }
}

private struct GeneralSettingsView: View {
    let model: GeneralSettingsViewModel

    var body: some View {
        Form {
            Section("로그인") {
                Toggle(
                    "로그인 시 실행",
                    isOn: Binding(
                        get: { model.loginEnabled },
                        set: model.setLoginEnabled
                    )
                )
                if let message = model.loginErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }

            Section("Accessibility") {
                permissionStatus(granted: model.accessibilityGranted)
                Button("권한 안내 요청", action: model.requestAccessibility)
                    .accessibilityLabel("Accessibility 권한 안내 요청")
                Button("시스템 설정 열기", action: model.openAccessibilitySettings)
                    .accessibilityLabel("Accessibility 시스템 설정 열기")
            }

            if model.showsInputMonitoring {
                Section("Input Monitoring") {
                    permissionStatus(granted: model.inputMonitoringGranted == true)
                    Button("권한 요청", action: model.requestInputMonitoring)
                        .accessibilityLabel("Input Monitoring 권한 요청")
                    Button("시스템 설정 열기", action: model.openInputMonitoringSettings)
                        .accessibilityLabel("Input Monitoring 시스템 설정 열기")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear(perform: model.refreshPermissions)
    }

    private func permissionStatus(granted: Bool) -> some View {
        Text(granted ? "허용됨" : "권한 필요")
            .accessibilityLabel(granted ? "권한 허용됨" : "권한 필요")
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

private struct TokenEditor: View {
    let field: TokenField
    @ObservedObject var model: SettingsViewModel
    let accessibilityLabel: String

    private var draft: TokenEditorDraft { model.tokenDraft(for: field) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TokenTextField(
                    text: Binding(
                        get: { draft.text },
                        set: { model.updateTokenText($0, for: field) }
                    ),
                    accessibilityLabel: accessibilityLabel,
                    hasCompletions: { !draft.completions.isEmpty },
                    onCommit: commit,
                    onMoveCompletion: moveCompletion,
                    onAcceptCompletion: acceptCompletion
                )
                .frame(minWidth: 220, minHeight: 26)

                KeyRecorder(
                    shortcut: recordedShortcut,
                    prompt: "키로 기록",
                    mode: mode == .shortcut ? .shortcut : .trailing,
                    accessibilityLabel: "\(accessibilityLabel) 키로 기록"
                )
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 26)

                if mode == .shortcut {
                    Menu("F21~F24 선택") {
                        ForEach(21...24, id: \.self) { number in
                            Button("F\(number)") {
                                model.mutateTokenDraft(field) {
                                    $0.selectToken("{KC_F\(number)}")
                                }
                            }
                        }
                    }
                } else {
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
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(accessibilityLabel) 오류: \(issue.message)")
            }

            Text("macOS가 먼저 처리한 조합은 토큰으로 직접 입력하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mode: TokenEditorMode {
        switch field {
        case .shortcut: return .shortcut
        case .trailing: return .trailing
        }
    }

    private var recordedShortcut: Binding<ShortcutDefinition> {
        Binding(
            get: {
                switch draft.value {
                case .shortcut(let shortcut):
                    return shortcut
                case .trailing(let trailingKey):
                    return ShortcutDefinition(trailingKey: trailingKey)
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
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.setAccessibilityLabel(accessibilityLabel)
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

private struct MacroRow: View {
    @Binding var macro: MacroDefinition
    @ObservedObject var model: SettingsViewModel
    let errors: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("제목", text: $macro.title, prompt: Text(macro.displayTitle))
                    .frame(width: 180)
                    .accessibilityLabel(macro.displayTitle)
                Toggle("활성화", isOn: $macro.isEnabled)
                    .toggleStyle(.checkbox)
                TokenEditor(
                    field: .shortcut(macro.id),
                    model: model,
                    accessibilityLabel: recorderAccessibilityLabels.shortcut
                )
                Spacer()
                Text(String(macro.id.uuidString.prefix(8)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $macro.text)
                .font(.body.monospaced())
                .frame(minHeight: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3))
                )
            Text("\(macro.text.count) / \(MacroDefinition.maximumTextCountText)")
                .font(.caption)
                .foregroundStyle(
                    macro.text.count > MacroDefinition.maximumTextCount ? .red : .secondary
                )

            TokenEditor(
                field: .trailing(macro.id),
                model: model,
                accessibilityLabel: recorderAccessibilityLabels.trailing
            )

            ForEach(errors, id: \.self) { error in
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
    }

    private var recorderAccessibilityLabels: MacroRecorderAccessibilityLabels {
        MacroRecorderAccessibilityLabels(macro)
    }

}
