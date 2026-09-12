import AppKit
import XCTest
@testable import Kocro

@MainActor
final class AppControllerTests: XCTestCase {
    func testSettingsWindowActivationIsIdempotentAndSupportsReopening() {
        let application = ActivationApplicationSpy()
        let lifecycle = SettingsWindowActivationController(application: application)
        lifecycle.windowDidOpen()
        lifecycle.windowDidOpen()
        XCTAssertEqual(application.policyChanges, [.regular])
        XCTAssertEqual(application.activateCount, 1)
        lifecycle.windowDidClose()
        lifecycle.windowDidClose()
        XCTAssertEqual(application.policyChanges, [.regular, .accessory])
        lifecycle.windowDidOpen()
        lifecycle.windowDidClose()
        XCTAssertEqual(application.policyChanges, [.regular, .accessory, .regular, .accessory])
        XCTAssertEqual(application.activateCount, 2)
    }

    func testBadLoadDisablesRuntimeAndOnlyShowsReplacementWarningWhenSettingsOpen() {
        let store = StoreSpy(loadResult: .failure(StoreError.invalidFile))
        let shortcuts = ShortcutSpy()
        let app = makeApp(store: store, shortcuts: shortcuts)
        app.start()
        XCTAssertEqual(app.overallStatus, .settingsError)
        XCTAssertTrue(app.runtime.macros.isEmpty)
        XCTAssertTrue(app.draft.macros.isEmpty)
        XCTAssertTrue(app.savedSettings.macros.isEmpty)
        XCTAssertTrue(app.registration.isEmpty)
        XCTAssertEqual(shortcuts.replaceCalls, [[]])
        XCTAssertFalse(app.showsReplaceWarning)
        app.prepareSettingsDraft()
        XCTAssertEqual(app.draft.macros.count, 8)
        XCTAssertTrue(app.savedSettings.macros.isEmpty)
        XCTAssertTrue(app.showsReplaceWarning)
    }

    func testSuccessfulLoadInstallsOnlyRegisteredMacrosAsExecutionSnapshots() throws {
        let registered = Fixtures.macro(text: "registered")
        let failed = Fixtures.macro(text: "must not run", shortcut: .init(key: .function(14), modifiers: []))
        let settings = AppSettings(macros: [registered, failed])
        let shortcuts = ShortcutSpy(states: [registered.id: .registered, failed.id: .registrationFailed])
        let queue = QueueSpy()
        let app = makeApp(store: StoreSpy(loadResult: .success(settings)), shortcuts: shortcuts, queue: queue)
        app.start()
        shortcuts.trigger(registered.id)
        shortcuts.trigger(failed.id)
        XCTAssertEqual(app.runtime, settings)
        XCTAssertEqual(app.draft, settings)
        XCTAssertEqual(app.savedSettings, settings)
        XCTAssertEqual(try exportedSettings(from: app), settings)
        XCTAssertEqual(queue.requests.map(\.steps), [registered.steps])
        XCTAssertEqual(queue.rejections.map(\.kind), [.missingDefinition])
        XCTAssertEqual(app.overallStatus, .ready)
    }

    func testFailedSaveKeepsOldRuntimeRegistrationAndTriggerContent() throws {
        let old = Fixtures.settings(text: "old")
        let store = StoreSpy(loadResult: .success(old))
        let shortcuts = ShortcutSpy()
        let queue = QueueSpy()
        let app = makeApp(store: store, shortcuts: shortcuts, queue: queue)
        app.start()
        let new = Fixtures.settings(text: "new")
        app.draft = new
        store.saveError = StoreError.io
        app.save()
        shortcuts.trigger(old.macros[0].id)
        XCTAssertEqual(app.runtime, old)
        XCTAssertEqual(app.savedSettings, old)
        XCTAssertEqual(try exportedSettings(from: app), old)
        XCTAssertTrue(store.savedValues.isEmpty)
        XCTAssertEqual(shortcuts.prepareCalls, [old, new])
        XCTAssertEqual(shortcuts.commitCount, 1)
        XCTAssertEqual(shortcuts.cancelCount, 1)
        XCTAssertEqual(queue.requests.map(\.steps), [old.macros[0].steps])
        XCTAssertNotNil(app.saveError)
    }

    func testSuccessfulSavePersistsBeforeReplacingRuntimeAndRegistration() throws {
        let old = Fixtures.settings(text: "old")
        let new = AppSettings(macros: [old.macros[0].withText("new")])
        let store = StoreSpy(loadResult: .success(old))
        let shortcuts = ShortcutSpy()
        let app = makeApp(store: store, shortcuts: shortcuts)
        app.start()
        app.draft = new
        store.onSave = {
            XCTAssertEqual(app.runtime, old)
            XCTAssertEqual(app.savedSettings, old)
            XCTAssertEqual(shortcuts.prepareCalls, [old, new])
            XCTAssertEqual(shortcuts.commitCount, 1)
        }
        app.save()
        XCTAssertEqual(store.savedValues, [new])
        XCTAssertEqual(app.runtime, new)
        XCTAssertEqual(app.savedSettings, new)
        XCTAssertEqual(try exportedSettings(from: app), new)
        XCTAssertEqual(shortcuts.prepareCalls, [old, new])
        XCTAssertEqual(shortcuts.commitCount, 2)
        XCTAssertNil(app.saveError)
    }

    func testCarbonCollisionPersistsDisabledCandidateBeforeCommittingOwnership() throws {
        let old = Fixtures.settings(text: "old")
        let successful = Fixtures.carbon(13)
        let conflicted = Fixtures.carbon(14)
        let edited = AppSettings(macros: [successful, conflicted])
        var normalized = edited
        normalized.macros[1].isEnabled = false
        let store = StoreSpy(loadResult: .success(old))
        let shortcuts = ShortcutSpy()
        let queue = QueueSpy()
        let app = makeApp(store: store, shortcuts: shortcuts, queue: queue)
        app.start()
        app.draft = edited
        shortcuts.states = [successful.id: .registered, conflicted.id: .registrationFailed]
        shortcuts.nextCandidateSettings = normalized
        store.onSave = {
            XCTAssertEqual(app.runtime, old)
            XCTAssertEqual(app.savedSettings, old)
            shortcuts.trigger(old.macros[0].id)
            XCTAssertEqual(queue.requests.map(\.steps), [old.macros[0].steps])
            XCTAssertEqual(shortcuts.commitCount, 1)
        }
        app.save()
        XCTAssertEqual(store.savedValues, [normalized])
        XCTAssertEqual(app.savedSettings, normalized)
        XCTAssertEqual(try exportedSettings(from: app), normalized)
        XCTAssertEqual(app.runtime, normalized)
        XCTAssertEqual(app.draft, normalized)
        XCTAssertEqual(app.registration[successful.id], .registered)
        XCTAssertEqual(app.registration[conflicted.id], .registrationFailed)
        XCTAssertEqual(shortcuts.commitCount, 2)
    }

    func testCandidateSaveFailureCancelsOnceAndPreservesRuntimeRoutesSnapshotAndDraft() {
        let old = Fixtures.settings(text: "old")
        let edited = AppSettings(macros: [old.macros[0].withText("edited")])
        let store = StoreSpy(loadResult: .success(old))
        let shortcuts = ShortcutSpy()
        let queue = QueueSpy()
        let app = makeApp(store: store, shortcuts: shortcuts, queue: queue)
        app.start()
        app.draft = edited
        store.failOnce(StoreError.io)
        store.onSave = {
            XCTAssertEqual(app.runtime, old)
            shortcuts.trigger(old.macros[0].id)
            XCTAssertEqual(queue.requests.map(\.steps), [old.macros[0].steps])
        }
        app.save()
        shortcuts.trigger(old.macros[0].id)
        XCTAssertEqual(shortcuts.cancelCount, 1)
        XCTAssertEqual(shortcuts.commitCount, 1)
        XCTAssertEqual(app.runtime, old)
        XCTAssertEqual(app.draft, edited)
        XCTAssertEqual(queue.requests.map(\.steps), [old.macros[0].steps, old.macros[0].steps])
        XCTAssertNotNil(app.saveError)
    }

    func testLaterSaveReplacesPreviousCollisionRegistrationMap() {
        let old = Fixtures.settings(text: "old")
        let first = Fixtures.carbon(13)
        let conflicted = Fixtures.carbon(14)
        let store = StoreSpy(loadResult: .success(old))
        let shortcuts = ShortcutSpy(states: [first.id: .registered, conflicted.id: .registrationFailed])
        let app = makeApp(store: store, shortcuts: shortcuts)
        app.start()
        app.draft = .init(macros: [first, conflicted])
        var normalized = app.draft
        normalized.macros[1].isEnabled = false
        shortcuts.nextCandidateSettings = normalized
        app.save()
        XCTAssertEqual(app.registration[conflicted.id], .registrationFailed)
        let replacement = Fixtures.carbon(15)
        app.draft = .init(macros: [first, replacement])
        shortcuts.states = [first.id: .registered, replacement.id: .registered]
        shortcuts.nextCandidateSettings = app.draft
        app.save()
        XCTAssertEqual(app.registration, [first.id: .registered, replacement.id: .registered])
    }

    func testPermissionRefreshKeepsCollisionErrorUntilNextSave() {
        let successful = Fixtures.carbon(13)
        let conflicted = Fixtures.carbon(14)
        let store = StoreSpy(loadResult: .success(.init(macros: [])))
        let shortcuts = ShortcutSpy()
        let app = makeApp(store: store, shortcuts: shortcuts)
        app.start()
        app.draft = .init(macros: [successful, conflicted])
        var normalized = app.draft
        normalized.macros[1].isEnabled = false
        shortcuts.states = [successful.id: .registered, conflicted.id: .conflict]
        shortcuts.nextCandidateSettings = normalized
        app.save()
        shortcuts.states = [:]
        app.refreshPermissions()
        XCTAssertEqual(app.registration[conflicted.id], .conflict)
    }

    func testLoadCollisionKeepsPersistedSettingsEnabledAndRefreshRetriesWithoutSaving() {
        let macro = Fixtures.carbon(13)
        let settings = AppSettings(macros: [macro])
        let store = StoreSpy(loadResult: .success(settings))
        let carbon = CarbonSpy(failingRegistration: 1)
        let coordinator = ShortcutCoordinator(carbon: carbon)
        let app = AppController(store: store, shortcuts: coordinator, permissions: PermissionSpy(), queue: QueueSpy())
        app.start()
        XCTAssertEqual(app.runtime, settings)
        XCTAssertEqual(app.draft, settings)
        XCTAssertTrue(app.runtime.macros[0].isEnabled)
        XCTAssertEqual(app.registration[macro.id], .registrationFailed)
        XCTAssertTrue(store.savedValues.isEmpty)
        carbon.failingRegistration = nil
        app.refreshPermissions()
        XCTAssertEqual(app.runtime, settings)
        XCTAssertEqual(app.draft, settings)
        XCTAssertEqual(app.registration[macro.id], .registered)
        XCTAssertEqual(carbon.registrations.count, 2)
        XCTAssertTrue(store.savedValues.isEmpty)
    }

    func testRealCoordinatorKeepsExistingRouteAndSnapshotDuringSuccessfulPersistence() {
        let old = Fixtures.carbon(13)
        let replacement = Fixtures.macro(id: old.id, text: "new", shortcut: .init(key: .function(14), modifiers: []))
        let store = StoreSpy(loadResult: .success(.init(macros: [old])))
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(carbon: carbon)
        let queue = QueueSpy()
        let app = AppController(store: store, shortcuts: coordinator, permissions: PermissionSpy(), queue: queue)
        app.start()
        let existingID = carbon.registrations[0].id
        app.draft = .init(macros: [replacement])
        store.onSave = {
            XCTAssertEqual(app.runtime.macros[0].steps, old.steps)
            carbon.send(id: existingID)
            XCTAssertEqual(queue.requests.map(\.steps), [old.steps])
        }
        app.save()
        let replacementID = carbon.registrations[1].id
        carbon.send(id: replacementID)
        XCTAssertEqual(queue.requests.map(\.steps), [old.steps, replacement.steps])
        XCTAssertEqual(app.runtime.macros[0].steps, replacement.steps)
    }

    func testRealCoordinatorCancelsUnroutedProvisionalIDWhenPersistenceFails() {
        let old = Fixtures.carbon(13)
        let replacement = Fixtures.macro(id: old.id, text: "new", shortcut: .init(key: .function(14), modifiers: []))
        let store = StoreSpy(loadResult: .success(.init(macros: [old])))
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(carbon: carbon)
        let queue = QueueSpy()
        let app = AppController(store: store, shortcuts: coordinator, permissions: PermissionSpy(), queue: queue)
        app.start()
        let existingID = carbon.registrations[0].id
        app.draft = .init(macros: [replacement])
        store.failOnce(StoreError.io)
        store.onSave = {
            let provisionalID = carbon.registrations[1].id
            carbon.send(id: existingID)
            carbon.send(id: provisionalID)
            XCTAssertEqual(queue.requests.map(\.steps), [old.steps])
        }
        app.save()
        let provisionalID = carbon.registrations[1].id
        carbon.send(id: existingID)
        carbon.send(id: provisionalID)
        XCTAssertEqual(queue.requests.map(\.steps), [old.steps, old.steps])
        XCTAssertEqual(carbon.unregisteredIDs, [provisionalID])
        XCTAssertEqual(app.runtime.macros[0].steps, old.steps)
        XCTAssertEqual(app.draft.macros[0].steps, replacement.steps)
        XCTAssertNotNil(app.saveError)
    }

    func testSupersededCandidateAfterPersistenceDoesNotPublishRuntimeOrDraft() throws {
        let old = AppSettings(macros: [])
        let edited = AppSettings(macros: [Fixtures.carbon(13)])
        let store = StoreSpy(loadResult: .success(old))
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(carbon: carbon)
        let app = AppController(store: store, shortcuts: coordinator, permissions: PermissionSpy(), queue: QueueSpy())
        app.start()
        app.draft = edited
        store.onSave = {
            let superseding = coordinator.prepareReplacement(with: .init(macros: [Fixtures.carbon(14)]))
            coordinator.cancel(superseding)
        }
        app.save()
        XCTAssertEqual(store.savedValues, [edited])
        XCTAssertEqual(app.savedSettings, edited)
        XCTAssertEqual(try exportedSettings(from: app), edited)
        XCTAssertEqual(app.runtime, old)
        XCTAssertEqual(app.draft, edited)
        XCTAssertNotNil(app.saveError)
    }

    func testLoadCommitFailureKeepsLoadedSettingsForExport() throws {
        let loaded = Fixtures.settings(text: "loaded")
        let store = StoreSpy(loadResult: .success(loaded))
        let app = AppController(
            store: store,
            shortcuts: RejectingCommitCoordinator(),
            permissions: PermissionSpy(),
            queue: QueueSpy()
        )

        app.start()

        XCTAssertNotNil(app.loadError)
        XCTAssertTrue(app.runtime.macros.isEmpty)
        XCTAssertTrue(app.draft.macros.isEmpty)
        XCTAssertTrue(app.registration.isEmpty)
        XCTAssertEqual(app.savedSettings, loaded)
        XCTAssertEqual(try exportedSettings(from: app), loaded)
        XCTAssertTrue(store.savedValues.isEmpty)

        app.prepareSettingsDraft()

        XCTAssertTrue(app.showsReplaceWarning)
        XCTAssertEqual(app.savedSettings, loaded)
        XCTAssertEqual(try exportedSettings(from: app), loaded)
        XCTAssertTrue(store.savedValues.isEmpty)
    }

    func testValidationFailurePreservesSavedSettingsAndExport() throws {
        let loaded = Fixtures.settings(text: "loaded")
        let store = StoreSpy(loadResult: .success(loaded))
        let shortcuts = ShortcutSpy()
        let app = makeApp(store: store, shortcuts: shortcuts)
        app.start()
        app.draft.macros[0] = app.draft.macros[0].withText("")

        app.save()

        XCTAssertNotNil(app.saveError)
        XCTAssertEqual(app.savedSettings, loaded)
        XCTAssertEqual(try exportedSettings(from: app), loaded)
        XCTAssertTrue(store.savedValues.isEmpty)
        XCTAssertEqual(shortcuts.prepareCalls, [loaded])
    }

    func testTriggerCopiesCompleteSequenceBeforeLaterSettingsReplacement() {
        let old = MacroDefinition(id: UUID(), isEnabled: true,
            shortcut: .init(key: .function(13), modifiers: []), steps: [
                .init(kind: .keys(.init(keyCode: 8, modifiers: .command))),
                .init(kind: .delay(milliseconds: 500)),
                .init(kind: .text("old")),
                .init(kind: .keys(.init(keyCode: 9, modifiers: [.command, .shift])))])
        let queue = QueueSpy()
        let shortcuts = ShortcutSpy()
        let app = makeApp(store: StoreSpy(loadResult: .success(.init(macros: [old]))), shortcuts: shortcuts, queue: queue)
        app.start()
        shortcuts.trigger(old.id)
        app.draft.macros[0].steps.reverse()
        app.draft.macros[0].steps[2].kind = .delay(milliseconds: 25)
        app.draft.macros[0] = app.draft.macros[0].withText("new")
        let replacement = app.draft.macros[0]
        app.save()
        shortcuts.trigger(old.id)
        XCTAssertEqual(queue.requests.map(\.steps), [old.steps, replacement.steps])
        XCTAssertEqual(queue.requests.first?.steps.map(\.id), old.steps.map(\.id))
    }

    func testTriggerCopiesLegacyTextAndTrailingKeyAsSteps() {
        let old = MacroDefinition(id: UUID(), isEnabled: true,
            shortcut: .init(key: .function(13), modifiers: []), text: "old", trailingKey: .space)
        let queue = QueueSpy()
        let shortcuts = ShortcutSpy()
        let app = makeApp(store: StoreSpy(loadResult: .success(.init(macros: [old]))), shortcuts: shortcuts, queue: queue)
        app.start()
        shortcuts.trigger(old.id)
        app.draft.macros[0].steps = [.init(kind: .text("new")), .init(kind: .keys(.init(keyCode: 36, modifiers: [])))]
        app.save()
        XCTAssertEqual(queue.requests.first?.steps, old.steps)
        XCTAssertEqual(queue.requests.first?.steps.map(\.kind), [.text("old"), .keys(.init(keyCode: 49, modifiers: []))])
    }

    func testKeyOnlySequenceRunsButNonEmittingSequencesAreRejected() {
        let sequences: [[MacroStep]] = [
            [], [.init(kind: .text(""))], [.init(kind: .delay(milliseconds: 500))],
            [.init(kind: .keys(.init(keyCode: 8, modifiers: .command))),
             .init(kind: .delay(milliseconds: 500)),
             .init(kind: .keys(.init(keyCode: 9, modifiers: .command)))]]
        for steps in sequences {
            let macro = MacroDefinition(id: UUID(), isEnabled: true,
                shortcut: .init(key: .function(13), modifiers: []), steps: steps)
            let queue = QueueSpy()
            let shortcuts = ShortcutSpy()
            let app = makeApp(store: StoreSpy(loadResult: .success(.init(macros: [macro]))), shortcuts: shortcuts, queue: queue)
            app.start()
            shortcuts.trigger(macro.id)
            if steps.contains(where: \.isEmitting) {
                XCTAssertEqual(queue.requests.map(\.steps), [steps])
                XCTAssertTrue(queue.rejections.isEmpty)
            } else {
                XCTAssertTrue(queue.requests.isEmpty)
                XCTAssertEqual(queue.rejections.map(\.kind), [.missingDefinition])
            }
        }
    }

    func testTriggerChecksCurrentAccessibilityInsteadOfCachedPermissionState() {
        let value = Fixtures.settings(text: "secret")
        let permissions = PermissionSpy(state: .init(accessibility: true), currentAccessibility: false)
        let queue = QueueSpy()
        let shortcuts = ShortcutSpy()
        let app = makeApp(store: StoreSpy(loadResult: .success(value)), shortcuts: shortcuts, permissions: permissions, queue: queue)
        app.start()
        shortcuts.trigger(value.macros[0].id)
        XCTAssertTrue(queue.requests.isEmpty)
        XCTAssertEqual(queue.rejections.map(\.kind), [.accessibilityRequired])
        XCTAssertEqual(permissions.currentAccessibilityChecks, 1)
    }

    func testRefreshPermissionsReconcilesRegistrationWithAccessibilityOnly() {
        let value = AppSettings(macros: [Fixtures.carbon(13)])
        let permissions = PermissionSpy(state: .init(accessibility: true), currentAccessibility: true)
        let shortcuts = ShortcutSpy(states: [value.macros[0].id: .registrationFailed])
        let app = makeApp(store: StoreSpy(loadResult: .success(value)), shortcuts: shortcuts, permissions: permissions)
        app.start()
        XCTAssertEqual(app.overallStatus, .ready)
        shortcuts.states = [value.macros[0].id: .registered]
        permissions.refreshedState = .init(accessibility: true)
        app.refreshPermissions()
        XCTAssertEqual(shortcuts.replaceCalls, [value.macros, value.macros])
        XCTAssertEqual(app.registration[value.macros[0].id], .registered)
        XCTAssertEqual(app.overallStatus, .ready)
    }

    func testQueueCallbacksUpdatePublishedStateOnMainActor() async {
        let queue = QueueSpy()
        let app = makeApp(queue: queue)
        let result = ExecutionResult(id: UUID(), shortcut: "F13", kind: .postingRequested, date: Date())
        await Task.detached {
            queue.emitIdle(false)
            queue.emitResult(result)
            queue.emitIdle(true)
        }.value
        await Task.yield()
        XCTAssertEqual(app.lastResult, result)
        XCTAssertTrue(app.queueIsIdle)
    }

    func testBackgroundTriggerCopiesSnapshotSynchronously() async {
        let value = Fixtures.settings(text: "background value")
        let queue = QueueSpy()
        let shortcuts = ShortcutSpy()
        let app = makeApp(store: StoreSpy(loadResult: .success(value)), shortcuts: shortcuts, queue: queue)
        app.start()
        await Task.detached { shortcuts.trigger(value.macros[0].id) }.value
        XCTAssertEqual(queue.requests.map(\.steps), [value.macros[0].steps])
    }

    func testMeasurementModeIsExposedAndProgressUpdatesPublishedCount() {
        let app = AppController(store: StoreSpy(loadResult: .success(.init(macros: []))),
            shortcuts: ShortcutSpy(), permissions: PermissionSpy(), queue: QueueSpy(), measurementEnabled: true)
        app.updateMeasurementCount(37)
        XCTAssertTrue(app.measurementEnabled)
        XCTAssertEqual(app.measurementCount, 37)
    }

    private func exportedSettings(from app: AppController) throws -> AppSettings {
        let model = SettingsViewModel(settings: app.draft, validator: .init())
        let document = try model.prepareExport(from: app.savedSettings)
        return try JSONDecoder().decode(AppSettings.self, from: document.data)
    }

    private func makeApp(
        store: StoreSpy = StoreSpy(loadResult: .success(.init(macros: []))),
        shortcuts: ShortcutSpy = ShortcutSpy(),
        permissions: PermissionSpy = PermissionSpy(),
        queue: QueueSpy = QueueSpy()
    ) -> AppController {
        AppController(store: store, shortcuts: shortcuts, permissions: permissions, queue: queue)
    }
}

private final class RejectingCommitCoordinator: ShortcutCoordinating {
    var onTrigger: ((UUID, ContinuousClock.Instant) -> Void)?

    @MainActor
    func prepareReplacement(with settings: AppSettings) -> any ShortcutReplacementCandidate {
        ShortcutSpy().prepareReplacement(with: settings)
    }

    @MainActor
    func commit(
        _ candidate: any ShortcutReplacementCandidate,
        installSnapshots: ([UUID: RegistrationState]) -> Void
    ) -> [UUID: RegistrationState]? {
        nil
    }

    @MainActor
    func cancel(_ candidate: any ShortcutReplacementCandidate) {}

    @MainActor
    func shutdown() {}
}

private final class ActivationApplicationSpy: ApplicationActivating {
    private(set) var policyChanges: [NSApplication.ActivationPolicy] = []
    private(set) var activateCount = 0
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        policyChanges.append(policy)
        return true
    }
    func activate() { activateCount += 1 }
}
