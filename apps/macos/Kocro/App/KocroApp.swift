import SwiftUI

@main
struct KocroApp: App {
    var body: some Scene {
        MenuBarExtra("Kocro", systemImage: "keyboard") {
            Text("준비 중")

            Button("설정…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            Divider()

            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
        }

        Settings {
            Text("Kocro 설정")
        }
    }
}
