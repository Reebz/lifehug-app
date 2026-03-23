import Testing
import Foundation
@testable import Lifehug

@Suite("TaskTimeout")
struct TaskTimeoutTests {

    @Test("Operation completes before timeout returns result")
    func completesBeforeTimeout() async throws {
        let result = try await withTimeout(seconds: 5.0) {
            return 42
        }
        #expect(result == 42)
    }

    @Test("Operation exceeds timeout throws TimeoutError")
    func exceedsTimeout() async {
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(seconds: 0.05) {
                try await Task.sleep(for: .seconds(10))
                return "should not reach"
            }
        }
    }

    @Test("Operation that throws propagates the error")
    func errorPropagates() async {
        struct TestError: Error {}

        await #expect(throws: TestError.self) {
            try await withTimeout(seconds: 5.0) {
                throw TestError()
            }
        }
    }
}
