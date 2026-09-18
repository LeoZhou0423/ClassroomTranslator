import Foundation
import Translation

@MainActor
@Observable
final class TranslationManager {
    var translatedText = ""
    var isTranslating = false
    
    func translate(_ text: String) async -> String {
        guard !text.isEmpty else { return "" }
        
        isTranslating = true
        defer { isTranslating = false }
        
        let source = Locale.Language(languageCode: .english)
        let target = Locale.Language(languageCode: .chinese)
        
        return await withCheckedContinuation { continuation in
            let session = LanguageSession(source: source, target: target)
            
            let request = LanguageSession.Request(sourceText: text)
            session.insert(request)
            
            Task {
                for await response in session.responses {
                    if let translated = response.targetText {
                        continuation.resume(returning: translated)
                        return
                    }
                }
                continuation.resume(returning: text)
            }
        }
    }
    
    func translateBatch(_ texts: [String]) async -> [String] {
        var results: [String] = []
        for text in texts {
            let translated = await translate(text)
            results.append(translated)
        }
        return results
    }
}
