import Foundation

@MainActor
final class LiveTranslationCoordinator {
    enum Kind: Equatable { case partial, final }

    struct Request {
        let kind: Kind
        let text: String
        let cue: String
        let context: String
        let revision: Int
        let generation: Int
        let segmentID: UUID?
        /// Full recognizer snapshot that produced a partial sentence unit.
        /// Final requests leave this nil.
        let sourceSnapshot: String?
        let completion: @MainActor (Response) -> Void

        init(
            kind: Kind,
            text: String,
            cue: String,
            revision: Int,
            generation: Int,
            segmentID: UUID? = nil,
            sourceSnapshot: String? = nil,
            context: String = "",
            completion: @escaping @MainActor (Response) -> Void
        ) {
            self.kind = kind
            self.text = text
            self.cue = cue
            self.context = context
            self.revision = revision
            self.generation = generation
            self.segmentID = segmentID
            self.sourceSnapshot = sourceSnapshot
            self.completion = completion
        }
    }

    struct Response {
        let request: Request
        let translatedText: String
        var isComplete = true
        var succeeded: Bool { !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    typealias Translator = @MainActor (String) async -> String

    private let translator: @MainActor (String, String, @escaping @MainActor (String) -> Void) async -> String
    private let partialInterval: Duration
    private var pendingFinals: [Request] = []
    private var pendingPartial: Request?
    private var worker: Task<Void, Never>?
    private var lastPartialStartedAt: ContinuousClock.Instant?
    private var activeGeneration = 0
    /// worker 任务的身份令牌：cancelAll() 会把 worker 置空，旧任务收尾时
    /// 不能把新任务的引用也清掉，否则 waitUntilIdle() 会提前返回（译文没落库）
    /// 并且可能同时跑两个 worker。
    private var workerToken = 0
    private var inFlightByWorker: [Int: Request] = [:]
    /// Successful translations are immutable for this view's fixed language
    /// pair. Repeated recognizer snapshots and final promotion therefore reuse
    /// the first result instead of invoking Apple's model again.
    private var translationCache: [String: String] = [:]
    private let clock = ContinuousClock()
    private var latestSegmentRequests: [UUID: (generation: Int, revision: Int, text: String)] = [:]

    init(partialInterval: Duration = .milliseconds(700), translator: @escaping Translator) {
        self.partialInterval = partialInterval
        self.translator = { text, _, _ in await translator(text) }
    }

    init(partialInterval: Duration = .milliseconds(700), contextualTranslator: @escaping @MainActor (String, String) async -> String) {
        self.partialInterval = partialInterval
        self.translator = { text, context, _ in await contextualTranslator(text, context) }
    }

    init(partialInterval: Duration = .milliseconds(700), streamingTranslator: @escaping @MainActor (String, String, @escaping @MainActor (String) -> Void) async -> String) {
        self.partialInterval = partialInterval
        self.translator = streamingTranslator
    }

    func submit(_ request: Request) {
        guard request.generation >= activeGeneration else { return }
        switch request.kind {
        case .final:
            if let id = request.segmentID {
                pendingFinals.removeAll { $0.segmentID == id && $0.generation == request.generation }
                latestSegmentRequests[id] = (request.generation, request.revision, request.text)
            }
            pendingFinals.append(request)
        case .partial: pendingPartial = request
        }
        startWorkerIfNeeded()
    }

    func invalidateSegments(_ ids: Set<UUID>) {
        pendingFinals.removeAll { $0.segmentID.map(ids.contains) ?? false }
        for id in ids { latestSegmentRequests[id] = (.max, .max, "") }
    }

    func cancelPartials() {
        pendingPartial = nil
    }

    func cancelAll() {
        pendingPartial = nil
        pendingFinals.removeAll()
        latestSegmentRequests.removeAll()
        workerToken += 1
        worker?.cancel()
        worker = nil
        inFlightByWorker.removeAll()
    }

    func activateGeneration(_ generation: Int) {
        activeGeneration = generation
        pendingFinals.removeAll { $0.generation < generation }
        if let pendingPartial, pendingPartial.generation < generation {
            self.pendingPartial = nil
        }
    }

    func waitUntilIdle() async {
        // A cancelled worker may overlap briefly with its successor. Re-read
        // the current task after every await so finishing cannot outrun it.
        while let current = worker {
            await current.value
        }
    }

    /// UX-04：收尾阶段给状态行用的"还剩几段"。
    var pendingCount: Int {
        pendingFinals.count + (pendingPartial == nil ? 0 : 1) + inFlightByWorker.count
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        workerToken += 1
        let token = workerToken
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let request = self.takeNextRequest() {
                self.inFlightByWorker[token] = request
                defer { self.inFlightByWorker[token] = nil }
                if request.kind == .partial, let last = self.lastPartialStartedAt {
                    let earliest = last.advanced(by: self.partialInterval)
                    if earliest > self.clock.now {
                        try? await self.clock.sleep(until: earliest)
                    }
                    guard !Task.isCancelled else { break }
                }
                if request.kind == .partial { self.lastPartialStartedAt = self.clock.now }
                let cacheKey = self.normalizedCacheKey(request.text) + "\u{001F}" + request.context
                var translated = self.translationCache[cacheKey] ?? ""
                if translated.isEmpty {
                    translated = await self.translator(request.text, request.context, { [weak self] draft in
                        guard let self, !Task.isCancelled, self.workerToken == token,
                              request.generation >= self.activeGeneration else { return }
                        if let id = request.segmentID, let latest = self.latestSegmentRequests[id],
                           latest.generation != request.generation || latest.revision != request.revision || latest.text != request.text { return }
                        request.completion(Response(request: request, translatedText: draft, isComplete: false))
                    })
                    if !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.translationCache[cacheKey] = translated
                    }
                }
                // TranslationSession can transiently invalidate itself and the
                // manager deliberately prepares it again on the next request.
                // A final has no later update to repair it, so retry it once.
                if request.kind == .final,
                   translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !Task.isCancelled {
                    try? await self.clock.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { break }
                    translated = await self.translator(request.text, request.context, { [weak self] draft in
                        guard let self, !Task.isCancelled, self.workerToken == token,
                              request.generation >= self.activeGeneration else { return }
                        if let id = request.segmentID, let latest = self.latestSegmentRequests[id],
                           latest.generation != request.generation || latest.revision != request.revision || latest.text != request.text { return }
                        request.completion(Response(request: request, translatedText: draft, isComplete: false))
                    })
                    if !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.translationCache[cacheKey] = translated
                    }
                }
                guard !Task.isCancelled else { break }
                guard request.generation >= self.activeGeneration else { continue }
                if let id = request.segmentID, let latest = self.latestSegmentRequests[id],
                   latest.generation != request.generation || latest.revision != request.revision || latest.text != request.text { continue }
                request.completion(Response(request: request, translatedText: translated))
            }
            // 只有自己仍然是"当前那个 worker"时才收尾，避免清掉后继者的引用。
            guard self.workerToken == token else { return }
            self.worker = nil
            if !self.pendingFinals.isEmpty || self.pendingPartial != nil {
                self.startWorkerIfNeeded()
            }
        }
    }

    private func takeNextRequest() -> Request? {
        if !pendingFinals.isEmpty { return pendingFinals.removeFirst() }
        defer { pendingPartial = nil }
        return pendingPartial
    }

    private func normalizedCacheKey(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
