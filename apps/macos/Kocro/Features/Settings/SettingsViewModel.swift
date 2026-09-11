import AppKit
import SwiftUI

enum TokenField: Hashable {
    case shortcut(UUID)
    case step(macroID: UUID, stepID: UUID)

    var macroID: UUID {
        switch self {
        case .shortcut(let id): return id
        case .step(let id, _): return id
        }
    }

    var focus: MacroFieldFocus {
        switch self {
        case .shortcut(let id): return .shortcut(id)
        case .step(let macroID, let stepID): return .step(macroID: macroID, stepID: stepID)
        }
    }
}

struct DeletedMacro: Equatable {
    let macro: MacroDefinition
    let index: Int
}

enum MacroFieldFocus: Hashable {
    case title(UUID)
    case shortcut(UUID)
    case text(UUID)
    case step(macroID: UUID, stepID: UUID)

    var macroID: UUID {
        switch self {
        case .title(let id), .shortcut(let id), .text(let id): return id
        case .step(let id, _): return id
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
            if !isLoadingDraft { recomputeDirty() }
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
        guard let index = settings.macros.firstIndex(where: { $0.id == id }) else { return }
        deletedMacros.append(DeletedMacro(macro: settings.macros.remove(at: index), index: index))
        // Keep drafts with the undo history, but exclude them from dirty/save checks.
        if expandedMacroID == id { expandedMacroID = nil }
        if focusedField?.macroID == id { focusedField = nil }
        recomputeDirty()
    }

    func undoDelete() {
        guard let deletion = deletedMacros.popLast() else { return }
        settings.macros.insert(deletion.macro, at: min(deletion.index, settings.macros.count))
        recomputeDirty()
    }

    func clearDeletionHistory() {
        deletedMacros.removeAll()
        let fields = activeTokenFields
        tokenDrafts = tokenDrafts.filter { fields.contains($0.key) }
        recomputeDirty()
    }

    var canUndoDelete: Bool { !deletedMacros.isEmpty }
    var replaceWarningMessage: String? {
        showsReplaceWarning ? "저장하면 기존 설정 파일을 기본 설정으로 교체합니다." : nil
    }

    func expand(_ id: UUID) {
        expandedMacroID = expandedMacroID == id ? nil : id
        if expandedMacroID == nil, focusedField?.macroID == id { focusedField = nil }
    }

    func selectHeader(_ id: UUID) {
        expandedMacroID = id
    }

    func move(from offsets: IndexSet, to destination: Int) {
        settings.macros.move(fromOffsets: offsets, toOffset: destination)
    }

    @discardableResult
    func move(id: UUID, direction: MacroMoveDirection) -> Bool {
        guard let index = settings.macros.firstIndex(where: { $0.id == id }) else { return false }
        let destination = direction == .up ? index - 1 : index + 1
        guard settings.macros.indices.contains(destination) else { return false }
        settings.macros.swapAt(index, destination)
        return true
    }

    @discardableResult
    func addTextStep(macroID: UUID) -> UUID? {
        addStep(.text(""), macroID: macroID)
    }

    @discardableResult
    func addKeyStep(macroID: UUID) -> UUID? {
        addStep(.keys(.init(keyCode: 36, modifiers: [])), macroID: macroID)
    }

    @discardableResult
    func addDelayStep(macroID: UUID) -> UUID? {
        addStep(.delay(milliseconds: 500), macroID: macroID)
    }

    private func addStep(_ kind: MacroStep.Kind, macroID: UUID) -> UUID? {
        guard let index = settings.macros.firstIndex(where: { $0.id == macroID }) else { return nil }
        let step = MacroStep(kind: kind)
        settings.macros[index].steps.append(step)
        if case .keys(let combination) = kind {
            tokenDrafts[.step(macroID: macroID, stepID: step.id)] = Self.keyDraft(combination)
        }
        reveal(id: macroID, field: .step(macroID: macroID, stepID: step.id))
        recomputeDirty()
        return step.id
    }

    func deleteStep(macroID: UUID, stepID: UUID) {
        guard let index = settings.macros.firstIndex(where: { $0.id == macroID }) else { return }
        settings.macros[index].steps.removeAll { $0.id == stepID }
        tokenDrafts.removeValue(forKey: .step(macroID: macroID, stepID: stepID))
        if focusedField == .step(macroID: macroID, stepID: stepID) { focusedField = nil }
        recomputeDirty()
    }

    @discardableResult
    func moveStep(id: UUID, direction: MacroMoveDirection) -> Bool {
        guard let macroIndex = settings.macros.firstIndex(where: { macro in
            macro.steps.contains { $0.id == id }
        }), let index = settings.macros[macroIndex].steps.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let destination = direction == .up ? index - 1 : index + 1
        guard settings.macros[macroIndex].steps.indices.contains(destination) else { return false }
        settings.macros[macroIndex].steps.swapAt(index, destination)
        return true
    }

    func updateDelay(milliseconds: Int, macroID: UUID, stepID: UUID) {
        guard let macroIndex = settings.macros.firstIndex(where: { $0.id == macroID }),
              let stepIndex = settings.macros[macroIndex].steps.firstIndex(where: { $0.id == stepID }),
              case .delay = settings.macros[macroIndex].steps[stepIndex].kind else { return }
        settings.macros[macroIndex].steps[stepIndex].kind = .delay(milliseconds: milliseconds)
    }

    func tokenDraft(for field: TokenField) -> TokenEditorDraft {
        tokenDrafts[field] ?? TokenEditorDraft(value: .trailing(nil), mode: .trailing)
    }

    func updateTokenText(_ text: String, for field: TokenField) {
        guard tokenDrafts[field] != nil else { return }
        tokenDrafts[field]?.updateText(text)
        recomputeDirty()
    }

    func mutateTokenDraft(_ field: TokenField, _ body: (inout TokenEditorDraft) -> Void) {
        guard var draft = tokenDrafts[field] else { return }
        body(&draft)
        tokenDrafts[field] = draft
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
        return canonicalText.split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func collapsedShortcutAccessibilityValue(for id: UUID) -> String {
        let source = collapsedShortcutText(for: id)
        let validation = TokenShortcutCodec.validate(source, mode: .shortcut)
        guard case .shortcut(let shortcut)? = validation.value else {
            return source.trimmingCharacters(in: .whitespaces).isEmpty
                ? "설정 안 됨" : "유효하지 않은 단축키, \(source)"
        }
        return shortcut.tokens.isEmpty ? "설정 안 됨" : shortcut.tokens.joined(separator: ", ")
    }

    func collapsedShortcutAccessibilityPresentation(for id: UUID) -> CollapsedShortcutAccessibilityPresentation {
        let label = settings.macros.first(where: { $0.id == id })
            .map { MacroRecorderAccessibilityLabels($0).shortcut } ?? "실행 단축키"
        return .init(label: label, value: collapsedShortcutAccessibilityValue(for: id))
    }

    func badge(for id: UUID) -> MacroStatusBadge {
        guard let macro = settings.macros.first(where: { $0.id == id }) else { return .registrationFailed }
        let savedMacro = savedSettings.macros.first(where: { $0.id == id })
        let fields = activeTokenFields
        let tokenDirty = tokenDrafts.contains { field, draft in
            field.macroID == id && fields.contains(field) && draft.isDirty
        }
        return .resolve(isEnabled: macro.isEnabled, isDirty: savedMacro != macro || tokenDirty,
                        registration: registration[id])
    }

    @discardableResult
    func prepareTokenEditsForSave() -> Bool {
        // Commit into a copy so a later invalid draft cannot partially update settings.
        var candidate = settings
        for index in candidate.macros.indices {
            let id = candidate.macros[index].id
            let shortcutField = TokenField.shortcut(id)
            guard commitTokenDraft(shortcutField),
                  case .shortcut(let shortcut)? = tokenDrafts[shortcutField]?.value else {
                reveal(id: id, field: .shortcut(id))
                recomputeDirty()
                return false
            }
            candidate.macros[index].shortcut = shortcut
            for stepIndex in candidate.macros[index].steps.indices {
                guard case .keys = candidate.macros[index].steps[stepIndex].kind else { continue }
                let stepID = candidate.macros[index].steps[stepIndex].id
                let field = TokenField.step(macroID: id, stepID: stepID)
                guard commitTokenDraft(field),
                      case .trailing(let trailing)? = tokenDrafts[field]?.value,
                      let combination = KeyCombination(trailingKey: trailing) else {
                    reveal(id: id, field: field.focus)
                    saveErrorMessage = "키 조합 단계의 기준 키를 입력하세요"
                    recomputeDirty()
                    return false
                }
                candidate.macros[index].steps[stepIndex].kind = .keys(combination)
            }
        }
        settings = candidate
        recomputeDirty()
        return true
    }

    func characterCount(for id: UUID) -> Int? {
        settings.macros.first(where: { $0.id == id })?.combinedTextCount
    }

    func errors(for id: UUID) -> [String] {
        guard let macro = settings.macros.first(where: { $0.id == id }) else {
            return ["항목을 찾을 수 없습니다"]
        }
        var errors = validator.issues(for: macro, in: settings).map(message(for:))
        if let issue = currentShortcutIssue(for: macro) {
            let text = message(for: issue)
            if !errors.contains(text) { errors.append(text) }
        }
        for step in macro.steps {
            guard case .keys = step.kind,
                  let draft = tokenDrafts[.step(macroID: id, stepID: step.id)] else { continue }
            if case .trailing(nil)? = TokenShortcutCodec.validate(draft.text, mode: .trailing).value {
                let text = "키 조합 단계의 기준 키를 입력하세요"
                if !errors.contains(text) { errors.append(text) }
            }
        }
        if let state = registration[id], state != .registered { errors.append(registrationMessage(state)) }
        return errors
    }

    private func currentShortcutIssue(for macro: MacroDefinition) -> ValidationError? {
        guard let draft = tokenDrafts[.shortcut(macro.id)],
              case .shortcut(let shortcut)? = TokenShortcutCodec.validate(draft.text, mode: .shortcut).value else {
            return nil
        }
        do {
            try validator.validateShortcut(shortcut)
            return nil
        } catch let issue as ValidationError {
            return macro.isEnabled || issue == .reservedShortcut ? issue : nil
        } catch { return nil }
    }

    private func message(for issue: ValidationError) -> String {
        switch issue {
        case .duplicateID: return "항목 ID가 중복됩니다"
        case .textTooLong: return "문자열은 \(MacroDefinition.maximumTextCountText)자 이하여야 합니다"
        case .emptyText: return "활성 매크로의 실행 순서가 비어 있습니다"
        case .emptyShortcut, .modifierRequired, .unsupportedFunction, .unsupportedModifiers:
            return "단축키를 수정하세요"
        case .reservedShortcut: return "이미 사용 중인 단축키입니다"
        case .duplicateShortcut: return "활성 단축키가 중복됩니다"
        case .invalidTrailing, .invalidKeyCombination: return "키 조합을 수정하세요"
        case .invalidDelay: return "딜레이는 0~60,000ms의 정수여야 합니다"
        }
    }

    func save() {
        saveErrorMessage = nil
        guard prepareTokenEditsForSave() else {
            if saveErrorMessage == nil { saveErrorMessage = "표시된 토큰 오류를 수정하세요" }
            return
        }
        do { _ = try validator.validate(settings) }
        catch {
            isDirty = true
            saveErrorMessage = "표시된 항목을 수정한 뒤 다시 저장하세요"
            revealFirstValidationIssue()
            return
        }
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
        case .registered: return ""
        case .conflict: return "다른 앱 또는 macOS가 이 단축키를 사용하고 있습니다"
        case .registrationFailed: return "단축키를 등록하지 못했습니다"
        }
    }

    private func commitTokenDraft(_ field: TokenField) -> Bool {
        guard var draft = tokenDrafts[field] else { return false }
        let valid = draft.commit()
        tokenDrafts[field] = draft
        return valid
    }

    private var activeTokenFields: Set<TokenField> {
        var fields = Set<TokenField>()
        for macro in settings.macros {
            fields.insert(.shortcut(macro.id))
            for step in macro.steps {
                if case .keys = step.kind { fields.insert(.step(macroID: macro.id, stepID: step.id)) }
            }
        }
        return fields
    }

    private func recomputeDirty() {
        let fields = activeTokenFields
        isDirty = settings != savedSettings || tokenDrafts.contains { fields.contains($0.key) && $0.value.isDirty }
    }

    private func revealFirstValidationIssue() {
        for macro in settings.macros {
            let issues = validator.issues(for: macro, in: settings)
            guard !issues.isEmpty else { continue }
            let issue = issues.first { issue in
                switch issue {
                case .emptyShortcut, .modifierRequired, .unsupportedFunction, .unsupportedModifiers,
                     .reservedShortcut, .duplicateShortcut: return true
                default: return false
                }
            } ?? issues[0]
            let focus: MacroFieldFocus
            switch issue {
            case .emptyShortcut, .modifierRequired, .unsupportedFunction, .unsupportedModifiers,
                 .reservedShortcut, .duplicateShortcut:
                focus = .shortcut(macro.id)
            case .duplicateID:
                focus = .title(macro.id)
            default:
                let step = macro.steps.first { step in
                    switch (issue, step.kind) {
                    case (.invalidDelay, .delay(let ms)): return !MacroStep.delayRange.contains(ms)
                    case (.invalidKeyCombination, .keys(let keys)): return !keys.isValid
                    case (.invalidTrailing, .keys): return true
                    case (.textTooLong, .text), (.emptyText, .text): return true
                    default: return false
                    }
                } ?? macro.steps.first
                focus = step.map { .step(macroID: macro.id, stepID: $0.id) } ?? .text(macro.id)
            }
            reveal(id: macro.id, field: focus)
            return
        }
    }

    private func reveal(id: UUID, field: MacroFieldFocus) {
        expandedMacroID = id
        focusedField = field
    }

    private static func makeTokenDrafts(for settings: AppSettings) -> [TokenField: TokenEditorDraft] {
        var drafts: [TokenField: TokenEditorDraft] = [:]
        for macro in settings.macros {
            drafts[.shortcut(macro.id)] = shortcutDraft(for: macro)
            for step in macro.steps {
                if case .keys(let combination) = step.kind {
                    drafts[.step(macroID: macro.id, stepID: step.id)] = keyDraft(combination)
                }
            }
        }
        return drafts
    }

    private static func shortcutDraft(for macro: MacroDefinition) -> TokenEditorDraft {
        TokenEditorDraft(value: .shortcut(macro.shortcut), mode: .shortcut)
    }

    private static func keyDraft(_ combination: KeyCombination) -> TokenEditorDraft {
        TokenEditorDraft(value: .trailing(combination.trailingKey), mode: .trailing)
    }
}
