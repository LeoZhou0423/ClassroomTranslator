import Foundation

/// Resolves independently of a system operation that ignores task cancellation.
/// A task group cannot provide this guarantee: it waits for all children on exit.
@MainActor
final class RecordingStartupStep {
    private var continuation: CheckedContinuation<Error?, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    static func run(
        timeoutNanoseconds: UInt64,
        onTimeout: @escaping @MainActor () -> Void,
        operation: @escaping @MainActor () async throws -> Void
    ) async -> Error? {
        let step = RecordingStartupStep()
        return await withCheckedContinuation { continuation in
            step.continuation = continuation
            step.operationTask = Task { @MainActor in
                do {
                    try await operation()
                    step.finish(nil)
                } catch {
                    step.finish(error)
                }
            }
            step.timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                guard step.continuation != nil else { return }
                onTimeout()
                step.finish(StartupError.timedOut)
            }
        }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        operationTask?.cancel()
        timeoutTask = nil
        operationTask = nil
        continuation.resume(returning: error)
    }

    enum StartupError: Error {
        case timedOut
    }
}
