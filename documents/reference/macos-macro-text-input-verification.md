---
type: reference
title: macOS 매크로 텍스트 입력 검증 기록
created: 2026-09-04
updated: 2026-09-07
related:
  - documents/spec/platform/macos-macro-text-input.md
  - documents/plan/archive/20260904-1213-macos-macro-text-input.md
---

# macOS 매크로 텍스트 입력 검증 기록

## 판정 범위

자동 테스트와 빌드는 구현 동작을 검증한다. 서명된 앱, macOS TCC 권한과 실제 키보드 입력이 필요한 항목은 별도의 실제 앱 검증으로 판정한다. `CGEvent.post`는 대상 앱 반영 결과를 제공하지 않으므로 입력 실행 상태는 `게시 요청 완료`까지만 판정한다.

2026-09-07 issue #8 후속 결정으로 F21~F24의 선택·저장·실행 지원을 제거했다. 이 문서의
기존 F21~F24와 Input Monitoring 검증 결과는 당시 구현의 이력이며 현재 지원 범위를
뜻하지 않는다. 현재 앱은 F13~F20까지만 지원하고, 기존 F21~F24 설정은 항목 내용과
순서를 유지한 채 비활성·빈 단축키로 마이그레이션한다.

## 2026-09-07 issue #8 후속 검증

- F21~F24와 HID/Input Monitoring 전용 테스트를 제품 경로와 함께 제거한 뒤 전체
  XCTest 169개가 통과했고 실패·건너뛴 테스트는 없다.
- 기본 매크로와 자동완성은 F13~F20까지만 제공하고 F21~F35 직접 입력·키 기록을
  거부하는 자동 테스트를 통과했다.
- 기존 F21~F24 JSON은 UUID, 제목, 문자열, 후속 키와 배열 순서를 보존하고 해당 항목만
  비활성·빈 단축키로 바꾸는 마이그레이션 테스트를 통과했다.
- 실제 Release 앱에서 새 매크로의 F21~F24 선택 메뉴가 제거된 것을 확인했다.
- `⌥⌘I`를 기록하면 실행 단축키 입력란에 `{KC_OPT}+{KC_CMD}+{KC_I}`가 표시되고,
  기록 버튼은 계속 `키로 기록`으로 표시되는 것을 확인했다.
- 설정 창이 열려 있을 때 activation policy가 regular(0), 닫은 뒤 accessory(1)인 것을
  확인했다.

## 2026-09-07 issue #6 확장 검증

검증 환경은 macOS 26.6.2(25G83), Xcode 26.6(17F113), Apple Silicon(arm64)이다. 자동 테스트는 현재 작업 트리에서 실행했고, 실제 앱 검증은 Release 앱을 `Kocro Local Development` 인증서와 Hardened Runtime으로 서명한 뒤 수행했다. 기존 사용자 설정은 내용에 접근하지 않고 복사본으로 보존했으며 검증 종료 뒤 원본을 복구했다.

| 검증 항목 | 결과 |
| --- | --- |
| 전체 XCTest | 148개 통과, 실패 0개 |
| unsigned Release build | 성공 |
| 로컬 개발 인증서 Release build | 성공, `codesign --verify --strict` 통과 |
| 금지 API | `CGEventTap`, global monitor, pasteboard, 외부 프로세스, network API, F25~F35 사용 0건 |
| 외부 package | Xcode remote package reference와 product dependency 0건 |
| build setting | `com.caost.Kocro`, macOS 13.0 확인 |

실제 앱에서는 title 키가 없는 두 항목을 로드해 `매크로 1`, `매크로 2`로 보완되는 것을 확인했다. 저장 뒤 두 title 키가 생겼고 UUID, 활성 상태, shortcut, 텍스트, 후속 키는 유지됐다. 제목을 `기존 제목`에서 `편집한 제목`으로 직접 편집했으며, 빈 제목 표시와 항목 추가·삭제·드래그 정렬도 확인했다. 저장된 F13 매크로의 텍스트를 설정 화면에서 `저장하지 않은 텍스트`로 바꾸고 저장하지 않은 채 F13을 실행했을 때 TextEdit에는 기존 실행 설정인 `저장된 텍스트`가 입력돼, 편집 draft와 실행 설정이 분리되는 것을 실제 앱에서 확인했다.

shortcut 입력은 modifier와 기준 키를 개별 토큰으로 표시했다. F21 picker 선택은 기존 F13 전체를 F21로 교체했고, 새 키 입력은 F21 전체를 새 modifier·기준 키 조합으로 교체했다. Escape는 값을 유지하고 focus를 해제했으며 Delete와 Backspace는 각각 값을 `설정 안 됨`으로 바꿨다. Backspace는 key code 51을 입력한 뒤 접근성 값이 `F13`에서 `설정 안 됨`으로 바뀐 것을 확인했다. 사용자 지정 후속 키는 `⌃ Control`, `⌥ Option`, `B` 세 토큰을 기록했고 별도 `지우기` 버튼은 후속 키를 `없음`으로 바꿨다.

일반 탭은 로그인 항목 상태와 Accessibility 제어를 표시했고, 저장 전 draft에서 F21을 선택하자 Input Monitoring 영역을 추가로 표시했다. 메뉴 바의 `설정…`은 설정 창을 열었고 `Kocro 정보`는 앱 아이콘, `Kocro`, `Version 1.0 (1)`을 포함한 표준 About 패널을 열었다. `종료`를 누른 뒤 Kocro 프로세스가 종료되는 것도 확인했다.

`Kocro Local Development` 인증서에 연결된 Accessibility 권한으로 F13을 합성해 TextEdit와 Chrome에 `한글 Hello café 👨‍👩‍👧‍👦`가 그대로 입력되는 것을 확인했다. TextEdit에서는 줄바꿈을 포함한 둘째 줄도 유지됐다. modifier가 있는 합성 Carbon key event는 이번 실행에서 macOS가 hotkey callback으로 전달하지 않아 현재 빌드의 FIFO 실제 입력은 재측정하지 못했다. 2026-09-04 실측의 빠른 연속 입력 결과와 현재 `MacroExecutionQueueTests`의 최대 동시 실행 1·FIFO 검증을 함께 근거로 남긴다.

저장된 활성 F21 설정은 Input Monitoring 허용 상태에서 전체 상태 `준비됨`, 등록된 매크로 1개를 표시해 조건부 권한 조회와 monitor 시작을 확인했다. draft에서 F21을 선택하거나 해제할 때 일반 탭의 Input Monitoring 영역이 함께 표시되거나 사라지는 것도 확인했다. 실행 중 Input Monitoring 철회는 시스템 설정 변경에 사용자 인증이 필요해 미판정이다. 물리 F21~F24 트리거 전달과 포커스 앱 비독점 동작은 VIA 키보드가 없어 미판정이다.

정식 배포 로그인 항목은 로컬 개발 빌드에서 `SMAppService.mainApp`가 `notFound`를 반환해 criterion 11의 실제 반영이 미판정이다. Carbon 중복 등록은 macOS가 허용했고 실제 등록 실패를 유발할 예약 shortcut을 확보하지 못해 criterion 13의 실제 충돌은 미판정이다. 충돌 항목만 disabled로 저장하고 저장 뒤 ownership을 commit하는 순서는 `AppControllerTests.testCarbonCollisionPersistsDisabledCandidateBeforeCommittingOwnership`, 저장 실패 시 candidate를 cancel하고 runtime·route·draft를 보존하는 동작은 `AppControllerTests.testCandidateSaveFailureCancelsOnceAndPreservesRuntimeRoutesSnapshotAndDraft`가 검증했다. criterion 14의 일반 설정과 메뉴 액션은 실제 앱에서 통과했다.

## 자동 검증

검증일은 2026-09-04이며 앱 버전은 1.0(빌드 1)이다. 자동 검증 환경은 macOS 26.6.2(25G83), Xcode 26.6(17F113), Apple Silicon이다.

| 검증 항목 | 근거 | 결과 |
| --- | --- | --- |
| 전체 XCTest | `xcodebuild test` | 90개 통과, 실패 0개 |
| Thread Sanitizer XCTest | `xcodebuild test -enableThreadSanitizer YES` | 90개 통과, data race 보고 0개 |
| Release 빌드 | `xcodebuild build -configuration Release` | 성공, ad hoc 서명과 Hardened Runtime을 적용한 `apps/macos/build/Build/Products/Release/Kocro.app` 생성 |
| 100개 샘플 nearest-rank와 동시 수집 | `PostingLatencyRecorderTests` | 7개 통과, 첫 100개 제한·p50=50·p95=95·이전 결과 무효화 확인 |
| HID monitor 시작 실패 | `ShortcutCoordinatorTests.testHIDPermissionAndStartFailuresLeaveCarbonRegistered`의 `HIDSpy(starts: false)` | 통과, HID 실패 상태와 Carbon 등록 유지 확인 |
| 금지 API와 실행 범위 | 정적 검색 | 금지 항목 0개 |

표준·스펙 리뷰 지적 사항을 반영한 뒤 위 여섯 항목을 같은 명령으로 다시 실행했고 결과는 같았다. 테스트 90개 통과, Thread Sanitizer 90개 통과와 data race 0개, Release 빌드 성공, ad hoc 서명과 Hardened Runtime 유지, `codesign --verify --strict` 통과, 금지 API 0건이다.

## 실제 앱 검증

아래 항목은 서명된 앱과 TCC 권한, 실제 키보드 입력이 필요한 검증이다. 텍스트 반영(TextEdit·Safari·Chrome·VS Code), FIFO 순서, 시작 시 권한 없음은 `CGEvent` 합성으로 실측해 통과로 판정했다. F21~F24는 VIA 키보드, 로그인 항목은 정식 서명·배포, Carbon 등록 충돌은 macOS 예약 단축키가 필요해 미실행으로 남기고 해당 실패 경로는 단위 테스트로 검증했다.

검증일 2026-09-04. `CGEvent`로 트리거 단축키를 합성하고 대상 앱 내용을 클립보드로 읽어 비교했다. 실제 modifier 병합을 재현하려고 ⌃⌥⌘을 홀드한 채 트리거를 게시했다.

| 대상·조건 | 실제 결과 | 판정 |
| --- | --- | --- |
| TextEdit, 한글·영문·여러 줄·이모지·조합 문자 | 게시된 텍스트가 설정과 동일(⌃⌥⌘9 트리거) | 통과 |
| Safari, Chrome 입력 필드 | 주소창에 유니코드·이모지·조합 문자가 설정과 동일하게 입력 | 통과 |
| VS Code | 편집기에 설정과 동일하게 입력 | 통과 |
| 여러 단축키를 빠르게 입력한 FIFO 순서 | ⌃⌥⌘1~4 빠른 연속 게시가 `[[A]][[B]][[C]][[D]]` 순서로 누락 없이 입력 | 통과 |
| Accessibility 권한 없음(시작 시) | 전체 상태 `Accessibility 권한 필요`, 트리거 시 결과가 `Accessibility 권한 필요`이고 이벤트 미게시 | 통과 |
| 실행 중 Accessibility 권한 철회 | macOS가 실행 중 프로세스의 신뢰 상태를 캐시해 앱은 즉시 감지하지 못하고 `게시 요청 완료`로 기록하나, 시스템이 실제 주입을 차단해 대상 앱에 텍스트가 들어가지 않음 | 부분 |
| Terminal | Terminal.app 미설치로 미실행 | 미판정 |
| F21~F24 활성화 전후의 Input Monitoring 요청 조건 | F21~F24 물리 입력에 VIA 키보드가 필요해 미실행. 단위 테스트로 검증(`ShortcutCoordinatorTests`) | 미판정 |
| Input Monitoring 권한 없음과 실행 중 철회 | 위와 같은 이유로 미실행 | 미판정 |
| 포커스된 앱도 F21~F24를 처리하는 HID 비독점 동작 | 위와 같은 이유로 미실행 | 미판정 |
| 다른 앱과 Carbon 단축키 충돌 | 다른 프로세스가 같은 전역 hotkey를 등록해도 `RegisterEventHotKey`가 모두 성공(Carbon이 중복 등록 허용)해 재현되지 않음. 실제 등록 실패는 macOS 예약 단축키에서만 발생하며 단위 테스트로 검증(`CarbonSpy(failingRegistration)`) | 미판정 |
| 앱 종료 시 Carbon·HID 자원 해제 | `NSApplication.willTerminateNotification` 연결과 단위 테스트로 검증(실측 미실행) | 미판정 |
| 메뉴 바에서 로그인 시 실행 활성화·비활성화 후 macOS 로그인 항목 반영 | ad hoc 서명·미배포 앱이라 `SMAppService.mainApp` 상태가 `notFound`(메뉴에 `로그인 항목을 찾지 못했습니다` 표시). 정식 서명·배포 앱이 필요해 미실행 | 미판정 |

미판정 항목은 실행 중인 macOS 데스크톱 세션에서 Release 앱에 Accessibility 권한을 부여하고 대상 앱마다 실제 키를 눌러 화면 반영을 눈으로 확인해야 하며, F21~F24는 VIA 키보드가 필요하다. 자동 테스트로는 대체할 수 없어 미실행 상태로 남긴다. 반면 아래 게시 지연 기준값은 대상 앱 화면 반영과 무관하게 게시 API 호출 완료까지만 재므로 실측을 수행했다.

### 유니코드 게시 modifier 병합 수정

SPEC-002 실제 앱 검증 중, 일반 키 조합(예: ⌃⌥⌘9) 트리거로는 게시 요청이 완료돼도 대상 앱에 문자가 삽입되지 않는 문제를 확인했다. 원인은 유니코드 `CGEvent`가 `flags`를 명시하지 않아, 트리거 보조 키(⌃⌥⌘)가 눌린 상태로 `.cghidEventTap`에 게시될 때 시스템이 그 보조 키를 병합하고 대상 앱이 문자를 단축키로 해석한 것이다. 유니코드 이벤트의 `flags`를 비우도록 고쳤다. 수정 뒤 ⌃⌥⌘9 트리거로 TextEdit에 `한글 Hello café 👨‍👩‍👧‍👦`와 둘째 줄이 설정과 동일하게 입력되는 것을 실제 앱에서 확인했다. F13처럼 보조 키 없는 트리거는 이 문제에 걸리지 않았다.

## Release 게시 지연 기준값

첫 버전은 환경별 기준값 수집 단계이므로 통과 임계값을 두지 않는다. 측정 범위는 단축키 콜백이 받은 시점부터 마지막 `CGEvent.post` 반환까지다. 대상 앱의 화면 반영 시간은 포함하지 않는다.

측정일은 2026-09-07이며 환경은 macOS 26.6.2(25G83), Apple Silicon(arm64), Xcode 26.6이다. Accessibility 권한을 부여하고 `Kocro Local Development` 인증서로 서명한 Release 앱을 `--measure-posting-latency`로 실행했다. F13(가상 키 코드 105) 매크로를 활성화해 100자 ASCII `a`를 게시하도록 설정한 뒤 트리거를 100회 보냈다. 트리거는 물리 키보드 대신 `CGEvent`로 합성해 200ms 간격으로 게시했고, 각 트리거 사이에 큐가 비므로 큐 대기는 측정에 섞이지 않는다.

| 항목 | 값 |
| --- | --- |
| 빌드 | Release, `Kocro Local Development` 서명과 Hardened Runtime |
| 입력 문자열 | ASCII `a` 100자 |
| 샘플 수 | 100개 |
| p50 | 1.453 ms |
| p95 | 3.273 ms |
| 최소 / 최대 | 0.708 ms / 9.757 ms |
| 평균 | 1.730 ms |
| 큐 대기 | 트리거 사이 200ms 간격으로 게시해 매 트리거 시점에 큐가 비어 있었다(측정 제외) |
| 외부 프로세스 시작 횟수 | 0회. 구현 정적 검색 0건, 실측 중에도 매크로 실행마다 프로세스를 시작하지 않았다 |

원시 100개 샘플과 p50·p95는 `~/Library/Application Support/com.caost.Kocro/posting-latency.json`에 저장했다. 이 경로는 사용자 홈 아래 앱 전용 파일이라 저장소에 포함하지 않는다.

단위는 ms이며 기록 순서는 측정 순서와 같다.

```json
[9.756542,1.626208,1.795666,3.915375,1.0815,2.846333,1.225958,1.711375,2.162792,0.873459,3.887625,0.707584,1.255875,0.766292,0.765958,0.801959,2.233375,1.934208,2.809083,4.077292,2.096375,5.417584,3.251459,3.195875,1.195417,1.590875,1.629541,1.524375,3.273042,1.567459,1.753542,1.854541,3.09375,1.210916,0.961042,0.840333,0.992875,0.729458,1.508333,0.765875,1.359041,1.393458,1.985333,0.916417,1.749,0.825083,0.88,1.550542,1.294792,0.745166,2.254917,1.4875,1.076875,0.947625,2.154875,2.555416,0.976959,3.223667,1.253166,2.053292,0.711084,0.838333,1.089375,0.922459,1.397709,1.216875,1.789333,1.459917,1.977,1.32225,2.178042,3.017958,0.753542,1.216125,2.845834,1.295875,1.820875,1.145792,1.468917,1.597292,2.681667,1.452791,1.53725,1.561834,0.9675,1.042542,2.268083,2.056042,0.763958,0.973292,1.289583,1.343709,1.404,0.849084,0.75625,1.527333,1.392959,1.085292,0.946834,1.6365]
```

실제 측정은 `--measure-posting-latency` 인자로 Release 앱을 한 번 시작한다. 측정 모드가 시작되면 이전 결과 파일을 제거하므로 새 결과가 생기기 전에는 해당 경로가 없어야 한다. 메뉴 바의 `측정 N/100`과 `큐 비어 있음`을 확인하면서 F13을 100회 입력한다. 결과 파일은 `~/Library/Application Support/com.caost.Kocro/posting-latency.json`이며 원시 100개 샘플과 p50·p95가 있어야 한다.

앱을 시작하기 전에 아래 준비 명령을 같은 셸에서 실행한다. 기존 결과 파일을 제거하지 못하면 앱을 시작하지 않고, 실행별 표식을 남긴다.

```sh
kocro_report="$HOME/Library/Application Support/com.caost.Kocro/posting-latency.json"
kocro_marker="$(mktemp -t kocro-measurement)" &&
rm -f "$kocro_report" &&
test ! -e "$kocro_report" &&
open "$(pwd)/apps/macos/build/Build/Products/Release/Kocro.app" --args --measure-posting-latency
```

100회 입력이 끝나면 같은 셸에서 아래 명령을 실행한다. `-nt`는 결과 파일이 실행별 표식보다 엄격하게 새 파일인지 확인하므로, 같은 초에 생성된 이전 파일도 현재 결과로 통과하지 않는다.

```sh
test "$kocro_report" -nt "$kocro_marker" &&
test "$(jq '.samples | length' "$kocro_report")" -eq 100 &&
jq -e '.p50 | numbers' "$kocro_report" >/dev/null &&
jq -e '.p95 | numbers' "$kocro_report" >/dev/null &&
rm -f "$kocro_marker"
```
