import SwiftUI

@main
@MainActor
struct ClassroomTranslatorApp: App {
    @State private var historyStore = HistoryStore()

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
