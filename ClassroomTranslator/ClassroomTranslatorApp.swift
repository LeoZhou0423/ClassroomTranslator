import SwiftUI

@main
struct ClassroomTranslatorApp: App {
    @State private var historyStore = HistoryStore()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(historyStore)
        }
        .defaultSize(width: 600, height: 500)
        
        Settings {
            SettingsView()
        }
    }
}
