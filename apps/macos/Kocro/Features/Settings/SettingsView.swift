import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showsImporter = false
    @State private var showsExporter = false
    @State private var exportDocument: MacroTransferDocument?
    @State private var transferMessage: String?
    @State private var transferFailed = false

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
                GeneralSettingsView(
                    model: .init(
                        app: app,
                        login: login,
                        beginMacroImport: beginImport,
                        beginMacroExport: beginExport
                    ),
                    transferMessage: transferMessage,
                    transferFailed: transferFailed
                )
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
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: completeImport
        )
        .fileExporter(
            isPresented: $showsExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Kocro-macros.json",
            onCompletion: completeExport
        )
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

    private func beginImport() {
        transferMessage = nil
        showsImporter = true
    }

    private func beginExport() {
        transferMessage = nil
        do {
            exportDocument = try model.prepareExport(from: app.savedSettings)
            showsExporter = true
        } catch {
            showTransferError(error, message: "매크로 내보내기를 준비하지 못했습니다.")
        }
    }

    private func completeImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }
            let count = try model.importMacros(from: Data(contentsOf: url))
            transferFailed = false
            transferMessage = count == 0
                ? "파일에 매크로가 없어 변경된 항목이 없습니다."
                : "매크로 \(count)개를 목록 끝에 비활성 상태로 추가했습니다. 적용하려면 저장하세요."
        } catch {
            showTransferError(error, message: "매크로를 가져오지 못했습니다. JSON 파일과 매크로 내용을 확인하세요.")
        }
    }

    private func completeExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            transferFailed = false
            transferMessage = "매크로를 파일로 내보냈습니다."
        case .failure(let error):
            showTransferError(error, message: "매크로 파일을 저장하지 못했습니다. 저장 위치와 권한을 확인하세요.")
        }
    }

    private func showTransferError(_ error: Error, message: String) {
        let cocoaError = error as NSError
        guard cocoaError.domain != NSCocoaErrorDomain
            || cocoaError.code != CocoaError.userCancelled.rawValue else { return }
        transferFailed = true
        transferMessage = message
    }
}
