---
type: plan
title: Kocro macOS 매크로 텍스트 입력 구현 계획
created: 2026-09-04
updated: 2026-09-04
related:
  - documents/spec/platform/macos-macro-text-input.md
status: in-progress
---

# Kocro macOS 매크로 텍스트 입력 구현 계획

> **For agentic workers:** Choose an execution method that matches the task boundaries. Use
> `subagent-driven-development` only when the plan contains two or more independent
> implementation tasks; execute tightly coupled or operational verification steps in order
> in the current context. Use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS 13 이상에서 사용자가 만든 매크로를 전역 단축키로 실행하고 Unicode 텍스트와 선택적인 후속 키를 완성된 배치로 만들어 FIFO 순서대로 게시하는 `Kocro` 메뉴 바 앱을 구현한다.

**Architecture:** `AppController`는 검증된 실행 설정과 편집 초안을 분리하고 원자적 JSON 저장이 성공한 뒤에만 실행 설정과 등록을 교체한다. `ShortcutCoordinator`는 일반 키 조합과 F13~F20을 Carbon으로, 단독 F21~F24를 필요한 HID usage만 매칭하는 `IOHIDManager`로 수신한다. 트리거 시점의 실행 내용을 값으로 복사하고 전체 `CGEvent` 생성이 끝난 요청만 직렬 queue에서 FIFO로 게시한다.

**Tech Stack:** Swift 5.9, SwiftUI `MenuBarExtra`/`Settings`, Foundation, Carbon, IOKit HID, ApplicationServices/CoreGraphics, ServiceManagement, OSLog, XCTest, Xcode 15 이상. 외부 package는 추가하지 않는다.

---

## 파일 구조

| 경로 | 책임 |
| --- | --- |
| `apps/macos/Kocro.xcodeproj/project.pbxproj` | macOS 13 앱·XCTest 타깃과 Apple 프레임워크 연결 |
| `apps/macos/Kocro/App/KocroApp.swift` | scene과 앱 수명 주기 |
| `apps/macos/Kocro/App/AppController.swift` | 로드·저장·권한·등록·실행 상태 조정 |
| `apps/macos/Kocro/Domain/MacroModels.swift` | UUID 매크로, shortcut, 후속 키, 설정 모델 |
| `apps/macos/Kocro/Domain/SettingsValidator.swift` | UUID·길이·키 조합·중복 검증 |
| `apps/macos/Kocro/Persistence/{SettingsStore,JSONSettingsStore}.swift` | 저장 경계와 원자적 JSON 구현 |
| `apps/macos/Kocro/Shortcuts/{ShortcutCoordinator,CarbonHotKeySource,HIDFunctionKeySource}.swift` | Carbon/HID 등록·수신·해제 |
| `apps/macos/Kocro/Input/{PermissionClient,EventBatchFactory,MacroExecutionQueue}.swift` | 권한, 전체 이벤트 선생성, FIFO 게시 |
| `apps/macos/Kocro/Features/MenuBar/MenuBarView.swift` | 우선순위 상태, 등록 수, 결과, 권한, 종료 |
| `apps/macos/Kocro/Features/Settings/{SettingsView,KeyRecorder,LoginItemController}.swift` | 무제한 편집, 로컬 키 기록, 로그인 실행 |
| `apps/macos/KocroTests/*.swift` | 시스템 경계와 수용 기준 XCTest |
| `apps/macos/KocroTests/Support/TestDoubles.swift` | 각 task의 file·OS API 대체 구현과 공통 fixture |
| `documents/reference/macos-macro-text-input-verification.md` | 실제 앱·권한·충돌·성능 검증 결과 |

## 공통 규칙

- product, project, target, scheme, module과 executable은 `Kocro`, bundle identifier는 `com.caost.Kocro`, deployment target은 macOS 13.0이다.
- production Swift 파일은 `Kocro`, test 파일은 `KocroTests` target에만 포함한다. 각 파일 생성 task에서 `project.pbxproj`도 갱신한다.
- 로그와 화면 결과에는 UUID, shortcut, 오류 종류와 시각만 둔다. 매크로 문자열과 활성 앱 이름은 넣지 않는다.
- builder는 브랜치를 변경하거나 커밋하지 않는다. conductor만 각 task 검증 뒤 stage 6에서 `wip(task-N): ...` checkpoint commit을 만들 수 있다. stage 9 승인 뒤 conductor가 checkpoint를 정리하고 전체 이슈 변경을 누락 없이 논리 단위 formal commit으로 다시 구성한다.
- 각 task는 GREEN 검증 뒤 중복 제거와 이름 정리처럼 동작을 바꾸지 않는 refactor를 수행하고, 해당 task의 focused test를 다시 통과시킨 뒤 checkpoint 후보로 넘긴다.

### Task 1: Kocro Xcode 프로젝트와 메뉴 바 진입점

**Files:**
- Create: `apps/macos/Kocro.xcodeproj/project.pbxproj`
- Create: `apps/macos/Kocro/App/KocroApp.swift`
- Create: `apps/macos/KocroTests/KocroSmokeTests.swift`

- [x] **Step 1: 프로젝트를 생성한다**

Xcode의 macOS App template에서 Product Name `Kocro`, Organization Identifier `com.caost`, SwiftUI, Swift, Include Tests를 선택해 `apps/macos`에 생성한다. deployment target은 13.0, `LSUIElement=YES`, signing off로 설정하고 Carbon, IOKit, ApplicationServices, ServiceManagement를 링크한다. RED 상태를 만들기 위해 template이 생성한 `ContentView.swift`와 `KocroApp.swift`, UI test target을 삭제한다.

- [x] **Step 2: 실패 test를 작성한다**

```swift
import XCTest
@testable import Kocro
final class KocroSmokeTests: XCTestCase {
    func testIdentity() {
        XCTAssertNotNil(KocroApp.self)
    }
}
```

- [x] **Step 3: 실패를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/KocroSmokeTests`

Expected: `KocroApp` 부재와 `** TEST FAILED **`.

- [x] **Step 4: 최소 앱을 구현한다**

```swift
import SwiftUI
@main struct KocroApp: App {
    var body: some Scene {
        MenuBarExtra("Kocro", systemImage: "keyboard") {
            Text("준비 중"); Button("설정…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            Divider(); Button("종료") { NSApplication.shared.terminate(nil) }
        }
        Settings { Text("Kocro 설정") }
    }
}
```

- [x] **Step 5: 검증한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/KocroSmokeTests && xcodebuild build -project apps/macos/Kocro.xcodeproj -scheme Kocro -configuration Release CODE_SIGNING_ALLOWED=NO && xcodebuild -showBuildSettings -project apps/macos/Kocro.xcodeproj -scheme Kocro -configuration Release | rg 'PRODUCT_BUNDLE_IDENTIFIER = com.caost.Kocro|MACOSX_DEPLOYMENT_TARGET = 13.0|INFOPLIST_KEY_LSUIElement = YES'`

Expected: `** TEST SUCCEEDED **`, `** BUILD SUCCEEDED **`, built app의 minimum system version 13.0과 `LSUIElement=1`.

- [x] **Step 6: checkpoint 후보**

builder는 커밋하지 않는다. conductor는 stage 6 뒤 `wip(task-1): scaffold Kocro macOS app`을 만들 수 있다.

### Task 2: UUID 매크로와 shortcut 검증

**Files:**
- Modify: `apps/macos/Kocro.xcodeproj/project.pbxproj`
- Create: `apps/macos/Kocro/Domain/MacroModels.swift`
- Create: `apps/macos/Kocro/Domain/SettingsValidator.swift`
- Create: `apps/macos/KocroTests/SettingsValidatorTests.swift`

- [x] **Step 1: 실패 test를 작성한다**

```swift
import XCTest
@testable import Kocro
final class SettingsValidatorTests: XCTestCase {
    let validator = SettingsValidator()
    func testDefaultsAndOrder() throws {
        let value = AppSettings.defaults
        XCTAssertEqual(value.macros.map(\.shortcut.key), (13...24).map { .function($0) })
        XCTAssertEqual(Set(value.macros.map(\.id)).count, 12)
        XCTAssertTrue(value.macros.allSatisfy { !$0.isEnabled && $0.text.isEmpty })
        XCTAssertNoThrow(try validator.validate(value))
        XCTAssertEqual(try validator.validate(.init(macros: Array(value.macros.reversed()))).macros.map(\.id), Array(value.macros.reversed()).map(\.id))
    }
    func testIdentityLengthAndEnabledValues() {
        let id = UUID(), key = ShortcutDefinition(key: .function(13), modifiers: [])
        let valid = MacroDefinition(id: id, isEnabled: true, shortcut: key, text: "가", trailingKey: .enter)
        XCTAssertThrowsError(try validator.validate(.init(macros: [valid, valid])))
        let duplicate = MacroDefinition(id: UUID(), isEnabled: true, shortcut: key, text: "나", trailingKey: nil)
        XCTAssertThrowsError(try validator.validate(.init(macros: [valid, duplicate])))
        XCTAssertThrowsError(try validator.validate(.init(macros: [valid.withText(String(repeating: "x", count: 10_001))])))
        XCTAssertNoThrow(try validator.validate(.init(macros: [valid.withText(String(repeating: "👨‍👩‍👧‍👦", count: 10_000))])))
        XCTAssertThrowsError(try validator.validate(.init(macros: [valid.withText("")])))
    }
    func testShortcutMatrixAndDuplicates() {
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .letter("a"), modifiers: [])))
        XCTAssertNoThrow(try validator.validateShortcut(.init(key: .function(1), modifiers: [.command])))
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .function(1), modifiers: [])))
        for n in 13...24 { XCTAssertNoThrow(try validator.validateShortcut(.init(key: .function(n), modifiers: []))) }
        XCTAssertNoThrow(try validator.validateShortcut(.init(key: .function(13), modifiers: [.shift])))
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .function(21), modifiers: [.shift])))
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .function(25), modifiers: [])))
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .letter("ab"), modifiers: [.command])))
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .keyCode(55), modifiers: [.command])))
        XCTAssertThrowsError(try validator.validateTrailing(.custom(keyCode: nil, modifiers: [.option])))
        XCTAssertThrowsError(try validator.validateTrailing(.custom(keyCode: 56, modifiers: [])))
        XCTAssertThrowsError(try validator.validateTrailing(.customFunction(21)))
    }
}
```

- [x] **Step 2: 타입 부재 실패를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/SettingsValidatorTests`

Expected: `SettingsValidator` 부재와 `** TEST FAILED **`.

- [x] **Step 3: 모델과 검증기를 구현한다**

```swift
import Foundation
struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8
    static let command = Self(rawValue: 1); static let control = Self(rawValue: 2)
    static let option = Self(rawValue: 4); static let shift = Self(rawValue: 8)
}
enum ShortcutKey: Codable, Hashable, Sendable { case empty, letter(String), keyCode(UInt16), function(Int) }
struct ShortcutDefinition: Codable, Hashable, Sendable {
    var key: ShortcutKey; var modifiers: ModifierSet
    var isHIDOnly: Bool { if case .function(let n) = key { return (21...24).contains(n) && modifiers.isEmpty }; return false }
    var functionNumber: Int? { if case .function(let n) = key { return n }; return nil }
    var displayName: String { if let n = functionNumber { return "F\(n)" }; return String(describing: key) }
}
enum TrailingKey: Codable, Hashable, Sendable { case enter, space, tab; case custom(keyCode: UInt16?, modifiers: ModifierSet); case customFunction(Int) }
struct MacroDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: UUID; var isEnabled: Bool; var shortcut: ShortcutDefinition; var text: String; var trailingKey: TrailingKey?
    func withText(_ value: String) -> Self { var copy = self; copy.text = value; return copy }
}
struct AppSettings: Codable, Equatable, Sendable {
    var macros: [MacroDefinition]
    static let defaults = Self(macros: (13...24).map { .init(id: UUID(), isEnabled: false, shortcut: .init(key: .function($0), modifiers: []), text: "", trailingKey: nil) })
}
```

```swift
enum ValidationError: Error { case duplicateID, textTooLong, emptyText, emptyShortcut, modifierRequired, unsupportedFunction, HIDModifiers, duplicateShortcut, invalidTrailing }
struct SettingsValidator {
    private let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    func validate(_ settings: AppSettings) throws -> AppSettings {
        var ids = Set<UUID>(), active = Set<ShortcutDefinition>()
        for macro in settings.macros {
            guard ids.insert(macro.id).inserted else { throw ValidationError.duplicateID }
            guard macro.text.count <= 10_000 else { throw ValidationError.textTooLong }
            if let trailing = macro.trailingKey { try validateTrailing(trailing) }
            guard macro.isEnabled else { continue }
            guard !macro.text.isEmpty else { throw ValidationError.emptyText }
            if case .empty = macro.shortcut.key { throw ValidationError.emptyShortcut }
            try validateShortcut(macro.shortcut)
            guard active.insert(macro.shortcut).inserted else { throw ValidationError.duplicateShortcut }
        }
        return settings
    }
    func validateShortcut(_ value: ShortcutDefinition) throws {
        switch value.key {
        case .empty: throw ValidationError.emptyShortcut
        case .letter(let letter): guard letter.count == 1, letter.unicodeScalars.allSatisfy({ $0.isASCII }), !value.modifiers.isEmpty else { throw ValidationError.modifierRequired }
        case .keyCode(let code): guard !modifierKeyCodes.contains(code), !value.modifiers.isEmpty else { throw ValidationError.modifierRequired }
        case .function(let n):
            guard (1...24).contains(n) else { throw ValidationError.unsupportedFunction }
            if n <= 12, value.modifiers.isEmpty { throw ValidationError.modifierRequired }
            if (21...24).contains(n), !value.modifiers.isEmpty { throw ValidationError.HIDModifiers }
        }
    }
    func validateTrailing(_ value: TrailingKey) throws {
        switch value { case .enter, .space, .tab: return; case .custom(let code?, _): if modifierKeyCodes.contains(code) { throw ValidationError.invalidTrailing }; case .custom(nil, _), .customFunction: throw ValidationError.invalidTrailing }
    }
}
```

`ShortcutKey.function`과 `TrailingKey.customFunction`만 이름 기반 Function 키를 decode한다. 따라서 F25~F35 JSON은 해당 case로 복원된 뒤 위 range 검증에서 거부되며 raw `keyCode`를 F25~F35로 해석하지 않는다. `keyCode`와 custom trailing은 modifier-only virtual key code 54~63을 거부한다. `KeyRecorder`는 일반 키와 F1~F20 전역 shortcut을 로컬 이벤트에서 기록하며 F1~F12에는 보조 키를 요구한다. F21~F24 전역 shortcut은 전용 picker에서 `.function`으로 지정한다. 후속 키에서는 안정적인 virtual key code가 있는 F1~F20을 `.custom(keyCode:modifiers:)`로 기록하고 F21~F35만 `.customFunction`으로 기록해 validation 오류를 표시한다.

- [x] **Step 4: 통과를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/SettingsValidatorTests`

Expected: `** TEST SUCCEEDED **`; 비활성 초안은 빈 값이 허용되고 UUID와 10,000자 제한은 적용된다.

- [x] **Step 5: checkpoint 후보**

conductor는 stage 6 뒤 `wip(task-2): add macro domain validation`을 만들 수 있고 builder는 커밋하지 않는다.

### Task 3: 원자적 JSON 저장과 저장 실패 롤백 경계

**Files:**
- Modify: `apps/macos/Kocro.xcodeproj/project.pbxproj`
- Create: `apps/macos/Kocro/Persistence/SettingsStore.swift`
- Create: `apps/macos/Kocro/Persistence/JSONSettingsStore.swift`
- Create: `apps/macos/KocroTests/JSONSettingsStoreTests.swift`
- Create: `apps/macos/KocroTests/Support/TestDoubles.swift`

- [x] **Step 1: 실패 test를 작성한다**

```swift
import XCTest
@testable import Kocro
final class JSONSettingsStoreTests: XCTestCase {
    func testMissingRoundTripOrderAndPermissions() throws {
        let file = MemorySettingsFile(contents: nil), store = JSONSettingsStore(file: file, validator: .init())
        let defaults = try store.load(), reversed = AppSettings(macros: Array(defaults.macros.reversed()))
        try store.save(reversed)
        XCTAssertEqual(try store.load().macros.map(\.id), reversed.macros.map(\.id))
        XCTAssertEqual(file.permissions, 0o600); XCTAssertEqual(file.replaceCount, 2)
    }
    func testCorruptLoadAndFailedSaveDoNotExposePartialData() throws {
        XCTAssertThrowsError(try JSONSettingsStore(file: MemorySettingsFile(contents: Data("{".utf8)), validator: .init()).load())
        let original = try JSONEncoder().encode(AppSettings.defaults), file = MemorySettingsFile(contents: original)
        file.writeError = StoreError.io
        XCTAssertThrowsError(try JSONSettingsStore(file: file, validator: .init()).save(.defaults))
        XCTAssertEqual(file.contents, original); XCTAssertEqual(file.replaceCount, 0)
    }
}
```

- [x] **Step 2: 실패를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/JSONSettingsStoreTests`

Expected: `JSONSettingsStore` 부재와 `** TEST FAILED **`.

- [x] **Step 3: 저장 코드를 구현한다**

```swift
import Foundation
enum StoreError: Error { case invalidFile, io }
protocol SettingsStoring { func load() throws -> AppSettings; func save(_ value: AppSettings) throws }
protocol SettingsFile { var exists: Bool { get }; func read() throws -> Data; func atomicReplace(with: Data, permissions: Int16) throws }
final class JSONSettingsStore: SettingsStoring {
    let file: SettingsFile; let validator: SettingsValidator
    init(file: SettingsFile, validator: SettingsValidator) { self.file = file; self.validator = validator }
    func load() throws -> AppSettings {
        guard file.exists else { let defaults = AppSettings.defaults; try save(defaults); return defaults }
        do { return try validator.validate(JSONDecoder().decode(AppSettings.self, from: file.read())) }
        catch { throw StoreError.invalidFile }
    }
    func save(_ value: AppSettings) throws {
        let valid = try validator.validate(value), encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try file.atomicReplace(with: encoder.encode(valid), permissions: 0o600)
    }
}
```

`ApplicationSupportSettingsFile`은 `~/Library/Application Support/com.caost.Kocro/settings.json`의 parent를 `0700`으로 만들고 같은 directory에 UUID 임시 파일을 `0600`으로 쓴다. 대상이 있으면 `FileManager.replaceItemAt`으로 교체하고, 최초 저장이면 같은 filesystem 안의 POSIX `rename(temporary.path, url.path)`으로 원자 이동한다. `rename`이 0이 아니면 `POSIXError(POSIXErrorCode(rawValue: errno)!)`를 던지고, `defer`에서 남은 임시 파일을 지운다. `MemorySettingsFile`은 test target에서 기존 대상 유무와 동일한 두 경로를 기록한다.

```swift
// apps/macos/KocroTests/Support/TestDoubles.swift — Task 3에서 생성
@testable import Kocro
import Foundation
final class MemorySettingsFile: SettingsFile {
    var contents: Data?; var permissions: Int16?; var replaceCount = 0; var writeError: Error?
    init(contents: Data?) { self.contents = contents }
    var exists: Bool { contents != nil }
    func read() throws -> Data { try contents ?? { throw StoreError.io }() }
    func atomicReplace(with data: Data, permissions: Int16) throws {
        if let writeError { throw writeError }; self.contents = data; self.permissions = permissions; replaceCount += 1
    }
}
enum Fixtures {
    static func macro(id: UUID = UUID(), text: String, shortcut: ShortcutDefinition = .init(key: .function(13), modifiers: [])) -> MacroDefinition {
        .init(id: id, isEnabled: true, shortcut: shortcut, text: text, trailingKey: nil)
    }
    static func settings(text: String) -> AppSettings { .init(macros: [macro(text: text)]) }
    static func carbon(_ n: Int) -> MacroDefinition { macro(text: "c\(n)", shortcut: .init(key: .function(n), modifiers: [])) }
    static func hid(_ n: Int) -> MacroDefinition { macro(text: "h\(n)", shortcut: .init(key: .function(n), modifiers: [])) }
    static func enabledCarbonCarbonHID() -> [MacroDefinition] { [carbon(13), carbon(14), hid(21)] }
}
```

- [x] **Step 4: 통과를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/JSONSettingsStoreTests`

Expected: `** TEST SUCCEEDED **`; 파일 없음은 사용자 전용 파일에 12개 초기값을 원자 저장하고, 손상 파일은 전체 실패, 쓰기 실패는 기존 bytes 유지다.

- [x] **Step 5: checkpoint 후보**

conductor는 stage 6 뒤 `wip(task-3): persist settings atomically`를 만들 수 있고 builder는 커밋하지 않는다.

### Task 4: Carbon과 F21~F24 HID shortcut 수신

**Files:**
- Modify: `apps/macos/Kocro.xcodeproj/project.pbxproj`
- Create: `apps/macos/Kocro/Shortcuts/ShortcutCoordinator.swift`
- Create: `apps/macos/Kocro/Shortcuts/CarbonHotKeySource.swift`
- Create: `apps/macos/Kocro/Shortcuts/HIDFunctionKeySource.swift`
- Create: `apps/macos/KocroTests/ShortcutCoordinatorTests.swift`
- Create: `apps/macos/KocroTests/HIDFunctionKeySourceTests.swift`
- Modify: `apps/macos/KocroTests/Support/TestDoubles.swift`

- [x] **Step 1: 실패 test를 작성한다**

```swift
import XCTest
@testable import Kocro
final class ShortcutCoordinatorTests: XCTestCase {
    func testPartialCarbonFailureAndHIDAreIndependent() {
        let carbon = CarbonSpy(failingRegistration: 2), hid = HIDSpy(permission: true, starts: true)
        let coordinator = ShortcutCoordinator(carbon: carbon, hid: hid)
        let macros = Fixtures.enabledCarbonCarbonHID()
        let states = coordinator.replace(with: macros)
        XCTAssertEqual(carbon.registrationCount, 2); XCTAssertEqual(hid.usages, [0x70])
        XCTAssertEqual(states[macros[0].id], .registered); XCTAssertEqual(states[macros[1].id], .registrationFailed); XCTAssertEqual(states[macros[2].id], .registered)
    }
    func testHIDPermissionAndStartFailuresLeaveCarbonRegistered() {
        for (hid, expected) in [(HIDSpy(permission: false, starts: true), RegistrationState.inputMonitoringRequired), (HIDSpy(permission: true, starts: false), .hidStartFailed)] {
            let carbon = CarbonSpy(), coordinator = ShortcutCoordinator(carbon: carbon, hid: hid), macros = Fixtures.enabledCarbonCarbonHID()
            let states = coordinator.replace(with: macros)
            XCTAssertEqual(states[macros[0].id], .registered); XCTAssertEqual(states[macros[2].id], expected)
        }
    }
    func testDisabledMacroIsNotRegisteredAndShutdownUnregistersCarbon() {
        var disabled = Fixtures.carbon(14); disabled.isEnabled = false
        let carbon = CarbonSpy(), coordinator = ShortcutCoordinator(carbon: carbon, hid: HIDSpy(permission: true, starts: true))
        _ = coordinator.replace(with: [Fixtures.carbon(13), disabled]); XCTAssertEqual(carbon.registrationCount, 1)
        coordinator.shutdown(); XCTAssertEqual(carbon.unregisterAllCount, 2)
    }
    func testRemovingAllHIDStopsMonitorWithoutPermissionCheck() {
        let hid = HIDSpy(permission: true, starts: true), coordinator = ShortcutCoordinator(carbon: CarbonSpy(), hid: hid)
        _ = coordinator.replace(with: [Fixtures.hid(21)]); _ = coordinator.replace(with: [Fixtures.carbon(13)])
        XCTAssertEqual(hid.stopCount, 2); XCTAssertEqual(hid.permissionChecks, 1)
        coordinator.shutdown(); XCTAssertEqual(hid.stopCount, 3)
    }
}
final class HIDFunctionKeySourceTests: XCTestCase {
    func testOnlyRequestedUsageAndPressEdgesTrigger() {
        XCTAssertEqual(HIDFunctionKeySource.matchingUsages([21, 24]), [0x70, 0x73])
        let sink = TriggerSpy(), source = HIDFunctionKeySource(api: HIDAPISpy(), onTrigger: sink.call)
        XCTAssertTrue(source.start(functions: [21]))
        source.receive(usage: 0x70, value: 1); source.receive(usage: 0x70, value: 1)
        source.receive(usage: 0x70, value: 0); source.receive(usage: 0x71, value: 1)
        source.receive(usage: 0x70, value: 1)
        XCTAssertEqual(sink.functions, [21, 21])
    }
}
```

- [x] **Step 2: 실패를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/ShortcutCoordinatorTests -only-testing:KocroTests/HIDFunctionKeySourceTests`

Expected: shortcut source 타입 부재와 `** TEST FAILED **`.

- [x] **Step 3: 조정 로직을 구현한다**

```swift
enum RegistrationState: Equatable { case registered, registrationFailed, inputMonitoringRequired, hidStartFailed }
protocol CarbonServing: AnyObject { var onRegistrationID: ((UInt32, ContinuousClock.Instant) -> Void)? { get set }; func register(id: UInt32, shortcut: ShortcutDefinition) -> Bool; func unregisterAll() }
protocol HIDServing: AnyObject { var hasPermission: Bool { get }; var onFunction: ((Int, ContinuousClock.Instant) -> Void)? { get set }; func start(functions: Set<Int>) -> Bool; func stop() }
final class ShortcutCoordinator {
    let carbon: CarbonServing; let hid: HIDServing
    var onTrigger: ((UUID, ContinuousClock.Instant) -> Void)?
    private let ingress = DispatchQueue(label: "com.caost.Kocro.shortcut-ingress")
    private var carbonIDs: [UInt32: UUID] = [:], hidFunctions: [Int: UUID] = [:]
    init(carbon: CarbonServing, hid: HIDServing) {
        self.carbon = carbon; self.hid = hid
        carbon.onRegistrationID = { [weak self] key, instant in self?.ingress.async { guard let self, let id = self.carbonIDs[key] else { return }; self.onTrigger?(id, instant) } }
        hid.onFunction = { [weak self] function, instant in self?.ingress.async { guard let self, let id = self.hidFunctions[function] else { return }; self.onTrigger?(id, instant) } }
    }
    func replace(with macros: [MacroDefinition], installSnapshots: () -> Void = {}) -> [UUID: RegistrationState] { ingress.sync {
        carbon.unregisterAll(); hid.stop(); carbonIDs.removeAll(); hidFunctions.removeAll(); installSnapshots(); let active = macros.filter(\.isEnabled); var states: [UUID: RegistrationState] = [:]
        for (offset, macro) in active.filter({ !$0.shortcut.isHIDOnly }).enumerated() {
            let key = UInt32(offset + 1), succeeded = carbon.register(id: key, shortcut: macro.shortcut)
            states[macro.id] = succeeded ? .registered : .registrationFailed; if succeeded { carbonIDs[key] = macro.id }
        }
        let hidMacros = active.filter(\.shortcut.isHIDOnly)
        guard !hidMacros.isEmpty else { return states }
        guard hid.hasPermission else { hidMacros.forEach { states[$0.id] = .inputMonitoringRequired }; return states }
        let started = hid.start(functions: Set(hidMacros.compactMap(\.shortcut.functionNumber)))
        hidMacros.forEach { macro in states[macro.id] = started ? .registered : .hidStartFailed; if started, let function = macro.shortcut.functionNumber { hidFunctions[function] = macro.id } }
        return states
    } }
    func shutdown() { carbon.unregisterAll(); hid.stop() }
}
```

`CarbonHotKeySource`는 callback 첫 줄에서 registration ID와 `ContinuousClock.now`를 전달한다. `HIDFunctionKeySource`는 Keyboard/Keypad page `0x07`의 F21 `0x70`, F22 `0x71`, F23 `0x72`, F24 `0x73` 가운데 활성 usage만 매칭하고 callback 첫 줄에서 수신 instant를 잡는다. 두 source callback과 `replace`는 같은 serial `ingress` queue에 제출된다. 교체보다 먼저 도착한 callback은 이전 map/snapshot으로 queue에 들어가고, 교체는 기존 source 중지→map 제거→`installSnapshots`→새 등록을 한 block에서 수행하며, 이후 callback만 새 map/snapshot을 사용한다. 두 source는 문자열을 받지 않으며 HID는 비독점 open으로 원래 이벤트를 제거하지 않는다.

`TestDoubles.swift`에 `CarbonSpy: CarbonServing`, `HIDSpy: HIDServing`, `HIDAPISpy`와 `TriggerSpy`를 추가한다. 각 spy는 위 test가 읽는 `registrationCount`, `unregisterAllCount`, `usages`, `permissionChecks`, `stopCount`, `functions`를 배열/정수로 저장하고 생성자 인수 `failingRegistration`, `permission`, `starts`에 따라 protocol 결과를 그대로 반환한다. 이는 OS API를 호출하지 않는 test 전용 구현이며 production membership을 선택하지 않는다.

- [x] **Step 4: 검증한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/ShortcutCoordinatorTests -only-testing:KocroTests/HIDFunctionKeySourceTests && ! rg -n 'CGEventTap|addGlobalMonitorForEvents' apps/macos/Kocro/Shortcuts`

Expected: `** TEST SUCCEEDED **`; 검색 출력 없음. Carbon 일부 실패와 HID 권한/시작 실패는 다른 경로를 유지한다.

- [x] **Step 5: checkpoint 후보**

conductor는 stage 6 뒤 `wip(task-4): register Carbon and HID shortcuts`을 만들 수 있고 builder는 커밋하지 않는다.

### Task 5: Accessibility와 조건부 Input Monitoring

**Files:**
- Modify: `apps/macos/Kocro.xcodeproj/project.pbxproj`
- Create: `apps/macos/Kocro/Input/PermissionClient.swift`
- Create: `apps/macos/KocroTests/PermissionClientTests.swift`
- Modify: `apps/macos/KocroTests/Support/TestDoubles.swift`

- [x] **Step 1: 실패 test를 작성한다**

```swift
import XCTest
@testable import Kocro
final class PermissionClientTests: XCTestCase {
    func testPromptsOnlyFromExplicitActionAndRechecks() {
        let api = PermissionAPISpy(accessibility: false, input: false), client = PermissionClient(api: api)
        _ = client.refresh(needsHID: false); XCTAssertEqual(api.accessibilityPrompts, 0); XCTAssertEqual(api.inputChecks, 0)
        client.requestAccessibility(); XCTAssertEqual(api.accessibilityPrompts, 1); XCTAssertFalse(client.state.accessibility)
        api.accessibility = true; XCTAssertTrue(client.refresh(needsHID: true).accessibility); XCTAssertEqual(api.inputChecks, 1)
    }
}
```

- [x] **Step 2: 실패를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/PermissionClientTests`

Expected: `PermissionClient` 부재와 `** TEST FAILED **`.

- [x] **Step 3: 권한 경계를 구현한다**

```swift
struct PermissionState { var accessibility: Bool; var inputMonitoring: Bool? }
protocol PermissionAPI {
    func accessibilityTrusted(prompt: Bool) -> Bool; func inputMonitoringGranted() -> Bool
    func requestInputMonitoring(); func openSettings(_ kind: PrivacyKind)
}
enum PrivacyKind { case accessibility, inputMonitoring }
final class PermissionClient {
    let api: PermissionAPI; private(set) var state = PermissionState(accessibility: false, inputMonitoring: nil)
    init(api: PermissionAPI) { self.api = api }
    @discardableResult func refresh(needsHID: Bool) -> PermissionState {
        state = .init(accessibility: api.accessibilityTrusted(prompt: false), inputMonitoring: needsHID ? api.inputMonitoringGranted() : nil); return state
    }
    func requestAccessibility() { _ = api.accessibilityTrusted(prompt: true) }
    func requestInputMonitoring() { api.requestInputMonitoring() }
    func openSettings(_ kind: PrivacyKind) { api.openSettings(kind) }
}
```

시스템 구현은 `AXIsProcessTrustedWithOptions`, `IOHIDCheckAccess`/`IOHIDRequestAccess`와 해당 Privacy & Security 설정 URL만 사용한다. 요청 직후 granted로 바꾸지 않고 앱 활성화와 메뉴 표시 때 refresh한다. Screen Recording, Full Disk Access, Automation과 관리자 권한은 요청하지 않는다.

`TestDoubles.swift`에 `PermissionAPISpy: PermissionAPI`를 추가한다. mutable `accessibility`, `input`, `accessibilityPrompts`, `inputChecks`를 저장하며 `accessibilityTrusted(prompt:)`는 prompt가 true일 때만 count를 올리고 현재 값을 반환한다. `inputMonitoringGranted()`는 count를 올리고 `input`을 반환한다.

- [x] **Step 4: 검증한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/PermissionClientTests`

Expected: `** TEST SUCCEEDED **`; F21~F24가 없을 때 Input Monitoring 호출은 0이다.

- [x] **Step 5: checkpoint 후보**

conductor는 stage 6 뒤 `wip(task-5): add conditional permission handling`을 만들 수 있고 builder는 커밋하지 않는다.

### Task 6: Unicode 완성 배치와 FIFO queue

**Files:**
- Modify: `apps/macos/Kocro.xcodeproj/project.pbxproj`
- Create: `apps/macos/Kocro/Input/EventBatchFactory.swift`
- Create: `apps/macos/Kocro/Input/MacroExecutionQueue.swift`
- Create: `apps/macos/KocroTests/EventBatchFactoryTests.swift`
- Create: `apps/macos/KocroTests/MacroExecutionQueueTests.swift`
- Modify: `apps/macos/KocroTests/Support/TestDoubles.swift`

- [x] **Step 1: 실패 test를 작성한다**

```swift
import XCTest
@testable import Kocro
final class EventBatchFactoryTests: XCTestCase {
    func testClustersAndAllOrNothingTrailingPair() throws {
        let api = EventAPISpy(), factory = EventBatchFactory(api: api, maximumUTF16Units: 4)
        XCTAssertEqual(factory.chunks("A👨‍👩‍👧‍👦e\u{301}B").joined(), "A👨‍👩‍👧‍👦e\u{301}B")
        let batch = try factory.make(text: "abcdef", trailing: .enter)
        XCTAssertEqual(api.created, [.unicode("abcd"), .unicode("ef"), .keyDown(36, []), .keyUp(36, [])])
        XCTAssertEqual(api.posted, 0); XCTAssertEqual(batch.count, 4)
        api.failAt = 2; XCTAssertThrowsError(try factory.make(text: "abcdef", trailing: .tab)); XCTAssertEqual(api.posted, 0)
        api.failAt = nil
        _ = try factory.make(text: "a", trailing: .custom(keyCode: 36, modifiers: [.shift]))
        XCTAssertEqual(Array(api.created.suffix(2)), [.keyDown(36, [.shift]), .keyUp(36, [.shift])])
    }
}
final class MacroExecutionQueueTests: XCTestCase {
    func testFIFOAndTriggerTimeSnapshot() async {
        let poster = BlockingPoster(), queue = MacroExecutionQueue(poster: poster, accessibility: { true })
        queue.enqueue(.init(id: UUID(), shortcut: "F13", text: "first", trailing: .space, receivedAt: .now))
        queue.enqueue(.init(id: UUID(), shortcut: "F14", text: "second", trailing: nil, receivedAt: .now))
        await queue.drain()
        XCTAssertEqual(poster.texts, ["first", "second"]); XCTAssertEqual(poster.maximumConcurrent, 1)
    }
    func testNoPermissionPostsNothingAndResultHasNoText() async {
        let poster = BlockingPoster(), queue = MacroExecutionQueue(poster: poster, accessibility: { false })
        queue.enqueue(.init(id: UUID(), shortcut: "F13", text: "secret", trailing: nil, receivedAt: .now)); await queue.drain()
        XCTAssertTrue(poster.texts.isEmpty); XCTAssertFalse(queue.lastResult!.description.contains("secret"))
    }
}
```

- [x] **Step 2: 실패를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/EventBatchFactoryTests -only-testing:KocroTests/MacroExecutionQueueTests`

Expected: input 타입 부재와 `** TEST FAILED **`.

- [x] **Step 3: batch와 queue를 구현한다**

```swift
enum EventKind: Equatable { case unicode(String), keyDown(UInt16, ModifierSet), keyUp(UInt16, ModifierSet) }
protocol EventAPI { associatedtype Event; func create(_ kind: EventKind) -> Event?; func post(_ event: Event) }
enum EventBuildError: Error { case creationFailed }
struct EventBatchFactory<API: EventAPI> {
    let api: API; let maximumUTF16Units: Int
    func chunks(_ text: String) -> [String] {
        var output: [String] = [], current = ""
        for character in text { let next = current + String(character); if !current.isEmpty && next.utf16.count > maximumUTF16Units { output.append(current); current = String(character) } else { current = next } }
        if !current.isEmpty { output.append(current) }; return output
    }
    func make(text: String, trailing: TrailingKey?) throws -> [API.Event] {
        var kinds = chunks(text).map(EventKind.unicode)
        if let trailing { let code: UInt16, modifiers: ModifierSet; switch trailing { case .enter: code = 36; modifiers = []; case .space: code = 49; modifiers = []; case .tab: code = 48; modifiers = []; case .custom(let value?, let flags): code = value; modifiers = flags; case .custom(nil, _), .customFunction: throw EventBuildError.creationFailed }; kinds += [.keyDown(code, modifiers), .keyUp(code, modifiers)] }
        let events = kinds.compactMap(api.create); guard events.count == kinds.count else { throw EventBuildError.creationFailed }; return events
    }
}
struct ExecutionRequest: Sendable { let id: UUID; let shortcut: String; let text: String; let trailing: TrailingKey?; let receivedAt: ContinuousClock.Instant }
enum ExecutionResultKind: String { case postingRequested, accessibilityRequired, eventCreationFailed, missingDefinition }
struct ExecutionResult { let id: UUID; let shortcut: String; let kind: ExecutionResultKind; let date: Date; var description: String { "\(shortcut) \(kind.rawValue) \(date.timeIntervalSince1970)" } }
protocol BatchPosting { func buildAndPost(_ request: ExecutionRequest) throws }
final class MacroExecutionQueue {
    let serial = DispatchQueue(label: "com.caost.Kocro.execution"), poster: BatchPosting, accessibility: () -> Bool
    private(set) var lastResult: ExecutionResult?; var onResult: ((ExecutionResult) -> Void)?; var onIdleChange: ((Bool) -> Void)?
    private let pendingLock = NSLock(); private var pending = 0
    init(poster: BatchPosting, accessibility: @escaping () -> Bool) { self.poster = poster; self.accessibility = accessibility }
    func enqueue(_ request: ExecutionRequest) { pendingLock.lock(); pending += 1; let becameBusy = pending == 1; if becameBusy { onIdleChange?(false) }; serial.async { let kind: ExecutionResultKind; if !self.accessibility() { kind = .accessibilityRequired } else { do { try self.poster.buildAndPost(request); kind = .postingRequested } catch { kind = .eventCreationFailed } }; let result = ExecutionResult(id: request.id, shortcut: request.shortcut, kind: kind, date: Date()); self.lastResult = result; self.onResult?(result); self.pendingLock.lock(); self.pending -= 1; let becameIdle = self.pending == 0; self.pendingLock.unlock(); if becameIdle { self.onIdleChange?(true) } }; pendingLock.unlock() }
    func reject(id: UUID, shortcut: String, kind: ExecutionResultKind) { serial.async { let result = ExecutionResult(id: id, shortcut: shortcut, kind: kind, date: Date()); self.lastResult = result; self.onResult?(result) } }
    func drain() async { await withCheckedContinuation { continuation in serial.async { continuation.resume() } } }
}
```

Core Graphics `BatchPosting`은 production `maximumUTF16Units`를 `20`으로 고정하고 모든 Unicode keyDown event에 `keyboardSetUnicodeString`을 적용하며 custom modifier flags를 후속 keyDown/keyUp에 설정한다. factory가 전부 생성한 뒤에만 `.cghidEventTap`에 순서대로 게시한다. 마지막 게시 호출이 반환된 뒤 다음 queue block을 시작한다. 대상 앱 반영 확인, 자동 재시도, clipboard, process, shell과 network는 구현하지 않는다.

`TestDoubles.swift`에 `EventAPISpy: EventAPI`, `BlockingPoster: BatchPosting`, `RecordingBatchPoster: BatchPosting`을 추가한다. `EventAPISpy`는 creation 순번이 `failAt`과 같으면 nil을 반환하고 `created`/`posted`를 기록한다. 두 poster는 request의 text, 현재 진입 수와 `maximumConcurrent`를 lock으로 보호해 기록하며 `BlockingPoster`는 FIFO 확인용 semaphore를 제공한다.

- [x] **Step 4: 검증한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/EventBatchFactoryTests -only-testing:KocroTests/MacroExecutionQueueTests`

Expected: `** TEST SUCCEEDED **`; 생성 실패 게시 수 0, 후속 pair 1개, FIFO와 최대 동시 게시 1.

- [x] **Step 5: checkpoint 후보**

conductor는 stage 6 뒤 `wip(task-6): queue complete Unicode batches`를 만들 수 있고 builder는 커밋하지 않는다.

### Task 7: AppController의 transactional 상태 전환

**Files:**
- Modify: `apps/macos/Kocro.xcodeproj/project.pbxproj`
- Create: `apps/macos/Kocro/App/AppController.swift`
- Create: `apps/macos/KocroTests/AppControllerTests.swift`
- Modify: `apps/macos/KocroTests/Support/TestDoubles.swift`

- [x] **Step 1: 실패 test를 작성한다**

```swift
import XCTest
@testable import Kocro
@MainActor final class AppControllerTests: XCTestCase {
    func testBadLoadDisablesEverythingAndOpensReplacementDraft() {
        let app = AppController(store: StoreSpy(load: .failure(StoreError.invalidFile)), shortcuts: ShortcutSpy(), permissions: PermissionSpy(), queue: QueueSpy())
        app.start(); XCTAssertEqual(app.overallStatus, .settingsError); XCTAssertTrue(app.runtime.macros.isEmpty)
        app.openSettings(); XCTAssertEqual(app.draft.macros.count, 12); XCTAssertTrue(app.showsReplaceWarning)
    }
    func testFailedSaveKeepsOldRuntimeRegistrationAndTrigger() {
        let old = Fixtures.settings(text: "old"), store = StoreSpy(load: .success(old)), shortcuts = ShortcutSpy()
        let queue = QueueSpy(), app = AppController(store: store, shortcuts: shortcuts, permissions: PermissionSpy(accessibility: true), queue: queue)
        app.start(); app.draft = Fixtures.settings(text: "new"); store.saveError = .io; app.save(); shortcuts.trigger(old.macros[0].id)
        XCTAssertEqual(app.runtime, old); XCTAssertEqual(shortcuts.replaceCalls, [old.macros]); XCTAssertEqual(queue.requests.map(\.text), ["old"])
    }
    func testTriggerCopiesTextAndTrailingBeforeLaterSettingsReplacement() {
        let old = MacroDefinition(id: UUID(), isEnabled: true, shortcut: .init(key: .function(13), modifiers: []), text: "old", trailingKey: .space)
        let shortcuts = ShortcutSpy(), queue = QueueSpy(), app = AppController(store: StoreSpy(load: .success(.init(macros: [old]))), shortcuts: shortcuts, permissions: PermissionSpy(accessibility: true), queue: queue)
        app.start(); shortcuts.trigger(old.id)
        app.draft.macros[0].text = "new"; app.draft.macros[0].trailingKey = .enter; app.save()
        XCTAssertEqual(queue.requests.first?.text, "old"); XCTAssertEqual(queue.requests.first?.trailing, .space)
    }
    func testUnregisteredOrUnauthorizedTriggerDoesNotQueue() {
        let value = Fixtures.settings(text: "secret"), shortcuts = ShortcutSpy(states: [value.macros[0].id: .registrationFailed]), queue = QueueSpy()
        let app = AppController(store: StoreSpy(load: .success(value)), shortcuts: shortcuts, permissions: PermissionSpy(accessibility: false), queue: queue)
        app.start(); shortcuts.trigger(value.macros[0].id); XCTAssertTrue(queue.requests.isEmpty)
    }
}
```

- [x] **Step 2: 실패를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/AppControllerTests`

Expected: `AppController` 부재와 `** TEST FAILED **`.

- [x] **Step 3: controller를 구현한다**

```swift
enum OverallStatus { case ready, accessibilityRequired, inputMonitoringRequired, settingsError }
protocol ShortcutCoordinating: AnyObject {
    var onTrigger: ((UUID, ContinuousClock.Instant) -> Void)? { get set }
    func replace(with macros: [MacroDefinition], installSnapshots: () -> Void) -> [UUID: RegistrationState]
    func shutdown()
}
protocol PermissionServing: AnyObject {
    var state: PermissionState { get }
    @discardableResult func refresh(needsHID: Bool) -> PermissionState
    func requestAccessibility()
    func requestInputMonitoring()
    func openSettings(_ kind: PrivacyKind)
    func currentAccessibility() -> Bool
}
protocol ExecutionQueueing: AnyObject {
    var lastResult: ExecutionResult? { get }
    var onResult: ((ExecutionResult) -> Void)? { get set }
    var onIdleChange: ((Bool) -> Void)? { get set }
    func enqueue(_ request: ExecutionRequest)
    func reject(id: UUID, shortcut: String, kind: ExecutionResultKind)
}
final class ExecutionSnapshotStore {
    private let lock = NSLock(); private var values: [UUID: MacroDefinition] = [:]
    func replace(_ macros: [MacroDefinition]) { lock.lock(); values = Dictionary(uniqueKeysWithValues: macros.filter(\.isEnabled).map { ($0.id, $0) }); lock.unlock() }
    func removeAll() { lock.lock(); values.removeAll(); lock.unlock() }
    func request(_ id: UUID, receivedAt: ContinuousClock.Instant) -> ExecutionRequest? {
        lock.lock(); defer { lock.unlock() }
        guard let macro = values[id], !macro.text.isEmpty else { return nil }
        return .init(id: id, shortcut: macro.shortcut.displayName, text: macro.text, trailing: macro.trailingKey, receivedAt: receivedAt)
    }
}
final class TriggerRouter {
    let snapshots: ExecutionSnapshotStore, queue: ExecutionQueueing, accessibility: () -> Bool
    init(snapshots: ExecutionSnapshotStore, queue: ExecutionQueueing, accessibility: @escaping () -> Bool) { self.snapshots = snapshots; self.queue = queue; self.accessibility = accessibility }
    func receive(id: UUID, receivedAt: ContinuousClock.Instant) {
        guard accessibility() else { queue.reject(id: id, shortcut: "등록 ID \(id.uuidString)", kind: .accessibilityRequired); return }
        guard let request = snapshots.request(id, receivedAt: receivedAt) else { queue.reject(id: id, shortcut: "등록 ID \(id.uuidString)", kind: .missingDefinition); return }
        queue.enqueue(request)
    }
}
@MainActor final class AppController: ObservableObject {
    @Published var draft = AppSettings(macros: []); @Published private(set) var runtime = AppSettings(macros: [])
    @Published private(set) var registration: [UUID: RegistrationState] = [:]; @Published private(set) var lastResult: ExecutionResult?; @Published private(set) var queueIsIdle = true; @Published private(set) var measurementCount = 0; @Published private(set) var loadError: Error?; @Published private(set) var saveError: Error?; @Published private(set) var showsReplaceWarning = false
    let store: SettingsStoring, shortcuts: ShortcutCoordinating, permissions: PermissionServing, queue: ExecutionQueueing
    let snapshots: ExecutionSnapshotStore; let router: TriggerRouter
    var overallStatus: OverallStatus { if loadError != nil { return .settingsError }; if !permissions.state.accessibility { return .accessibilityRequired }; if registration.values.contains(.inputMonitoringRequired) { return .inputMonitoringRequired }; return .ready }
    init(store: SettingsStoring, shortcuts: ShortcutCoordinating, permissions: PermissionServing, queue: ExecutionQueueing) {
        let snapshots = ExecutionSnapshotStore()
        self.store = store; self.shortcuts = shortcuts; self.permissions = permissions; self.queue = queue; self.snapshots = snapshots
        self.router = TriggerRouter(snapshots: snapshots, queue: queue, accessibility: permissions.currentAccessibility)
        shortcuts.onTrigger = router.receive
        queue.onResult = { [weak self] result in Task { @MainActor in self?.lastResult = result } }
        queue.onIdleChange = { [weak self] idle in Task { @MainActor in self?.queueIsIdle = idle } }
    }
    func start() { do { let value = try store.load(); runtime = value; draft = value; refreshPermissions(reconcileShortcuts: false); registration = shortcuts.replace(with: value.macros) { snapshots.replace(value.macros) } } catch { runtime = .init(macros: []); draft = .init(macros: []); snapshots.removeAll(); loadError = error } }
    func openSettings() { if loadError != nil { draft = .defaults; showsReplaceWarning = true }; refreshPermissions() }
    func save() { do { try store.save(draft); runtime = draft; loadError = nil; saveError = nil; showsReplaceWarning = false; refreshPermissions(reconcileShortcuts: false); registration = shortcuts.replace(with: runtime.macros) { snapshots.replace(runtime.macros) } } catch { saveError = error } }
    func refreshPermissions(reconcileShortcuts: Bool = true) { _ = permissions.refresh(needsHID: runtime.macros.contains { $0.isEnabled && $0.shortcut.isHIDOnly }); if reconcileShortcuts { registration = shortcuts.replace(with: runtime.macros) { snapshots.replace(runtime.macros) } } }
    func updateMeasurementCount(_ count: Int) { measurementCount = count }
    func shutdown() { shortcuts.shutdown() }
}
```

`ShortcutCoordinator`, `PermissionClient`, `MacroExecutionQueue`를 각각 위 protocol에 conform시킨다. `PermissionClient.currentAccessibility()`는 cached UI state를 읽지 않고 thread-safe한 `AXIsProcessTrusted()`를 호출한다. Carbon과 HID source callback은 어느 run loop/thread에서 와도 `TriggerRouter.receive`를 동기 호출하고, router가 actor 전환 전에 `ExecutionSnapshotStore` lock 안에서 문자열과 후속 키를 복사한다. UI 상태 변경만 `queue.onResult`에서 `MainActor`로 보낸다. 저장 순서는 validation→temporary write→atomic replace→runtime/snapshot 교체→registration 교체다. 저장 실패에는 마지막 두 단계가 실행되지 않는다. 권한 refresh는 shortcut을 다시 조정해 새 권한 부여와 실행 중 철회를 즉시 상태에 반영한다. 항목별 Carbon/HID 실패는 전체 settings error로 올리지 않는다.

`TestDoubles.swift`에 `StoreSpy: SettingsStoring`, `ShortcutSpy: ShortcutCoordinating`, `PermissionSpy: PermissionServing`, `QueueSpy: ExecutionQueueing`을 추가한다. 각 spy는 test 생성자 인수와 mutable 오류를 반환하고 `replaceCalls`, `requests`, `onTrigger`, `onResult`를 그대로 기록한다. `ShortcutSpy.trigger(_:)`는 `onTrigger(id, .now)`를 호출하고 `QueueSpy.reject`는 request 배열을 바꾸지 않은 채 result만 기록한다.

- [x] **Step 4: 검증한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/AppControllerTests`

Expected: `** TEST SUCCEEDED **`; load 오류는 등록 0, save 오류는 기존 runtime과 trigger 유지.

- [x] **Step 5: checkpoint 후보**

conductor는 stage 6 뒤 `wip(task-7): coordinate settings and execution`을 만들 수 있고 builder는 커밋하지 않는다.

### Task 8: 메뉴 바·설정·로그인 실행 UI

**Files:**
- Modify: `apps/macos/Kocro.xcodeproj/project.pbxproj`
- Modify: `apps/macos/Kocro/App/KocroApp.swift`
- Create: `apps/macos/Kocro/Features/MenuBar/MenuBarView.swift`
- Create: `apps/macos/Kocro/Features/Settings/SettingsView.swift`
- Create: `apps/macos/Kocro/Features/Settings/KeyRecorder.swift`
- Create: `apps/macos/Kocro/Features/Settings/LoginItemController.swift`
- Create: `apps/macos/KocroTests/ViewModelTests.swift`
- Create: `apps/macos/KocroTests/LoginItemControllerTests.swift`
- Modify: `apps/macos/KocroTests/Support/TestDoubles.swift`

- [x] **Step 1: 실패 test를 작성한다**

```swift
import XCTest
@testable import Kocro
@MainActor final class ViewModelTests: XCTestCase {
    func testStatusPriorityCountAndUnlimitedEditing() {
        let menu = MenuBarViewModel(statuses: [.accessibilityRequired, .inputMonitoringRequired, .settingsError], registrations: [.registered, .registrationFailed])
        XCTAssertEqual(menu.statusText, "설정 오류"); XCTAssertEqual(menu.registeredCount, 1)
        let settings = SettingsViewModel(settings: .init(macros: []), validator: .init())
        for _ in 0..<30 { settings.add() }; let last = settings.settings.macros[29].id
        settings.move(from: IndexSet(integer: 29), to: 0); settings.delete(at: IndexSet(integer: 1))
        XCTAssertEqual(settings.settings.macros.first?.id, last); XCTAssertEqual(settings.settings.macros.count, 29)
    }
}
final class LoginItemControllerTests: XCTestCase {
    func testDefaultOffAndExplicitToggle() throws {
        let service = LoginServiceSpy(status: .notRegistered), value = LoginItemController(service: service)
        XCTAssertFalse(value.isEnabled); try value.setEnabled(true); try value.setEnabled(false)
        XCTAssertEqual(service.registerCount, 1); XCTAssertEqual(service.unregisterCount, 1)
    }
}
```

- [x] **Step 2: 실패를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/ViewModelTests -only-testing:KocroTests/LoginItemControllerTests`

Expected: view model 타입 부재와 `** TEST FAILED **`.

- [x] **Step 3: 화면을 구현한다**

```swift
struct MenuBarView: View {
    @ObservedObject var app: AppController; @ObservedObject var login: LoginItemController
    var body: some View {
        Text(app.statusText); Text("등록된 매크로 \(app.registration.values.filter { $0 == .registered }.count)개")
        if let result = app.lastResult { Text("매크로 \(result.id.uuidString.prefix(8)) · \(result.shortcut) · \(result.kind.rawValue) · \(result.date.formatted())") }
        if !app.permissions.state.accessibility { Button("Accessibility 권한 안내", action: app.requestAccessibility); Button("Accessibility 설정 열기") { app.openSettings(.accessibility) } }
        if app.permissions.state.inputMonitoring == false { Button("Input Monitoring 권한 요청", action: app.requestInputMonitoring); Button("Input Monitoring 설정 열기") { app.openSettings(.inputMonitoring) } }
        Button("설정…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }; Toggle("로그인 시 실행", isOn: Binding(get: { login.isEnabled }, set: login.setEnabledIgnoringError))
        Button("종료") { app.shutdown(); NSApplication.shared.terminate(nil) }
    }
}
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    var body: some View { VStack {
        if model.showsReplaceWarning { Text("기존 설정 파일을 읽을 수 없습니다. 저장하면 새 설정으로 교체합니다.") }
        if let message = model.saveErrorMessage { Text(message).foregroundStyle(.red) }
        Text("비밀번호, API 키와 인증 토큰을 저장하지 마세요.")
        List { ForEach($model.settings.macros) { $macro in MacroRow(macro: $macro, errors: model.errors(for: macro.id)) }.onDelete(perform: model.delete).onMove(perform: model.move) }
        HStack { Button("추가", action: model.add); Button("저장", action: model.save) }
    } }
}
```

`MacroRow`는 enabled Toggle, 포커스된 `KeyRecorder`, F21~F24 전용 picker, 여러 줄 `TextEditor`, `text.count / 10000`, 없음/Enter/Space/Tab/custom 후속 키 Picker와 UUID별 validation/registration 오류를 표시한다. `KeyRecorder`는 `NSView.keyDown(with:)` 한 건만 기록한다. 일반 키와 F1~F20은 modifier를 함께 변환하고 F13~F20은 단독 입력도 허용한다. F21~F24는 로컬 keyCode로 기록하지 않으며 global `NSEvent` monitor도 만들지 않는다. 삭제·이동·편집은 draft만 바꾸고 Save 전 runtime을 변경하지 않는다.

```swift
@MainActor final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings { didSet { if hasLoadedDraft { isDirty = true } } }; @Published var showsReplaceWarning = false; @Published var saveErrorMessage: String?; @Published var registration: [UUID: RegistrationState] = [:]
    private(set) var isDirty = false; private var hasLoadedDraft = false
    let validator: SettingsValidator; var onSave: ((AppSettings) -> Void)?
    init(settings: AppSettings, validator: SettingsValidator) { self.settings = settings; self.validator = validator }
    func add() { settings.macros.append(.init(id: UUID(), isEnabled: false, shortcut: .init(key: .empty, modifiers: []), text: "", trailingKey: nil)) }
    func delete(at offsets: IndexSet) { settings.macros.remove(atOffsets: offsets) }
    func move(from offsets: IndexSet, to destination: Int) { settings.macros.move(fromOffsets: offsets, toOffset: destination) }
    func errors(for id: UUID) -> [String] {
        guard let macro = settings.macros.first(where: { $0.id == id }) else { return ["항목을 찾을 수 없습니다"] }
        var values: [String] = []
        if macro.text.count > 10_000 { values.append("문자열은 10,000자 이하여야 합니다") }
        if macro.isEnabled && macro.text.isEmpty { values.append("활성 매크로의 문자열이 비어 있습니다") }
        if macro.isEnabled && (try? validator.validateShortcut(macro.shortcut)) == nil { values.append("단축키를 수정하세요") }
        if let trailing = macro.trailingKey, (try? validator.validateTrailing(trailing)) == nil { values.append("후속 키를 수정하세요") }
        if settings.macros.filter({ $0.id == macro.id }).count > 1 { values.append("항목 ID가 중복됩니다") }
        if settings.macros.filter({ $0.isEnabled && $0.shortcut == macro.shortcut }).count > 1 { values.append("활성 단축키가 중복됩니다") }
        if let state = registration[id], state != .registered { values.append(String(describing: state)) }
        return values
    }
    func save() { guard (try? validator.validate(settings)) != nil else { saveErrorMessage = "표시된 항목을 수정한 뒤 다시 저장하세요"; return }; saveErrorMessage = nil; onSave?(settings) }
    func loadDraftIfNeeded(from app: AppController) { guard !hasLoadedDraft else { return }; settings = app.draft; hasLoadedDraft = true; isDirty = false; synchronizeStatus(from: app) }
    func synchronizeStatus(from app: AppController) { showsReplaceWarning = app.showsReplaceWarning; registration = app.registration; if let error = app.saveError { saveErrorMessage = "설정을 저장하지 못했습니다 (\(String(describing: type(of: error))))" } }
    func markSaved(_ value: AppSettings) { settings = value; isDirty = false; saveErrorMessage = nil }
}
struct MenuBarViewModel {
    let statuses: [OverallStatus]; let registrations: [RegistrationState]
    var statusText: String { if statuses.contains(.settingsError) { return "설정 오류" }; if statuses.contains(.inputMonitoringRequired) { return "Input Monitoring 권한 필요" }; if statuses.contains(.accessibilityRequired) { return "Accessibility 권한 필요" }; return "준비됨" }
    var registeredCount: Int { registrations.filter { $0 == .registered }.count }
}
```

`AppController`에 `statusText` computed property와 `requestAccessibility()`, `requestInputMonitoring()`, `openSettings(_ kind: PrivacyKind)`을 추가해 `PermissionClient`로 위임한다. app startup이 끝난 뒤 `SettingsViewModel`을 생성한다. 메뉴의 설정 버튼은 `app.openSettings(); settingsModel.loadDraftIfNeeded(from: app); settingsModel.synchronizeStatus(from: app)`을 호출한 다음 설정 창을 연다. model이 편집 draft의 단일 소유자이며 `synchronizeStatus`는 `settings`를 덮어쓰지 않는다. `onSave`는 controller draft를 전달받은 값으로 바꾸고 `app.save()`한다. 성공하면 `markSaved(app.draft)`, 실패하면 dirty draft를 유지한 채 `synchronizeStatus`만 호출한다. 권한 refresh와 registration 변경에도 `synchronizeStatus`만 호출하므로 저장 전 편집은 유지된다. `MacroRow`는 binding과 UUID별 오류 배열만 렌더링하는 별도 `View`로 같은 `SettingsView.swift`에 정의한다.

- [x] **Step 4: 로그인과 실제 dependency 조립을 구현한다**

```swift
import ServiceManagement
protocol LoginService { var status: SMAppService.Status { get }; func register() throws; func unregister() throws }
final class LoginItemController: ObservableObject {
    let service: LoginService; @Published private(set) var isEnabled: Bool
    init(service: LoginService) { self.service = service; isEnabled = service.status == .enabled }
    func setEnabled(_ enabled: Bool) throws { if enabled { try service.register() } else { try service.unregister() }; isEnabled = service.status == .enabled }
    func setEnabledIgnoringError(_ enabled: Bool) { try? setEnabled(enabled) }
}
```

`KocroApp`의 `@StateObject` container에서 JSON file, Carbon, HID, permissions, CGEvent poster, queue, `SMAppService.mainApp`을 한 번 생성해 두 scene에 전달한다. 설정 열기는 macOS 13에서 동작하는 `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`을 사용하고 macOS 14 전용 `SettingsLink`는 사용하지 않는다. 앱 시작에 `start`, 활성화와 menu 표시 때 `refreshPermissions`, 종료에 `shutdown`을 호출한다.

`TestDoubles.swift`에 `LoginServiceSpy: LoginService`를 추가해 mutable `status`, `registerCount`, `unregisterCount`를 기록한다. `register()`는 status를 `.enabled`, `unregister()`는 `.notRegistered`로 바꾼다.

- [x] **Step 5: 검증한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/ViewModelTests -only-testing:KocroTests/LoginItemControllerTests && xcodebuild build -project apps/macos/Kocro.xcodeproj -scheme Kocro -configuration Release CODE_SIGNING_ALLOWED=NO`

Expected: test/build 성공, 30개 항목 편집 성공, 기본 login off.

- [x] **Step 6: checkpoint 후보**

conductor는 stage 6 뒤 `wip(task-8): add menu bar and settings UI`를 만들 수 있고 builder는 커밋하지 않는다.

### Task 9: 자동 통합·보안 범위 검증

**Files:**
- Modify: `apps/macos/Kocro.xcodeproj/project.pbxproj`
- Create: `apps/macos/KocroTests/MacroPipelineIntegrationTests.swift`
- Create: `apps/macos/KocroTests/PrivacyTests.swift`

- [x] **Step 1: 실패 test를 작성한다**

```swift
import XCTest
@testable import Kocro
@MainActor final class MacroPipelineIntegrationTests: XCTestCase {
    func testOneHundredRapidTriggersPreserveSnapshots() async {
        let harness = PipelineHarness(accessibility: true), macros = (0..<100).map { Fixtures.macro(text: "value-\($0)") }
        harness.install(macros); macros.forEach { harness.trigger($0.id) }; await harness.drain()
        XCTAssertEqual(harness.postedTexts, (0..<100).map { "value-\($0)" }); XCTAssertEqual(harness.maximumConcurrentPosts, 1)
    }
    func testFailedSaveKeepsOldThenSuccessfulSaveSwitches() async {
        let harness = PipelineHarness(accessibility: true); harness.install([Fixtures.macro(text: "old")])
        harness.editText("new"); harness.failNextSave(); harness.saveAndTrigger(); await harness.drain(); XCTAssertEqual(harness.postedTexts, ["old"])
        harness.saveAndTrigger(); await harness.drain(); XCTAssertEqual(harness.postedTexts, ["old", "new"])
    }
}
final class PrivacyTests: XCTestCase {
    func testResultDescriptionHasNoTextOrApp() { let value = ExecutionResult(id: UUID(), shortcut: "F13", kind: .postingRequested, date: .init(timeIntervalSince1970: 0)); XCTAssertFalse(value.description.contains("secret")); XCTAssertFalse(value.description.contains("TextEdit")) }
}
```

- [x] **Step 2: 실패를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/MacroPipelineIntegrationTests -only-testing:KocroTests/PrivacyTests`

Expected: `PipelineHarness` 부재와 `** TEST FAILED **`.

- [x] **Step 3: test harness를 구현한다**

```swift
@MainActor final class PipelineHarness {
    let store = StoreSpy(load: .success(.init(macros: []))), shortcuts = ShortcutSpy(), poster = RecordingBatchPoster()
    lazy var queue = MacroExecutionQueue(poster: poster, accessibility: { true })
    lazy var app = AppController(store: store, shortcuts: shortcuts, permissions: PermissionSpy(accessibility: true), queue: queue)
    var postedTexts: [String] { poster.texts }; var maximumConcurrentPosts: Int { poster.maximumConcurrent }
    init(accessibility: Bool) {}
    func install(_ macros: [MacroDefinition]) { store.loadResult = .success(.init(macros: macros)); app.start() }
    func trigger(_ id: UUID) { shortcuts.trigger(id) }; func drain() async { await queue.drain() }
    func editText(_ text: String) { app.draft.macros[0].text = text }; func failNextSave() { store.failOnce(.io) }
    func saveAndTrigger() { app.save(); shortcuts.trigger(app.runtime.macros[0].id) }
}
```

`RecordingBatchPoster`는 text 순서와 동시 진입 수만 기록하고 production target에는 포함하지 않는다.

`StoreSpy.failOnce(_:)`는 다음 `save` 호출에서 오류를 local 변수로 옮기고 저장된 오류를 nil로 지운 뒤 throw한다. 이후 `save`는 전달된 값을 `loadResult`에 반영하므로 두 번째 저장은 성공한다.

- [x] **Step 4: 전체 자동 검증을 실행한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' && ! rg -n 'CGEventTap|addGlobalMonitorForEvents|NSPasteboard|Process\(|NSTask|URLSession|F2[5-9]|F3[0-5]' apps/macos/Kocro && ! find apps -maxdepth 1 -type d \( -name windows -o -name linux -o -name shared \) | grep .`

Expected: 전체 test 성공, 금지 API·F25~F35·Windows/Linux/shared 결과 없음.

- [x] **Step 5: checkpoint 후보**

conductor는 stage 6 뒤 `wip(task-9): verify macro pipeline`을 만들 수 있고 builder는 커밋하지 않는다.

### Task 10: 실제 macOS·Release 성능 검증과 문서 갱신

**Files:**
- Modify: `apps/macos/Kocro.xcodeproj/project.pbxproj`
- Create: `apps/macos/Kocro/Input/PostingLatencyRecorder.swift`
- Create: `apps/macos/KocroTests/PostingLatencyRecorderTests.swift`
- Create: `documents/reference/macos-macro-text-input-verification.md`
- Modify: `documents/reference/README.md`

- [x] **Step 1: 실패 test를 작성한다**

```swift
import XCTest
@testable import Kocro
final class PostingLatencyRecorderTests: XCTestCase {
    func testNearestRank() throws { let report = try PostingLatencyRecorder.report((1...100).reversed().map(Double.init)); XCTAssertEqual(report.p50, 50); XCTAssertEqual(report.p95, 95); XCTAssertEqual(report.samples.count, 100) }
    func testRequiresOneHundred() { XCTAssertThrowsError(try PostingLatencyRecorder.report([1, 2])) }
}
```

- [x] **Step 2: 실패를 확인한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' -only-testing:KocroTests/PostingLatencyRecorderTests`

Expected: recorder 부재와 `** TEST FAILED **`.

- [x] **Step 3: 계산을 구현한다**

```swift
struct LatencyReport: Codable { let samples: [Double]; let p50: Double; let p95: Double }
enum LatencyError: Error { case sampleCount }
enum PostingLatencyRecorder {
    static func report(_ values: [Double]) throws -> LatencyReport { guard values.count == 100 else { throw LatencyError.sampleCount }; let sorted = values.sorted(); return .init(samples: values, p50: sorted[49], p95: sorted[94]) }
}
final class MeasurementSession {
    let enabled = CommandLine.arguments.contains("--measure-posting-latency")
    private let lock = NSLock(); private(set) var samples: [Double] = []; var onProgress: ((Int) -> Void)?
    func record(receivedAt: ContinuousClock.Instant, postedAt: ContinuousClock.Instant) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, samples.count < 100 else { return }
        let duration = receivedAt.duration(to: postedAt).components
        samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
        onProgress?(samples.count)
        if samples.count == 100 {
            let report = try PostingLatencyRecorder.report(samples)
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.caost.Kocro/posting-latency.json")
            try JSONEncoder().encode(report).write(to: url, options: .atomic)
        }
    }
}
```

Carbon/HID callback의 첫 줄에서 `ContinuousClock.now`를 `ExecutionRequest.receivedAt`에 복사한다. 실제 poster는 마지막 `CGEvent.post`가 반환된 뒤 `try? measurement.record(receivedAt: request.receivedAt, postedAt: .now)`를 별도 문장으로 호출한다. 기록 저장 실패는 OSLog에 오류 종류만 남기며 이미 게시된 요청의 `postingRequested` 결과를 바꾸거나 `eventCreationFailed`로 변환하지 않는다. `KocroApp` container가 `MeasurementSession`을 생성하고 `--measure-posting-latency` argument가 있을 때만 poster에 연결한다. container는 `measurement.onProgress = { count in Task { @MainActor in app.updateMeasurementCount(count) } }`로 `measurementCount`를 갱신하고, queue의 `onIdleChange`는 `queueIsIdle`을 MainActor에서 갱신한다. 메뉴 바는 측정 mode일 때 `측정 \(measurementCount)/100 · \(queueIsIdle ? "queue empty" : "게시 중")`을 표시한다. 수신 instant부터 마지막 게시 반환까지 측정하며 대상 앱 화면 반영은 제외한다. 검증자는 queue empty가 된 뒤 다음 키를 눌러 queue 대기를 0으로 유지한다. 앱은 100번째 sample 뒤 report를 저장하고, 실행마다 외부 process를 시작하지 않는다.

- [x] **Step 4: build를 검증한다**

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' && xcodebuild build -project apps/macos/Kocro.xcodeproj -scheme Kocro -configuration Release -derivedDataPath apps/macos/build CODE_SIGNING_ALLOWED=NO`

Expected: `** TEST SUCCEEDED **`, `** BUILD SUCCEEDED **`.

- [ ] **Step 5: 실제 결과를 기록한다**

설정에서 F13 macro를 활성화하고 정확히 100개의 ASCII `a`를 저장한 뒤 Release 앱을 종료한다. Run: `open "$(pwd)/apps/macos/build/Build/Products/Release/Kocro.app" --args --measure-posting-latency`. 메뉴 바의 queue empty와 `측정 N/100`을 확인하면서 F13을 100회 누른다. 앱은 한 번만 시작하며 각 shortcut 실행에서 process를 만들지 않는다.

`documents/reference/macos-macro-text-input-verification.md`에 canonical frontmatter와 다음 행을 만들고 날짜, macOS/app version, 실제 결과, pass/fail을 채운다: TextEdit 한글 입력기에서 한글·영문·여러 줄·emoji·조합 문자; Safari 또는 Chromium; Terminal; VS Code; 빠른 여러 shortcut; Accessibility 없음/실행 중 철회; F21~F24 활성 전후와 Input Monitoring 없음/철회; 포커스 앱도 F21 처리하는 HID 비독점; Carbon 충돌; 종료 자원 해제; 메뉴 바에서 로그인 시 실행을 켜고 macOS 로그인 항목에 나타나는지 확인한 뒤 다시 꺼서 제거되는지 확인. HID monitor 시작 실패는 Task 4의 deterministic `HIDSpy(starts: false)` test 결과로 검증 문서의 자동 검증 절에 기록하고 실제 환경에서 재현하도록 요구하지 않는다. 상태는 `게시 요청 완료`까지만 판정한다.

같은 문서에 100회 원시 ms, p50, p95, Release, 100자 ASCII, queue 대기 제외, 이전 게시 완료 뒤 다음 측정, 외부 process 0회를 실제 값으로 기록한다. 첫 버전은 환경별 기준값 수집 단계라 통과 임계값이 없다는 점도 명시한다. `documents/reference/README.md`에 문서 링크를 등록한다.

Run: `test "$(jq '.samples | length' "$HOME/Library/Application Support/com.caost.Kocro/posting-latency.json")" -eq 100 && jq '{p50,p95}' "$HOME/Library/Application Support/com.caost.Kocro/posting-latency.json"`

Expected: exit 0, 숫자 p50/p95 출력, 검증 문서에 같은 실제 값이 기록됨.

- [x] **Step 6: 개인정보와 범위를 확인한다**

Run: `! rg -n 'TODO|TBD|실행 후 기록|NSPasteboard|Process\(|NSTask|URLSession|retry|focused(App|Application)' documents/reference/macos-macro-text-input-verification.md apps/macos/Kocro`

Expected: exit 0, 출력 없음. 문자열·활성 앱 이름·fallback·retry·외부 실행이 없다.

- [x] **Step 7: stage 9 formal commit 소유권**

builder는 브랜치를 변경하거나 커밋하지 않는다. conductor는 stage 6 checkpoint를 보존한 채 stage 9 승인을 기다린다. 승인 뒤 checkpoint를 정리하고 checkpoint의 파일을 하나도 누락하지 않은 채 전체 이슈 변경을 다음 논리 단위 formal commit으로 구성한다.

```text
feat(macos): add Kocro settings domain and persistence
feat(macos): register Carbon and HID macro shortcuts
feat(macos): queue complete Unicode input batches
feat(macos): add menu bar settings and login controls
test(macos): verify macro input acceptance behavior
docs: record macOS macro verification
```

각 formal commit은 production 코드와 대응 test를 함께 포함한다. 단일 generic commit으로 합치지 않는다.

## 수용 기준 연결

| 기준 | task | 검증 |
| --- | --- | --- |
| 1. macOS 13 메뉴 바·설정 | 1, 8 | smoke, Release, 실제 UI |
| 2. 무제한 UUID 항목·저장 | 2, 3, 8 | validation, round-trip, 30개 UI |
| 3. 키 규칙·Carbon/HID·조건부 권한 | 2, 4, 5 | matrix, usage, API 호출 수 |
| 4. 한글 입력기 Unicode | 6, 10 | cluster test, TextEdit |
| 5. 후속 키 1회·생성 실패 게시 0 | 6 | event 순서와 실패 test |
| 6. 빠른 FIFO | 6, 9 | 동시 게시 1, 100 요청 |
| 7. 권한·로드·등록·HID·저장 오류 | 3~7, 10 | 항목 상태, 게시 차단, rollback, 실제 철회 |
| 8. clipboard fallback·retry 없음 | 6, 9, 10 | 게시 수와 정적 검색 |
| 9. 문자열·활성 앱 비노출 | 3, 6~10 | 결과/UI/log/doc 검사 |
| 10. Release 100회 p50/p95 기준값 | 10 | 원시 100개와 nearest-rank, 임계값 없음 명시 |
| 11. 로그인 시 실행 기본값·전환 | 8 | `LoginItemControllerTests`, 실제 메뉴 전환 |

## 완료 전 검증

Run: `xcodebuild test -project apps/macos/Kocro.xcodeproj -scheme Kocro -destination 'platform=macOS' && xcodebuild build -project apps/macos/Kocro.xcodeproj -scheme Kocro -configuration Release CODE_SIGNING_ALLOWED=NO && ! rg -n 'AIMacro|com\.caost\.AIMacro|CGEventTap|addGlobalMonitorForEvents|NSPasteboard|Process\(|NSTask|URLSession' apps/macos/Kocro documents/reference/macos-macro-text-input-verification.md`

Expected: 전체 XCTest와 Release build 성공, 잘못된 이름과 금지 API 없음, 검증 문서에 실제 기능 결과와 100개 측정값·p50·p95가 모두 기록됨.
