---
type: reference
title: macOS 매크로 텍스트 입력 검증 기록
created: 2026-09-04
updated: 2026-09-04
related:
  - documents/spec/platform/macos-macro-text-input.md
  - documents/plan/20260904-1213-macos-macro-text-input.md
---

# macOS 매크로 텍스트 입력 검증 기록

## 판정 범위

자동 테스트와 빌드는 구현 동작을 검증한다. 서명된 앱, macOS TCC 권한과 실제 키보드 입력이 필요한 항목은 별도의 실제 앱 검증으로 판정한다. `CGEvent.post`는 대상 앱 반영 결과를 제공하지 않으므로 입력 실행 상태는 `게시 요청 완료`까지만 판정한다.

## 자동 검증

검증일은 2026-09-04이며 앱 버전은 1.0(빌드 1)이다. 자동 검증 환경은 macOS 26.6.2(25G83), Xcode 26.6(17F113), Apple Silicon이다.

| 검증 항목 | 근거 | 결과 |
| --- | --- | --- |
| 전체 XCTest | `xcodebuild test` | 87개 통과, 실패 0개 |
| Thread Sanitizer XCTest | `xcodebuild test -enableThreadSanitizer YES` | 87개 통과, data race 보고 0개 |
| Release 빌드 | `xcodebuild build -configuration Release` | 성공, `apps/macos/build/Build/Products/Release/Kocro.app` 생성 |
| 100개 sample nearest-rank와 동시 수집 | `PostingLatencyRecorderTests` | 7개 통과, 첫 100개 제한·p50=50·p95=95·이전 결과 무효화 확인 |
| HID monitor 시작 실패 | `ShortcutCoordinatorTests.testHIDPermissionAndStartFailuresLeaveCarbonRegistered`의 `HIDSpy(starts: false)` | 통과, HID 실패 상태와 Carbon 등록 유지 확인 |
| 금지 API와 실행 범위 | 정적 검색 | 금지 항목 0개 |

## 실제 앱 검증

아래 항목은 서명된 앱과 TCC 권한, F21~F24를 전송할 수 있는 하드웨어가 필요한 검증이다. 현재 checkpoint에서는 수행하지 않았으며 결과를 pass 또는 fail로 판정하지 않았다.

| 대상·조건 | 실제 결과 | 판정 |
| --- | --- | --- |
| TextEdit, 한글 입력기 활성, 한글·영문·여러 줄·이모지·조합 문자 | 미실행 | 미판정 |
| Safari 또는 Chromium 입력 필드 | 미실행 | 미판정 |
| Terminal | 미실행 | 미판정 |
| VS Code | 미실행 | 미판정 |
| 여러 단축키를 빠르게 입력한 FIFO 순서 | 미실행 | 미판정 |
| Accessibility 권한 없음 | 미실행 | 미판정 |
| 실행 중 Accessibility 권한 철회 | 미실행 | 미판정 |
| F21~F24 활성화 전후의 Input Monitoring 요청 조건 | 미실행 | 미판정 |
| Input Monitoring 권한 없음과 실행 중 철회 | 미실행 | 미판정 |
| 포커스된 앱도 F21~F24를 처리하는 HID 비독점 동작 | 미실행 | 미판정 |
| 다른 앱과 Carbon 단축키 충돌 | 미실행 | 미판정 |
| 앱 종료 시 Carbon·HID 자원 해제 | 미실행 | 미판정 |
| 메뉴 바에서 로그인 시 실행 활성화 후 macOS 로그인 항목 표시 | 미실행 | 미판정 |
| 로그인 시 실행 비활성화 후 macOS 로그인 항목 제거 | 미실행 | 미판정 |

## Release 게시 지연 기준값

첫 버전은 환경별 기준값 수집 단계이므로 통과 임계값을 두지 않는다. 측정 범위는 단축키 callback이 받은 instant부터 마지막 `CGEvent.post` 반환까지다. 대상 앱의 화면 반영 시간은 포함하지 않는다.

| 항목 | 값 |
| --- | --- |
| 빌드 | Release, 실제 측정 미실행 |
| 입력 문자열 | ASCII `a` 100자, 실제 측정 미실행 |
| sample 수 | 0개 |
| 원시 ms | 실제 측정값 없음 |
| p50 | 실제 측정값 없음 |
| p95 | 실제 측정값 없음 |
| queue 대기 | 측정 시 `queue empty`를 확인하고 이전 게시 완료 뒤 다음 키 입력 필요 |
| 외부 process 시작 횟수 | 구현 정적 검색 0회, 실제 측정은 미판정 |

실제 측정은 `--measure-posting-latency` argument로 Release 앱을 한 번 시작한다. 측정 mode가 시작되면 이전 결과 파일을 제거하므로 새 결과가 생기기 전에는 해당 경로가 없어야 한다. 메뉴 바의 `측정 N/100`과 `queue empty`를 확인하면서 F13을 100회 입력한다. 결과 파일은 `~/Library/Application Support/com.caost.Kocro/posting-latency.json`이며 원시 100개 sample과 p50·p95가 있어야 한다.

앱을 시작하기 전에 아래 준비 명령을 같은 shell에서 실행한다. 기존 결과 파일을 제거하지 못하면 앱을 시작하지 않고, 실행별 marker를 남긴다.

```sh
kocro_report="$HOME/Library/Application Support/com.caost.Kocro/posting-latency.json"
kocro_marker="$(mktemp -t kocro-measurement)" &&
rm -f "$kocro_report" &&
test ! -e "$kocro_report" &&
open "$(pwd)/apps/macos/build/Build/Products/Release/Kocro.app" --args --measure-posting-latency
```

100회 입력이 끝나면 같은 shell에서 아래 명령을 실행한다. `-nt`는 결과 파일이 실행별 marker보다 엄격하게 새 파일인지 확인하므로, 같은 초에 생성된 이전 파일도 현재 결과로 통과하지 않는다.

```sh
test "$kocro_report" -nt "$kocro_marker" &&
test "$(jq '.samples | length' "$kocro_report")" -eq 100 &&
jq -e '.p50 | numbers' "$kocro_report" >/dev/null &&
jq -e '.p95 | numbers' "$kocro_report" >/dev/null &&
rm -f "$kocro_marker"
```
