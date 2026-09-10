import Foundation
import XCTest
@testable import Kocro

@MainActor
final class MacroTransferTests: XCTestCase {
    private let codec = SettingsJSONCodec(validator: .init())

    func testExportPreservesSavedSnapshotAndDoesNotCommitEditorDrafts() throws {
        let saved = AppSettings(macros: [
            MacroDefinition(id: UUID(), title: "", isEnabled: true,
                shortcut: .init(key: .function(13), modifiers: []),
                text: "한글 👨‍👩‍👧‍👦\nCafe\u{301}", trailingKey: .enter),
            MacroDefinition(id: UUID(), title: "  제목  ", isEnabled: false,
                shortcut: .init(key: .function(14), modifiers: .shift),
                text: "둘째\n줄", trailingKey: .custom(keyCode: 0, modifiers: .shift)),
        ])
        let model = SettingsViewModel(settings: saved, validator: .init())
        let id = saved.macros[0].id
        let deleted = saved.macros[1]
        model.settings.macros[0].text = "저장 전 편집"
        model.updateTokenText("{KC_NOPE}", for: .shortcut(id))
        model.updateTokenText("{KC_BAD}", for: .trailing(deleted.id))
        model.delete(id: deleted.id)
        let before = model.settings
        let history = model.deletedMacros
        let tokenText = model.tokenDraft(for: .shortcut(id)).text
        XCTAssertTrue(model.canUndoDelete)
        var saves = 0
        model.onSave = { _ in saves += 1 }

        let document = try model.prepareExport(from: saved)

        XCTAssertNotNil(String(data: document.data, encoding: .utf8))
        XCTAssertEqual(try codec.decode(document.data), saved)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: document.data), saved)
        XCTAssertEqual(model.settings, before)
        XCTAssertEqual(model.tokenDraft(for: .shortcut(id)).text, tokenText)
        XCTAssertEqual(model.tokenDraft(for: .trailing(deleted.id)).text, "{KC_BAD}")
        XCTAssertEqual(model.deletedMacros, history)
        XCTAssertTrue(model.canUndoDelete)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(saves, 0)
        let store = JSONSettingsStore(file: MemorySettingsFile(contents: document.data), validator: .init())
        XCTAssertEqual(try store.load(), saved)

        model.undoDelete()

        XCTAssertEqual(model.settings.macros[1], deleted)
        XCTAssertEqual(model.settings.macros[0], before.macros[0])
        XCTAssertEqual(model.tokenDraft(for: .trailing(deleted.id)).text, "{KC_BAD}")
        XCTAssertFalse(model.canUndoDelete)
        XCTAssertEqual(saves, 0)
    }

    func testRepeatedImportAppendsDisabledCopiesAndPreservesEditorState() throws {
        let first = Fixtures.carbon(13)
        let deleted = Fixtures.carbon(14)
        let original = AppSettings(macros: [first, deleted])
        let model = SettingsViewModel(settings: original, validator: .init())
        model.updateTokenText("{KC_NOPE}", for: .shortcut(first.id))
        model.updateTokenText("{KC_BAD}", for: .trailing(deleted.id))
        model.settings.macros[0].title = "편집한 제목"
        model.delete(id: deleted.id)
        model.registration = [first.id: .registrationFailed]
        model.showsReplaceWarning = true
        model.saveErrorMessage = "기존 오류"
        let before = model.settings
        let history = model.deletedMacros
        var saves = 0
        model.onSave = { _ in saves += 1 }
        let data = try codec.encode(original)

        XCTAssertEqual(try model.importMacros(from: data), 2)
        XCTAssertEqual(try model.importMacros(from: data), 2)

        XCTAssertEqual(Array(model.settings.macros.prefix(1)), before.macros)
        let additions = Array(model.settings.macros.dropFirst())
        XCTAssertEqual(additions.map(\.text), [first.text, deleted.text, first.text, deleted.text])
        XCTAssertEqual(additions.map(\.shortcut), [first.shortcut, deleted.shortcut, first.shortcut, deleted.shortcut])
        XCTAssertTrue(additions.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(Set(additions.map(\.id)).count, 4)
        XCTAssertTrue(Set(additions.map(\.id)).isDisjoint(with: Set(original.macros.map(\.id))))
        for macro in additions {
            XCTAssertEqual(model.tokenDraft(for: .shortcut(macro.id)).text,
                TokenEditorDraft(value: .shortcut(macro.shortcut), mode: .shortcut).text)
            XCTAssertEqual(model.tokenDraft(for: .trailing(macro.id)).text,
                TokenEditorDraft(value: .trailing(macro.trailingKey), mode: .trailing).text)
        }
        XCTAssertEqual(model.tokenDraft(for: .shortcut(first.id)).text, "{KC_NOPE}")
        XCTAssertEqual(model.deletedMacros, history)
        XCTAssertEqual(model.registration, [first.id: .registrationFailed])
        XCTAssertEqual(model.saveErrorMessage, "기존 오류")
        XCTAssertTrue(model.showsReplaceWarning)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(saves, 0)
        model.undoDelete()
        XCTAssertEqual(model.settings.macros[1], deleted)
        XCTAssertEqual(model.tokenDraft(for: .trailing(deleted.id)).text, "{KC_BAD}")
    }

    func testEmptyImportLeavesCleanModelUnchanged() throws {
        let original = Fixtures.settings(text: "기존")
        let model = SettingsViewModel(settings: original, validator: .init())
        var saves = 0
        model.onSave = { _ in saves += 1 }

        XCTAssertEqual(try model.importMacros(from: Data("{\"macros\":[]}".utf8)), 0)
        XCTAssertEqual(model.settings, original)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(saves, 0)
    }

    func testInvalidFilesAreRejectedBeforeAnyEditorMutation() throws {
        let valid = Fixtures.carbon(13)
        var tooLong = Fixtures.carbon(14)
        tooLong.text = String(repeating: "👨🏽‍💻", count: 10_001)
        var emptyActive = Fixtures.carbon(14)
        emptyActive.text = ""
        var badTrailing = Fixtures.carbon(14)
        badTrailing.trailingKey = .custom(keyCode: nil, modifiers: [])
        let duplicateShortcut = Fixtures.carbon(13)
        var inputs = [Data("{".utf8), Data("[]".utf8)]
        for macros in [[valid, valid], [valid, tooLong], [valid, emptyActive],
                       [valid, badTrailing], [valid, duplicateShortcut]] {
            inputs.append(try JSONEncoder().encode(AppSettings(macros: macros)))
        }
        for title: Any in [NSNull(), 1, ["value": "잘못된 제목"]] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(AppSettings(macros: [valid]))) as? [String: Any])
            var macros = try XCTUnwrap(object["macros"] as? [[String: Any]])
            macros[0]["title"] = title
            object["macros"] = macros
            inputs.append(try JSONSerialization.data(withJSONObject: object))
        }
        for data in inputs {
            let model = SettingsViewModel(settings: .init(macros: [valid, Fixtures.carbon(15)]), validator: .init())
            model.updateTokenText("{KC_NOPE}", for: .shortcut(valid.id))
            model.delete(at: IndexSet(integer: 1))
            model.registration = [valid.id: .registrationFailed]
            let before = model.settings
            let history = model.deletedMacros
            let draftCount = model.tokenDrafts.count
            var saves = 0
            model.onSave = { _ in saves += 1 }

            XCTAssertThrowsError(try model.importMacros(from: data))
            XCTAssertEqual(model.settings, before)
            XCTAssertEqual(model.deletedMacros, history)
            XCTAssertEqual(model.tokenDrafts.count, draftCount)
            XCTAssertEqual(model.tokenDraft(for: .shortcut(valid.id)).text, "{KC_NOPE}")
            XCTAssertEqual(model.registration, [valid.id: .registrationFailed])
            XCTAssertEqual(saves, 0)
        }
    }

    func testImportUsesStoreMigrationsBeforeAddingCopies() throws {
        var legacy = (21...24).map { Fixtures.carbon($0) }
        legacy.append(Fixtures.macro(text: "예약 키", shortcut: .init(key: .keyCode(8), modifiers: .command)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppSettings(macros: legacy))) as? [String: Any])
        var macros = try XCTUnwrap(object["macros"] as? [[String: Any]])
        for index in macros.indices { macros[index].removeValue(forKey: "title") }
        object["macros"] = macros
        let data = try JSONSerialization.data(withJSONObject: object)
        let store = JSONSettingsStore(file: MemorySettingsFile(contents: data), validator: .init())
        let migrated = try store.load()
        let model = SettingsViewModel(settings: .init(macros: []), validator: .init())

        XCTAssertEqual(try model.importMacros(from: data), 5)
        XCTAssertEqual(model.settings.macros.map(\.title), migrated.macros.map(\.title))
        XCTAssertEqual(model.settings.macros.map(\.text), legacy.map(\.text))
        XCTAssertEqual(model.settings.macros.map(\.shortcut), migrated.macros.map(\.shortcut))
        XCTAssertTrue(model.settings.macros.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(model.settings.macros.prefix(4).allSatisfy { $0.shortcut.key == .empty })
        XCTAssertEqual(model.settings.macros.last?.shortcut, legacy.last?.shortcut)
    }

    func testImportedCopiesSaveOnlyOnExplicitSaveAndActivationUsesExistingValidation() throws {
        let original = Fixtures.settings(text: "기존")
        let model = SettingsViewModel(settings: original, validator: .init())
        var saved: AppSettings?
        model.onSave = { saved = $0 }

        try model.importMacros(from: codec.encode(original))
        XCTAssertNil(saved)
        model.save()
        XCTAssertEqual(saved, model.settings)
        XCTAssertFalse(try XCTUnwrap(saved).macros[1].isEnabled)
        model.markSaved(try XCTUnwrap(saved))
        saved = nil
        model.settings.macros[1].isEnabled = true
        model.save()
        XCTAssertNil(saved)
        XCTAssertTrue(model.errors(for: model.settings.macros[1].id).contains("활성 단축키가 중복됩니다"))
    }
}
