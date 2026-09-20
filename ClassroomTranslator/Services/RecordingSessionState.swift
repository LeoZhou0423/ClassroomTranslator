import Foundation

struct RecordingSessionState: Equatable {
    enum Phase: Equatable { case idle, starting, recording, paused, interrupted, ended }

    private(set) var phase: Phase = .idle
    private(set) var accumulated: TimeInterval = 0
    private var startedAt: Date?

    mutating func beginStarting() { phase = .starting }

    mutating func failStart(resumable: Bool) {
        startedAt = nil
        phase = resumable ? .paused : .idle
    }

    mutating func start(at date: Date = Date()) {
        guard phase != .ended else { return }
        phase = .recording
        startedAt = date
    }

    mutating func pause(at date: Date = Date()) {
        accumulate(until: date)
        phase = .paused
    }

    mutating func interrupt(at date: Date = Date()) {
        accumulate(until: date)
        phase = .interrupted
    }

    mutating func end(at date: Date = Date()) {
        accumulate(until: date)
        phase = .ended
    }

    mutating func reset() {
        phase = .idle
        accumulated = 0
        startedAt = nil
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulated + (startedAt.map { date.timeIntervalSince($0) } ?? 0)
    }

    private mutating func accumulate(until date: Date) {
        if let startedAt { accumulated += max(0, date.timeIntervalSince(startedAt)) }
        startedAt = nil
    }
}
