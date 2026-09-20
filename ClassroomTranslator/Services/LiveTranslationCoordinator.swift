import Foundation

@MainActor
final class LiveTranslationCoordinator {
    enum Kind: Equatable { case partial, final }

    struct Request {
        let kind: Kind
        let text: String
        let cue: String
        let revision: Int
        let generation: Int
        let segmentID: UUID?
        let completion: @MainActor (Response) -> Void

        init(
            kind: Kind,
            text: String,
            cue: String,
            revision: Int,
            generation: Int,
            segmentID: UUID? = nil,
            completion: @escaping @MainActor (Response) -> Void
        ) {
            self.kind = kind
            self.text = text
            self.cue = cue
            self.revision = revision
            self.generation = generation
            self.segmentID = segmentID
            self.completion = completion
        }
    }

    struct Response {
        let request: Request
        let translatedText: String
        var succeeded: Bool { !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    typealias Translator = @MainActor (String) async -> String

    private let translator: Translator
    private let partialInterval: Duration
    private var pendingFinals: [Request] = []
    private var pendingPartial: Request?
    private var worker: Task<Void, Never>?
    private var lastPartialStartedAt: ContinuousClock.Instant?
    private var activeGeneration = 0
    private let clock = ContinuousClock()

    init(partialInterval: Duration = .milliseconds(700), translator: @escaping Translator) {
        self.partialInterval = partialInterval
        self.translator = translator
    }

    func submit(_ request: Request) {
        guard request.generation >= activeGeneration else { return }
        switch request.kind {
        case .final: pendingFinals.append(request)
        case .partial: pendingPartial = request
        }
        startWorkerIfNeeded()
    }

    func cancelPartials() {
        pendingPartial = nil
    }

    func cancelAll() {
        pendingPartial = nil
        pendingFinals.removeAll()
        worker?.cancel()
        worker = nil
    }

    func activateGeneration(_ generation: Int) {
        activeGeneration = generation
        pendingFinals.removeAll { $0.generation < generation }
        if let pendingPartial, pendingPartial.generation < generation {
            self.pendingPartial = nil
        }
    }

    func waitUntilIdle() async {
        await worker?.value
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let request = self.takeNextRequest() {
                if request.kind == .partial, let last = self.lastPartialStartedAt {
                    let earliest = last.advanced(by: self.partialInterval)
                    if earliest > self.clock.now {
                        try? await self.clock.sleep(until: earliest)
                    }
                    guard !Task.isCancelled else { break }
                }
                if request.kind == .partial { self.lastPartialStartedAt = self.clock.now }
                let translated = await self.translator(request.text)
                guard !Task.isCancelled else { break }
                guard request.generation >= self.activeGeneration else { continue }
                request.completion(Response(request: request, translatedText: translated))
            }
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
}
