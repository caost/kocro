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
                Button("매크로 추가", action: model.add)
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
