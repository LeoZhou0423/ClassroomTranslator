import Foundation

/// Resolves independently of a system operation that ignores task cancellation.
/// A task group cannot provide this guarantee: it waits for all children on exit.
@MainActor
final class RecordingStartupStep {
    private var continuation: CheckedContinuation<Error?, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var onTimeout: (@MainActor () -> Void)?
    private let timeoutNanoseconds: UInt64

    init(timeoutNanoseconds: UInt64) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    static func run(
        timeoutNanoseconds: UInt64,
        onTimeout: @escaping @MainActor () -> Void,
        operation: @escaping @MainActor () async throws -> Void
    ) async -> Error? {
        await RecordingStartupStep(timeoutNanoseconds: timeoutNanoseconds)
            .run(onTimeout: onTimeout, operation: operation)
    }

    func run(
        onTimeout: @escaping @MainActor () -> Void,
        operation: @escaping @MainActor () async throws -> Void
    ) async -> Error? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.onTimeout = onTimeout
            self.operationTask = Task { @MainActor in
                do {
                    try await operation()
                    self.finish(nil)
                } catch {
                    self.finish(error)
                }
            }
            self.scheduleTimeout()
        }
    }

    func kick() {
        guard continuation != nil else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        scheduleTimeout()
    }

    private func scheduleTimeout() {
        guard continuation != nil, let onTimeout else { return }
        let nanoseconds = timeoutNanoseconds
        timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard self.continuation != nil else { return }
            onTimeout()
            self.finish(StartupError.timedOut)
        }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        self.onTimeout = nil
        timeoutTask?.cancel()
        operationTask?.cancel()
        timeoutTask = nil
        operationTask = nil
        continuation.resume(returning: error)
    }

    enum StartupError: LocalizedError {
        case timedOut

        var errorDescription: String? {
            String(localized: "Recording took too long to start.")
        }
    }
}
