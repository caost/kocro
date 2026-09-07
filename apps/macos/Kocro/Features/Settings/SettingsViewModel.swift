import AppKit
import SwiftUI

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

private extension MacroFieldFocus {
    var macroID: UUID {
        switch self {
        case .title(let id), .shortcut(let id), .text(let id), .trailing(let id):
            return id
        }
    }
}

enum MacroMoveDirection: Equatable {
    case up
    case down
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
        guard let draft = tokenDrafts[.shortcut(macro.id)],
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
            return macro.isEnabled || issue == .reservedShortcut ? issue : nil
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
        case .conflict:
            return "다른 앱 또는 macOS가 이 단축키를 사용하고 있습니다"
        case .registrationFailed:
            return "단축키를 등록하지 못했습니다"
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
