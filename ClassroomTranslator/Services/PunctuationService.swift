import Foundation

/// Punctuation restoration client — calls local Python rpunct server
/// POST http://127.0.0.1:18976/punct  { "text": "..." }
/// Falls back to raw text if server is unreachable.
enum PunctuationService {
    private static let url = URL(string: "http://127.0.0.1:18976/punct")!

    /// Restore punctuation in text. Always returns (falls back to input on any failure).
    static func punctuate(_ text: String) async -> String {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return text }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        request.httpBody = try? JSONEncoder().encode(["text": text])

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let punctuated = json["text"] as? String,
                  !punctuated.isEmpty else {
                return text
            }
            return punctuated
        } catch {
            return text
        }
    }
}
