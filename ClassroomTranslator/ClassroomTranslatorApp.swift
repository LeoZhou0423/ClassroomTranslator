import SwiftUI

@main
@MainActor
struct ClassroomTranslatorApp: App {
    @State private var historyStore = HistoryStore()

    init() {
        Self.applyAppLanguage()
    }

    static func applyAppLanguage() {
        let pref = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hans"
        if pref == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([pref], forKey: "AppleLanguages")
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(historyStore)
        }
        .defaultSize(width: 700, height: 500)

        Settings {
            SettingsView()
        }
    }
}
