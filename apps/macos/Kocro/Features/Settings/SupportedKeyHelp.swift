import AppKit
import SwiftUI

struct SupportedKeyHelp {
    struct Section: Identifiable, Equatable {
        let title: String
        let body: String
        var id: String { title }
    }

    private static let supportedFunctionRange = functionRange(MacKeyCodePolicy.supportedFunctionNumbers)
    private static let standaloneFunctionRange = functionRange(MacKeyCodePolicy.standaloneFunctionNumbers)
    private static let modifiedFunctionRange = functionRange(
        MacKeyCodePolicy.supportedFunctionNumbers.lowerBound...(MacKeyCodePolicy.standaloneFunctionNumbers.lowerBound - 1)
    )
    private static let unsupportedFunctionRange = functionRange(
        (MacKeyCodePolicy.supportedFunctionNumbers.upperBound + 1)...35
    )

    private static func functionRange(_ range: ClosedRange<Int>) -> String {
        "F\(range.lowerBound)~F\(range.upperBound)"
    }

    static let sections = [
        Section(
            title: "실행 단축키",
            body: "실행 단축키는 modifier와 문자·숫자·기호, navigation·whitespace 키를 조합해 입력합니다. Escape, Backspace와 Delete는 실행 단축키로 사용할 수 없습니다. 일반 키와 \(modifiedFunctionRange)에는 보조 키가 필요합니다. Command만 사용하는 표준 단축키는 사용할 수 없습니다. \(standaloneFunctionRange)은 단독 또는 보조 키 조합을 지원합니다. \(unsupportedFunctionRange), Fn, Caps Lock, 미디어 키는 지원하지 않습니다."
        ),
        Section(
            title: "후속 키",
            body: "후속 키는 문자·숫자·기호, navigation·editing·whitespace와 \(supportedFunctionRange)을 지원합니다. \(unsupportedFunctionRange), Fn, Caps Lock, 미디어 키는 지원하지 않습니다."
        ),
        Section(
            title: "토큰과 별칭",
            body: "보조 키 토큰은 {KC_CTRL}, {KC_OPT}, {KC_SHIFT}, {KC_CMD}입니다. 좌우 modifier 별칭 {KC_LCTL}/{KC_RCTL}, {KC_LALT}/{KC_RALT}, {KC_LSFT}/{KC_RSFT}, {KC_LCMD}/{KC_RCMD}도 입력할 수 있습니다."
        ),
    ]
}

struct SupportedKeyHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("지원 키 코드").font(.title2)
            ForEach(SupportedKeyHelp.sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(.headline)
                    Text(section.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}
