import XCTest
@testable import Kocro

@MainActor
final class AppControllerTests: XCTestCase {
    func testBadLoadDisablesRuntimeAndOnlyShowsReplacementWarningWhenSettingsOpen() {
        let store = StoreSpy(loadResult: .failure(StoreError.invalidFile))
        let shortcuts = ShortcutSpy()
        let app = makeApp(store: store, shortcuts: shortcuts)

        app.start()

        XCTAssertEqual(app.overallStatus, .settingsError)
        XCTAssertTrue(app.runtime.macros.isEmpty)
        XCTAssertTrue(app.draft.macros.isEmpty)
        XCTAssertTrue(app.registration.isEmpty)
        XCTAssertEqual(shortcuts.replaceCalls, [[]])
        XCTAssertFalse(app.showsReplaceWarning)

        app.prepareSettingsDraft()

        XCTAssertEqual(app.draft.macros.count, 12)
        XCTAssertTrue(app.showsReplaceWarning)
    }

    func testSuccessfulLoadInstallsOnlyRegisteredMacrosAsExecutionSnapshots() {
        let registered = Fixtures.macro(text: "registered")
        let failed = Fixtures.macro(
            text: "must not run",
            shortcut: .init(key: .function(14), modifiers: [])
        )
        let settings = AppSettings(macros: [registered, failed])
        let shortcuts = ShortcutSpy(states: [
            registered.id: .registered,
            failed.id: .registrationFailed,
        ])
        let queue = QueueSpy()
        let app = makeApp(
            store: StoreSpy(loadResult: .success(settings)),
            shortcuts: shortcuts,
            queue: queue
        )

        app.start()
        shortcuts.trigger(registered.id)
        shortcuts.trigger(failed.id)

        XCTAssertEqual(app.runtime, settings)
        XCTAssertEqual(app.draft, settings)
        XCTAssertEqual(queue.requests.map(\.text), ["registered"])
        XCTAssertEqual(queue.rejections.map(\.kind), [.missingDefinition])
        XCTAssertEqual(app.overallStatus, .ready)
    }

    func testFailedSaveKeepsOldRuntimeRegistrationAndTriggerContent() {
        let old = Fixtures.settings(text: "old")
        let store = StoreSpy(loadResult: .success(old))
        let shortcuts = ShortcutSpy()
        let queue = QueueSpy()
        let app = makeApp(store: store, shortcuts: shortcuts, queue: queue)
        app.start()
        app.draft = Fixtures.settings(text: "new")
        store.saveError = StoreError.io

        app.save()
        shortcuts.trigger(old.macros[0].id)

        XCTAssertEqual(app.runtime, old)
        XCTAssertEqual(shortcuts.replaceCalls, [old.macros])
        XCTAssertEqual(queue.requests.map(\.text), ["old"])
        XCTAssertNotNil(app.saveError)
    }

    func testSuccessfulSavePersistsBeforeReplacingRuntimeAndRegistration() {
        let old = Fixtures.settings(text: "old")
        let new = AppSettings(macros: [old.macros[0].withText("new")])
        let store = StoreSpy(loadResult: .success(old))
        let shortcuts = ShortcutSpy()
        let app = makeApp(store: store, shortcuts: shortcuts)
        app.start()
        app.draft = new
        store.onSave = {
            XCTAssertEqual(app.runtime, old)
            XCTAssertEqual(shortcuts.replaceCalls, [old.macros])
        }

        app.save()

        XCTAssertEqual(store.savedValues, [new])
        XCTAssertEqual(app.runtime, new)
        XCTAssertEqual(shortcuts.replaceCalls, [old.macros, new.macros])
        XCTAssertNil(app.saveError)
    }

    func testTriggerCopiesTextAndTrailingBeforeLaterSettingsReplacement() {
        let id = UUID()
        let old = MacroDefinition(
            id: id,
            isEnabled: true,
            shortcut: .init(key: .function(13), modifiers: []),
            text: "old",
            trailingKey: .space
        )
        let queue = QueueSpy()
        let shortcuts = ShortcutSpy()
        let app = makeApp(
            store: StoreSpy(loadResult: .success(.init(macros: [old]))),
            shortcuts: shortcuts,
            queue: queue
        )
        app.start()

        shortcuts.trigger(id)
        app.draft.macros[0].text = "new"
        app.draft.macros[0].trailingKey = .enter
        app.save()

        XCTAssertEqual(queue.requests.first?.text, "old")
        XCTAssertEqual(queue.requests.first?.trailing, .space)
    }

    func testTriggerChecksCurrentAccessibilityInsteadOfCachedPermissionState() {
        let value = Fixtures.settings(text: "secret")
        let permissions = PermissionSpy(
            state: .init(accessibility: true, inputMonitoring: nil),
            currentAccessibility: false
        )
        let queue = QueueSpy()
        let shortcuts = ShortcutSpy()
        let app = makeApp(
            store: StoreSpy(loadResult: .success(value)),
            shortcuts: shortcuts,
            permissions: permissions,
            queue: queue
        )
        app.start()

        shortcuts.trigger(value.macros[0].id)

        XCTAssertTrue(queue.requests.isEmpty)
        XCTAssertEqual(queue.rejections.map(\.kind), [.accessibilityRequired])
        XCTAssertEqual(permissions.currentAccessibilityChecks, 1)
    }

    func testRefreshPermissionsReconcilesRegistrationAndStatus() {
        let value = AppSettings(macros: [Fixtures.hid(21)])
        let permissions = PermissionSpy(
            state: .init(accessibility: true, inputMonitoring: false),
            currentAccessibility: true
        )
        let shortcuts = ShortcutSpy(states: [value.macros[0].id: .inputMonitoringRequired])
        let app = makeApp(
            store: StoreSpy(loadResult: .success(value)),
            shortcuts: shortcuts,
            permissions: permissions
        )
        app.start()
        XCTAssertEqual(app.overallStatus, .inputMonitoringRequired)
        shortcuts.states = [value.macros[0].id: .registered]
        permissions.refreshedState = .init(accessibility: true, inputMonitoring: true)

        app.refreshPermissions()

        XCTAssertEqual(permissions.refreshNeedsHID, [true, true])
        XCTAssertEqual(shortcuts.replaceCalls, [value.macros, value.macros])
        XCTAssertEqual(app.registration[value.macros[0].id], .registered)
        XCTAssertEqual(app.overallStatus, .ready)
    }

    func testQueueCallbacksUpdatePublishedStateOnMainActor() async {
        let queue = QueueSpy()
        let app = makeApp(queue: queue)
        let result = ExecutionResult(
            id: UUID(),
            shortcut: "F13",
            kind: .postingRequested,
            date: Date()
        )

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
        let app = makeApp(
            store: StoreSpy(loadResult: .success(value)),
            shortcuts: shortcuts,
            queue: queue
        )
        app.start()

        await Task.detached {
            shortcuts.trigger(value.macros[0].id)
        }.value

        XCTAssertEqual(queue.requests.map(\.text), ["background value"])
    }

    func testMeasurementModeIsExposedAndProgressUpdatesPublishedCount() {
        let app = AppController(
            store: StoreSpy(loadResult: .success(.init(macros: []))),
            shortcuts: ShortcutSpy(),
            permissions: PermissionSpy(),
            queue: QueueSpy(),
            measurementEnabled: true
        )

        app.updateMeasurementCount(37)

        XCTAssertTrue(app.measurementEnabled)
        XCTAssertEqual(app.measurementCount, 37)
    }

    private func makeApp(
        store: StoreSpy = StoreSpy(loadResult: .success(.init(macros: []))),
        shortcuts: ShortcutSpy = ShortcutSpy(),
        permissions: PermissionSpy = PermissionSpy(),
        queue: QueueSpy = QueueSpy()
    ) -> AppController {
        AppController(
            store: store,
            shortcuts: shortcuts,
            permissions: permissions,
            queue: queue
        )
    }
}
