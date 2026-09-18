import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(HistoryStore.self) private var historyStore
    @State private var speechManager = SpeechManager()
    @State private var translationManager = TranslationManager()
    @State private var subtitleWindowController: SubtitleWindowController?
    @State private var isRecording = false
    @State private var currentEnglish = ""
    @State private var currentChinese = ""
    @State private var recentSegments: [(original: String, translated: String)] = []
    @State private var showHistory = false
    @State private var showSettings = false
    @AppStorage("recognitionLanguage") private var recognitionLanguage: String = "en-GB"
    private let maxRecentSegments = 20

    var body: some View {
        VStack(spacing: 0) { headerBar; Divider(); mainContent; Divider(); controlBar }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { setupSubtitleWindow() }
        .onChange(of: recognitionLanguage) { _, newLanguage in
            speechManager.switchLanguage(to: newLanguage)
        }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .modifier(TranslationSessionCompat(manager: translationManager))
    }
    
    private var headerBar: some View {
        HStack {
            Image(systemName: "text.book.closed").font(.title2).foregroundColor(.accentColor)
            Text("Classroom Translator").font(.headline)
            Text("(\(currentAccentName))").font(.caption).foregroundColor(.secondary)
            Spacer()
            Button(action: { showHistory = true }) { Label("History", systemImage: "clock") }.buttonStyle(.borderless)
            Button(action: { showSettings = true }) { Label("Settings", systemImage: "gear") }.buttonStyle(.borderless)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    
    private var mainContent: some View {
        VStack(spacing: 16) {
            if recentSegments.isEmpty && currentEnglish.isEmpty { emptyStateView }
            else { transcriptView }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.circle").font(.system(size: 60)).foregroundColor(.secondary)
            Text("Ready to Listen").font(.title2).foregroundColor(.secondary)
            Text("Click Start to begin recording").font(.subheadline).foregroundColor(.secondary)
        }
    }
    
    private var transcriptView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(recentSegments.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(segment.original).font(.system(size: 14, weight: .medium))
                        Text(segment.translated).font(.system(size: 13)).foregroundColor(.blue)
                    }.padding(8).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(6)
                }
                if !currentEnglish.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentEnglish).font(.system(size: 14, weight: .medium)).foregroundColor(.orange)
                        Text(currentChinese.isEmpty ? "Translating..." : currentChinese).font(.system(size: 13)).foregroundColor(.gray)
                    }.padding(8).background(Color(nsColor: .controlBackgroundColor).opacity(0.5)).cornerRadius(6)
                }
            }.padding()
        }
    }
    
    private var controlBar: some View {
        HStack(spacing: 20) {
            Button(action: toggleOverlay) {
                Label(subtitleWindowController?.window?.isVisible == true ? "Hide Overlay" : "Show Overlay",
                      systemImage: subtitleWindowController?.window?.isVisible == true ? "eye.slash" : "eye")
            }.buttonStyle(.bordered)
            Spacer()
            Button(action: toggleRecording) {
                HStack { Image(systemName: isRecording ? "stop.fill" : "mic.fill"); Text(isRecording ? "Stop" : "Start") }
                    .frame(width: 100)
            }.buttonStyle(.borderedProminent).tint(isRecording ? .red : .accentColor).controlSize(.large)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    
    private var currentAccentName: String {
        let accentMap: [String: String] = [
            "en-US": "American", "en-GB": "British", "en-AU": "Australian",
            "en-IN": "Indian", "en-IE": "Irish", "en-NZ": "New Zealand",
            "en-ZA": "South African", "zh-Hans": "Chinese",
            "ja-JP": "Japanese", "ko-KR": "Korean", "hi-IN": "Hindi"
        ]
        return accentMap[recognitionLanguage] ?? recognitionLanguage
    }
    
    private func setupSubtitleWindow() {
        let controller = SubtitleWindowController()
        subtitleWindowController = controller
        speechManager.onSegmentRecognized = { text, isFinal in
            Task { @MainActor in
                if isFinal {
                    recentSegments.append((original: text, translated: ""))
                    if recentSegments.count > maxRecentSegments { recentSegments.removeFirst() }
                    let translated = await translationManager.translate(text)
                    if let lastIndex = recentSegments.indices.last {
                        recentSegments[lastIndex] = (original: text, translated: translated)
                    }
                    controller.updateSegments(recentSegments)
                    historyStore.addSegment(TranscriptSegment(original: text, translated: translated))
                    currentEnglish = ""; currentChinese = ""
                } else {
                    currentEnglish = text
                    controller.updateSegments(recentSegments, currentText: text)
                }
            }
        }
    }
    
    private func toggleRecording() {
        if isRecording {
            speechManager.stopRecording(); historyStore.stopCurrentRecord(); isRecording = false
        } else {
            Task {
                let granted = await speechManager.requestPermissions()
                guard granted else { return }
                historyStore.startNewRecord(); try? speechManager.startRecording(); isRecording = true
            }
        }
    }
    
    private func toggleOverlay() {
        if subtitleWindowController?.window?.isVisible == true { subtitleWindowController?.hideWindow() }
        else { subtitleWindowController?.showWindow() }
    }
}
