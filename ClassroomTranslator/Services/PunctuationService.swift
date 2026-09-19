import Foundation

/// Punctuation restoration client — calls local Python rpunct server
/// POST http://127.0.0.1:18976/punct  { "text": "..." }
/// Falls back to raw text if server is unreachable.
enum PunctuationService {
    private static let url = URL(string: "http://127.0.0.1:18976/punct")!
    private static var task: URLSessionDataTask?

    /// Restore punctuation in text. Non-blocking, returns via callback.
    static func punctuate(_ text: String, completion: @escaping (String) -> Void) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            completion(text)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        request.httpBody = try? JSONEncoder().encode(["text": text])

        task?.cancel()
        task = URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let punctuated = json["text"] as? String else {
                completion(text)
                return
            }
            completion(punctuated)
        }
        task?.resume()
    }

    /// Synchronous punctuate (for testing)
    static func punctuateSync(_ text: String) -> String {
        let group = DispatchGroup()
        var result = text
        group.enter()
        punctuate(text) { result = $0; group.leave() }
        _ = group.wait(timeout: .now() + 3)
        return result
    }
}
