import Foundation

enum TranslationBackendChoice: String, CaseIterable {
    case apple, translateGemma
    static let defaultsKey = "translationBackend"
    init(defaults: UserDefaults = .standard) {
        self = Self(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .apple
    }
}

/// Fixed loopback endpoint: classroom text is sent only to the user's local
/// Ollama instance, never to a cloud service by this client.
struct LocalTranslationClient {
    static let model = "translategemma:4b"
    static let baseURL = URL(string: "http://127.0.0.1:11434")!
    var session: URLSession = .shared

    enum Failure: LocalizedError {
        case unavailable, response(Int), empty, incomplete
        var errorDescription: String? {
            switch self {
            case .unavailable: return "无法连接本机 Ollama。请先启动 Ollama，并在设置中下载 TranslateGemma 4B。"
            case .response(let code): return "本地翻译服务返回错误（\(code)）。请检查模型是否下载完成。"
            case .empty: return "本地翻译模型返回空内容，英文转写已保留。"
            case .incomplete: return "本地翻译达到输出长度限制，未将截断结果作为完整译文保存。"
            }
        }
    }

    static func prompt(text: String, source: String, target: String, context: String) -> String {
        let english = Locale(identifier: "en")
        let sourceCode = source.split(separator: "-").first.map(String.init) ?? source
        let targetCode = target.hasPrefix("zh") ? target : (target.split(separator: "-").first.map(String.init) ?? target)
        let sourceName = english.localizedString(forLanguageCode: sourceCode) ?? sourceCode
        let targetName = target == "zh-Hans" ? "Simplified Chinese" : (english.localizedString(forLanguageCode: targetCode) ?? targetCode)
        let reference = context.isEmpty ? "" : "\nReference context (do not translate or add it to the output): \(context)\nPreserve names and numbers. Use context to disambiguate meaning; do not invent missing source words."
        return "You are a professional \(sourceName) (\(sourceCode)) to \(targetName) (\(targetCode)) translator. Your goal is to accurately convey the meaning and nuances of the original \(sourceName) text while adhering to \(targetName) grammar, vocabulary, and cultural sensitivities." + reference + "\nProduce only the \(targetName) translation, without any additional explanations or commentary. Please translate the following \(sourceName) text into \(targetName):\n\n\n" + text
    }

    func translate(_ text: String, source: String, target: String, context: String) async throws -> String {
        let payload: [String: Any] = [
            "model": Self.model,
            "messages": [["role": "user", "content": Self.prompt(text: text, source: source, target: target, context: context)]],
            "stream": false, "keep_alive": "10m",
            "options": ["temperature": 0, "num_ctx": 2048, "num_predict": 512]
        ]
        let data = try await request(path: "api/chat", payload: payload, timeout: 60)
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard response.done == true else { throw Failure.incomplete }
        guard response.done_reason != "length" else { throw Failure.incomplete }
        let output = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw Failure.empty }
        return output
    }

    func modelInstalled() async throws -> Bool {
        let data = try await request(path: "api/tags", payload: nil, timeout: 5)
        return try JSONDecoder().decode(ModelList.self, from: data).models.contains { $0.name == Self.model }
    }

    func downloadModel() async throws {
        _ = try await request(path: "api/pull", payload: ["model": Self.model, "stream": false], timeout: 3600)
        guard try await modelInstalled() else { throw Failure.unavailable }
    }

    private func request(path: String, payload: [String: Any]?, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        if let payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw Failure.unavailable }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.response((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
        let done: Bool?
        let done_reason: String?
    }
    private struct ModelList: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }
}
