import Foundation

enum TimeoutError: Error { case timeout }

/// Race an async operation against a timeout. Returns the operation result or throws TimeoutError.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            try Task.checkCancellation()
            throw TimeoutError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        return result
    }
}
