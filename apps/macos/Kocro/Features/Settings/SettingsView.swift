import SwiftUI

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
    @Published private(set) var isDirty = false

    let validator: SettingsValidator
    var onSave: ((AppSettings) -> Void)?

    private var hasLoadedDraft: Bool
    private var isLoadingDraft = false

    init(settings: AppSettings, validator: SettingsValidator) {
        self.settings = settings
        self.validator = validator
        hasLoadedDraft = !settings.macros.isEmpty
    }

    func add() {
        settings.macros.append(
            MacroDefinition(
                id: UUID(),
                isEnabled: false,
                shortcut: .init(key: .empty, modifiers: []),
                text: "",
                trailingKey: nil
            )
        )
    }

    func delete(at offsets: IndexSet) {
        settings.macros.remove(atOffsets: offsets)
    }

    func move(from offsets: IndexSet, to destination: Int) {
        settings.macros.move(fromOffsets: offsets, toOffset: destination)
    }

    func characterCount(for id: UUID) -> Int? {
        settings.macros.first(where: { $0.id == id })?.text.count
    }

    func errors(for id: UUID) -> [String] {
        guard let macro = settings.macros.first(where: { $0.id == id }) else {
            return ["항목을 찾을 수 없습니다"]
        }

        var errors: [String] = []
        if macro.text.count > 10_000 {
            errors.append("문자열은 10,000자 이하여야 합니다")
        }
        if macro.isEnabled && macro.text.isEmpty {
            errors.append("활성 매크로의 문자열이 비어 있습니다")
        }
        if macro.isEnabled {
            do {
                try validator.validateShortcut(macro.shortcut)
            } catch {
                errors.append("단축키를 수정하세요")
            }
        }
        if macro.isEnabled, let trailingKey = macro.trailingKey {
            do {
                try validator.validateTrailing(trailingKey)
            } catch {
                errors.append("후속 키를 수정하세요")
            }
        }
        if settings.macros.filter({ $0.id == macro.id }).count > 1 {
            errors.append("항목 ID가 중복됩니다")
        }
        if macro.isEnabled,
           let identity = macro.shortcut.registrationIdentity,
           settings.macros.filter({
               $0.isEnabled && $0.shortcut.registrationIdentity == identity
           }).count > 1 {
            errors.append("활성 단축키가 중복됩니다")
        }
        if let registrationState = registration[id], registrationState != .registered {
            errors.append(registrationMessage(registrationState))
        }
        return errors
    }

    func save() {
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
}

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    let prepare: () -> Void

    var body: some View {
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
                    MacroRow(macro: $macro, errors: model.errors(for: macro.id))
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
        .padding()
        .frame(minWidth: 760, minHeight: 560)
        .onAppear(perform: prepare)
    }
}

private struct MacroRow: View {
    @Binding var macro: MacroDefinition
    let errors: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("활성화", isOn: $macro.isEnabled)
                    .toggleStyle(.checkbox)
                KeyRecorder(shortcut: $macro.shortcut)
                    .frame(width: 150, height: 26)
                Picker("F21~F24", selection: hidFunctionBinding) {
                    Text("선택 안 함").tag(0)
                    ForEach(21...24, id: \.self) { number in
                        Text("F\(number)").tag(number)
                    }
                }
                .frame(width: 160)
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
            Text("\(macro.text.count) / 10,000")
                .font(.caption)
                .foregroundStyle(macro.text.count > 10_000 ? .red : .secondary)

            HStack {
                Picker("후속 키", selection: trailingModeBinding) {
                    ForEach(TrailingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .frame(width: 180)
                if trailingModeBinding.wrappedValue == .custom {
                    KeyRecorder(
                        shortcut: trailingShortcutBinding,
                        prompt: "후속 키 입력",
                        allowsUnmodified: true
                    )
                        .frame(width: 150, height: 26)
                }
            }

            ForEach(errors, id: \.self) { error in
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
    }

    private var hidFunctionBinding: Binding<Int> {
        Binding(
            get: {
                guard let number = macro.shortcut.functionNumber,
                      (21...24).contains(number) else { return 0 }
                return number
            },
            set: { number in
                macro.shortcut = number == 0
                    ? .init(key: .empty, modifiers: [])
                    : .init(key: .function(number), modifiers: [])
            }
        )
    }

    private var trailingModeBinding: Binding<TrailingMode> {
        Binding(
            get: { TrailingMode(macro.trailingKey) },
            set: { mode in
                switch mode {
                case .none: macro.trailingKey = nil
                case .enter: macro.trailingKey = .enter
                case .space: macro.trailingKey = .space
                case .tab: macro.trailingKey = .tab
                case .custom: macro.trailingKey = .custom(keyCode: nil, modifiers: [])
                }
            }
        )
    }

    private var trailingShortcutBinding: Binding<ShortcutDefinition> {
        Binding(
            get: {
                guard case .custom(let keyCode?, let modifiers) = macro.trailingKey else {
                    return .init(key: .empty, modifiers: [])
                }
                return .init(key: .keyCode(keyCode), modifiers: modifiers)
            },
            set: { shortcut in
                switch shortcut.key {
                case .keyCode(let keyCode):
                    macro.trailingKey = .custom(keyCode: keyCode, modifiers: shortcut.modifiers)
                case .function(let number):
                    macro.trailingKey = .custom(
                        keyCode: KeyRecorderTranslator.keyCode(forFunction: number),
                        modifiers: shortcut.modifiers
                    )
                case .empty, .letter:
                    break
                }
            }
        )
    }
}

private enum TrailingMode: String, CaseIterable, Identifiable {
    case none
    case enter
    case space
    case tab
    case custom

    var id: String { rawValue }

    init(_ trailingKey: TrailingKey?) {
        switch trailingKey {
        case nil: self = .none
        case .enter?: self = .enter
        case .space?: self = .space
        case .tab?: self = .tab
        case .custom?, .customFunction?: self = .custom
        }
    }

    var label: String {
        switch self {
        case .none: return "없음"
        case .enter: return "Enter"
        case .space: return "Space"
        case .tab: return "Tab"
        case .custom: return "사용자 지정"
        }
    }
}
