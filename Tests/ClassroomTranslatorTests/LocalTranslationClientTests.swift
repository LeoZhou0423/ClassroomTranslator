import XCTest
@testable import ClassroomTranslator

final class LocalTranslationClientTests: XCTestCase {
    func testRequestUsesLocalModelAndRejectsEmptyOrTruncatedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LocalTranslationClient(session: session)
        let translated = try await client.translate("During office hours.", source: "en-US", target: "zh-Hans", context: "Course")
        XCTAssertEqual(translated, "在答疑时间。")
        do {
            _ = try await client.translate("EMPTY", source: "en", target: "zh-Hans", context: "")
            XCTFail("Empty output must not be reported as successful translation")
        } catch { XCTAssertTrue(error is LocalTranslationClient.Failure) }
        do {
            _ = try await client.translate("TRUNCATED", source: "en", target: "zh-Hans", context: "")
            XCTFail("A length-limited result must not be stored as a complete translation")
        } catch { XCTAssertTrue(error is LocalTranslationClient.Failure) }
    }

    func testTranslateGemmaPromptKeepsReferenceOutsideSourceAndNamesLanguage() {
        let text = "My name is Shelly Kagan."
        let prompt = LocalTranslationClient.prompt(text: text, source: "en-US", target: "zh-Hans", context: "Course: Philosophy 176")
        XCTAssertTrue(prompt.contains("English (en) to Simplified Chinese (zh-Hans)"))
        XCTAssertTrue(prompt.contains("Reference context (do not translate or add it to the output): Course: Philosophy 176"))
        XCTAssertTrue(prompt.hasSuffix("\n\n\n" + text))
        XCTAssertEqual(LocalTranslationClient.baseURL.host, "127.0.0.1")
    }

    func testBackendDefaultsRemainAppleUntilLocalModelIsConfigured() {
        let suite = "TranslationTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TranslationBackendChoice(defaults: defaults), .apple)
        defaults.set("translateGemma", forKey: TranslationBackendChoice.defaultsKey)
        XCTAssertEqual(TranslationBackendChoice(defaults: defaults), .translateGemma)
    }
}

private final class TranslationMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        XCTAssertEqual(payload?["model"] as? String, "translategemma:4b")
        XCTAssertEqual(payload?["stream"] as? Bool, false)
        let messages = payload?["messages"] as? [[String: String]]
        let prompt = messages?.first?["content"] ?? ""
        let empty = prompt.hasSuffix("EMPTY")
        let truncated = prompt.hasSuffix("TRUNCATED")
        let result: [String: Any] = ["message": ["content": empty ? "" : "在答疑时间。"], "done": true, "done_reason": truncated ? "length" : "stop"]
        let data = try! JSONSerialization.data(withJSONObject: result)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
