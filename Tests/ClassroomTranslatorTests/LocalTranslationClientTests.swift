import XCTest
@testable import ClassroomTranslator

final class LocalTranslationClientTests: XCTestCase {
    @MainActor
    func testRequestUsesLocalModelAndRejectsEmptyOrTruncatedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LocalTranslationClient(session: session)
        var drafts: [String] = []
        let translated = try await client.translate("During office hours.", source: "en-US", target: "zh-Hans", context: "Course", onProgress: { drafts.append($0) })
        XCTAssertEqual(translated, "在答疑时间。")
        XCTAssertEqual(drafts.first, "在答")
        XCTAssertEqual(drafts.last, translated)
        do {
            _ = try await client.translate("EMPTY", source: "en", target: "zh-Hans", context: "")
            XCTFail("Empty output must not be reported as successful translation")
        } catch { XCTAssertTrue(error is LocalTranslationClient.Failure) }
        do {
            _ = try await client.translate("TRUNCATED", source: "en", target: "zh-Hans", context: "")
            XCTFail("A length-limited result must not be stored as a complete translation")
        } catch { XCTAssertTrue(error is LocalTranslationClient.Failure) }
    }

    func testStreamingDeltasFormOneCompleteSentence() throws {
        var stream = LocalTranslationStream()
        try stream.append(#"{"message":{"content":"在答"},"done":false}"#)
        XCTAssertEqual(stream.text, "在答")
        XCTAssertFalse(stream.done)
        try stream.append(#"{"message":{"content":"疑时间。"},"done":false}"#)
        try stream.append(#"{"message":{"content":""},"done":true,"done_reason":"stop"}"#)
        XCTAssertEqual(stream.text, "在答疑时间。")
        XCTAssertTrue(stream.done)
        XCTAssertFalse(stream.truncated)
    }

    func testStreamingErrorsAndTruncationCannotLookComplete() throws {
        var stream = LocalTranslationStream()
        XCTAssertThrowsError(try stream.append(#"{"error":"model not found"}"#))
        XCTAssertThrowsError(try stream.append("invalid json"))
        try stream.append(#"{"message":{"content":"截断"},"done":true,"done_reason":"length"}"#)
        XCTAssertTrue(stream.truncated)
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
        XCTAssertEqual(payload?["stream"] as? Bool, true)
        let messages = payload?["messages"] as? [[String: String]]
        let prompt = messages?.first?["content"] ?? ""
        let empty = prompt.hasSuffix("EMPTY")
        let truncated = prompt.hasSuffix("TRUNCATED")
        let chunks: [[String: Any]] = [
            ["message": ["content": empty ? "" : "在答"], "done": false],
            ["message": ["content": empty ? "" : "疑时间。"], "done": false],
            ["message": ["content": ""], "done": true, "done_reason": truncated ? "length" : "stop"]
        ]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/x-ndjson"])!, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            var data = try! JSONSerialization.data(withJSONObject: chunk)
            data.append(0x0A)
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
