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
        .defaultSize(width: 1000, height: 650)

        Settings {
            AppSettingsHost()
        }
    }
}

@MainActor
private struct AppSettingsHost: View {
    @State private var translationManager = TranslationManager()

    var body: some View {
        SettingsView(translationManager: translationManager)
            .modifier(TranslationSessionCompat(manager: translationManager))
    }
}
