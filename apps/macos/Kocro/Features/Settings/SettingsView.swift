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

struct DeletedMacro: Equatable {
    let macro: MacroDefinition
    let index: Int
}

enum MacroFieldFocus: Hashable {
    case title(UUID)
    case shortcut(UUID)
    case text(UUID)
    case trailing(UUID)
}

enum MacroMoveDirection: Equatable {
    case up
    case down
}

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
        if registration == .registrationFailed { return .conflict }
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

struct SupportedKeyHelp {
    struct Section: Identifiable, Equatable {
        let title: String
        let body: String
        var id: String { title }
    }

    static let sections = [
        Section(
            title: "실행 단축키",
            body: "실행 단축키는 modifier와 문자·숫자·기호, navigation·whitespace 키를 조합해 입력합니다. Escape, Backspace와 Delete는 실행 단축키로 사용할 수 없습니다. 일반 키와 F1~F12에는 보조 키가 필요합니다. Command만 사용하는 표준 단축키는 사용할 수 없습니다. F13~F20은 단독 또는 보조 키 조합을 지원합니다. F21~F35, Fn, Caps Lock, 미디어 키는 지원하지 않습니다."
        ),
        Section(
            title: "후속 키",
            body: "후속 키는 문자·숫자·기호, navigation·editing·whitespace와 F1~F20을 지원합니다. F21~F35, Fn, Caps Lock, 미디어 키는 지원하지 않습니다."
        ),
        Section(
            title: "토큰과 별칭",
            body: "보조 키 토큰은 {KC_CTRL}, {KC_OPT}, {KC_SHIFT}, {KC_CMD}입니다. 좌우 modifier 별칭 {KC_LCTL}/{KC_RCTL}, {KC_LALT}/{KC_RALT}, {KC_LSFT}/{KC_RSFT}, {KC_LCMD}/{KC_RCMD}도 입력할 수 있습니다."
        ),
    ]
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
    @Published private(set) var expandedMacroID: UUID?
    @Published private(set) var deletedMacros: [DeletedMacro] = []
    @Published var focusedField: MacroFieldFocus?

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
        expandedMacroID = macro.id
        focusedField = .title(macro.id)
        recomputeDirty()
    }

    func delete(at offsets: IndexSet) {
        let ids = offsets.sorted(by: >).compactMap { index in
            settings.macros.indices.contains(index) ? settings.macros[index].id : nil
        }
        for id in ids { delete(id: id) }
    }

    func delete(id: UUID) {
        guard let index = settings.macros.firstIndex(where: { $0.id == id }) else {
            return
        }
        deletedMacros.append(
            DeletedMacro(macro: settings.macros.remove(at: index), index: index)
        )
        if expandedMacroID == id { expandedMacroID = nil }
        if focusedField?.macroID == id { focusedField = nil }
        recomputeDirty()
    }

    func undoDelete() {
        guard let deletion = deletedMacros.popLast() else { return }
        settings.macros.insert(
            deletion.macro,
            at: min(deletion.index, settings.macros.count)
        )
        recomputeDirty()
    }

    func clearDeletionHistory() {
        deletedMacros.removeAll()
    }

    var canUndoDelete: Bool { !deletedMacros.isEmpty }

    var replaceWarningMessage: String? {
        showsReplaceWarning
            ? "저장하면 기존 설정 파일을 기본 설정으로 교체합니다."
            : nil
    }

    func expand(_ id: UUID) {
        expandedMacroID = expandedMacroID == id ? nil : id
        if expandedMacroID == nil, focusedField?.macroID == id {
            focusedField = nil
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        settings.macros.move(fromOffsets: offsets, toOffset: destination)
    }

    @discardableResult
    func move(id: UUID, direction: MacroMoveDirection) -> Bool {
        guard let index = settings.macros.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let destination = direction == .up ? index - 1 : index + 1
        guard settings.macros.indices.contains(destination) else { return false }
        settings.macros.swapAt(index, destination)
        return true
    }

    func selectHeader(_ id: UUID) {
        guard expandedMacroID != id else { return }
        expandedMacroID = id
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

    func collapsedShortcutTokens(for id: UUID) -> [String] {
        let source = collapsedShortcutText(for: id)
        let validation = TokenShortcutCodec.validate(source, mode: .shortcut)
        guard let canonicalText = validation.canonicalText else {
            return source.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [source]
        }
        return canonicalText
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func collapsedShortcutAccessibilityValue(for id: UUID) -> String {
        let source = collapsedShortcutText(for: id)
        let validation = TokenShortcutCodec.validate(source, mode: .shortcut)
        guard case .shortcut(let shortcut)? = validation.value else {
            return source.trimmingCharacters(in: .whitespaces).isEmpty
                ? "설정 안 됨"
                : "유효하지 않은 단축키, \(source)"
        }
        return shortcut.tokens.isEmpty
            ? "설정 안 됨"
            : shortcut.tokens.joined(separator: ", ")
    }

    func collapsedShortcutAccessibilityPresentation(
        for id: UUID
    ) -> CollapsedShortcutAccessibilityPresentation {
        let label = settings.macros.first(where: { $0.id == id })
            .map { MacroRecorderAccessibilityLabels($0).shortcut }
            ?? "실행 단축키"
        return .init(
            label: label,
            value: collapsedShortcutAccessibilityValue(for: id)
        )
    }

    func badge(for id: UUID) -> MacroStatusBadge {
        guard let macro = settings.macros.first(where: { $0.id == id }) else {
            return .registrationFailed
        }
        let savedMacro = savedSettings.macros.first(where: { $0.id == id })
        let tokenDirty = tokenDrafts[.shortcut(id)]?.isDirty == true
            || tokenDrafts[.trailing(id)]?.isDirty == true
        return .resolve(
            isEnabled: macro.isEnabled,
            isDirty: savedMacro != macro || tokenDirty,
            registration: registration[id]
        )
    }

    @discardableResult
    func prepareTokenEditsForSave() -> Bool {
        for index in settings.macros.indices {
            let id = settings.macros[index].id
            let shortcutField = TokenField.shortcut(id)
            let trailingField = TokenField.trailing(id)
            guard commitTokenDraft(shortcutField) else {
                reveal(id: id, field: .shortcut(id))
                recomputeDirty()
                return false
            }
            guard commitTokenDraft(trailingField) else {
                reveal(id: id, field: .trailing(id))
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
        if let draftIssue = currentShortcutIssue(for: macro) {
            let draftMessage = message(for: draftIssue)
            if !errors.contains(draftMessage) {
                errors.append(draftMessage)
            }
        }
        if let registrationState = registration[id], registrationState != .registered {
            errors.append(registrationMessage(registrationState))
        }
        return errors
    }

    private func currentShortcutIssue(for macro: MacroDefinition) -> ValidationError? {
        guard macro.isEnabled,
              let draft = tokenDrafts[.shortcut(macro.id)],
              case .shortcut(let shortcut)? = TokenShortcutCodec.validate(
                draft.text,
                mode: .shortcut
              ).value else {
            return nil
        }
        do {
            try validator.validateShortcut(shortcut)
            return nil
        } catch let issue as ValidationError {
            return issue
        } catch {
            return nil
        }
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
             .unsupportedModifiers:
            return "단축키를 수정하세요"
        case .reservedShortcut:
            return "이미 사용 중인 단축키입니다"
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
            revealFirstValidationIssue()
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
            if expandedMacroID == nil { expandedMacroID = settings.macros.first?.id }
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
        showsReplaceWarning = false
        deletedMacros.removeAll()
        expandedMacroID = nil
        focusedField = nil
    }

    private func registrationMessage(_ state: RegistrationState) -> String {
        switch state {
        case .registered:
            return ""
        case .registrationFailed:
            return "다른 앱 또는 macOS가 이 단축키를 사용하고 있습니다"
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

    private func revealFirstValidationIssue() {
        for macro in settings.macros {
            let issues = validator.issues(for: macro, in: settings)
            guard !issues.isEmpty else {
                continue
            }
            let issue = issues.first { issue in
                switch issue {
                case .emptyShortcut, .modifierRequired, .unsupportedFunction,
                     .unsupportedModifiers, .reservedShortcut,
                     .duplicateShortcut:
                    return true
                default:
                    return false
                }
            } ?? issues.first!
            let focus: MacroFieldFocus
            switch issue {
            case .invalidTrailing:
                focus = .trailing(macro.id)
            case .textTooLong, .emptyText:
                focus = .text(macro.id)
            case .duplicateID:
                focus = .title(macro.id)
            case .emptyShortcut, .modifierRequired, .unsupportedFunction,
                 .unsupportedModifiers, .reservedShortcut,
                 .duplicateShortcut:
                focus = .shortcut(macro.id)
            }
            reveal(id: macro.id, field: focus)
            return
        }
    }

    private func reveal(id: UUID, field: MacroFieldFocus) {
        expandedMacroID = id
        focusedField = field
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

private extension MacroFieldFocus {
    var macroID: UUID {
        switch self {
        case .title(let id), .shortcut(let id), .text(let id), .trailing(let id):
            return id
        }
    }
}

@MainActor
struct GeneralSettingsViewModel {
    private let app: AppController
    private let login: LoginItemController

    init(app: AppController, login: LoginItemController) {
        self.app = app
        self.login = login
    }

    var loginEnabled: Bool { login.isEnabled }
    var loginErrorMessage: String? { login.errorMessage }
    var accessibilityGranted: Bool { app.permissionState.accessibility }

    func setLoginEnabled(_ enabled: Bool) {
        login.setEnabledReportingError(enabled)
    }

    func requestAccessibility() { app.requestAccessibility() }
    func openAccessibilitySettings() { app.openPrivacySettings(.accessibility) }
    func refreshPermissions() {
        app.refreshPermissions(reconcileShortcuts: false)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var app: AppController
    @ObservedObject var login: LoginItemController
    let prepare: () -> Void
    @FocusState private var focusedField: MacroFieldFocus?
    @State private var showsSupportedKeyHelp = false

    var body: some View {
        VStack(spacing: 0) {
            if let warning = model.replaceWarningMessage {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top)
            }

            TabView(selection: $model.selectedSection) {
                GeneralSettingsView(model: .init(app: app, login: login))
                .tabItem { Label(SettingsSection.general.label, systemImage: "gearshape") }
                .tag(SettingsSection.general)

                macrosSection
                    .tabItem { Label(SettingsSection.macros.label, systemImage: "command") }
                    .tag(SettingsSection.macros)
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear(perform: prepare)
        .onDisappear(perform: model.clearDeletionHistory)
        .onChange(of: model.focusedField) { focusedField = $0 }
        .sheet(isPresented: $showsSupportedKeyHelp) {
            SupportedKeyHelpView()
        }
    }

    private var macrosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("매크로").font(.title2)
                    Text("단축키를 누르면 설정한 문자열과 선택적인 후속 키를 입력합니다.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("지원 키 코드") { showsSupportedKeyHelp = true }
            }
            if let message = model.saveErrorMessage {
                Text(message)
                    .foregroundStyle(.red)
            }

            List {
                ForEach($model.settings.macros) { $macro in
                    MacroCard(
                        macro: $macro,
                        model: model,
                        errors: model.errors(for: macro.id),
                        focusedField: $focusedField
                    )
                }
                .onDelete(perform: model.delete)
                .onMove(perform: model.move)
            }

            HStack {
                Button("추가", action: model.add)
                if model.canUndoDelete {
                    Text("매크로를 삭제했습니다.")
                        .foregroundStyle(.secondary)
                    Button("실행 취소", action: model.undoDelete)
                }
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

private struct SupportedKeyHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("지원 키 코드").font(.title2)
            ForEach(SupportedKeyHelp.sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(.headline)
                    Text(section.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620)
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

            Section("민감한 정보") {
                Text("비밀번호, API 키와 인증 토큰을 매크로에 저장하지 마세요.")
                    .foregroundStyle(.secondary)
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
                .focused(focusedField, equals: focusValue)

                KeyRecorder(
                    shortcut: recordedShortcut,
                    prompt: "키로 기록",
                    mode: mode == .shortcut ? .shortcut : .trailing,
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

    private var mode: TokenEditorMode {
        switch field {
        case .shortcut: return .shortcut
        case .trailing: return .trailing
        }
    }

    private var focusValue: MacroFieldFocus {
        switch field {
        case .shortcut(let id): return .shortcut(id)
        case .trailing(let id): return .trailing(id)
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

private struct MacroCard: View {
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
                .frame(minWidth: 120, idealWidth: 220)
                .accessibilityLabel(labels.title)
                .focused(focusedField, equals: .title(macro.id))
                let accessibility = model.collapsedShortcutAccessibilityPresentation(
                    for: macro.id
                )
                CollapsedShortcutBlocks(
                    tokens: model.collapsedShortcutTokens(for: macro.id),
                    accessibility: accessibility
                )
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                Spacer()
                Text(badge.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    .accessibilityLabel(badge.label)
                    .fixedSize()
                Button(role: .destructive) {
                    model.delete(id: macro.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel(labels.delete)
                Button {
                    model.expand(macro.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel(labels.expand)
                .accessibilityValue(isExpanded ? "펼쳐짐" : "접힘")
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

enum MacroActivationControlKind: Equatable {
    case switchToggle
}

struct MacroActivationToggle: View {
    static let controlKind = MacroActivationControlKind.switchToggle

    @Binding var isOn: Bool
    let accessibilityLabel: String

    var body: some View {
        Toggle("활성화", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(accessibilityLabel)
    }
}
