import XCTest
@testable import RemarcFeature

final class ProcessRunnerTests: XCTestCase {
    func testRunProcessReturnsTrueOnZeroExit() async throws {
        let success = await ProcessRunner.run("/usr/bin/true", arguments: [])
        XCTAssertTrue(success)
    }

    func testRunProcessReturnsFalseOnNonzeroExit() async throws {
        let success = await ProcessRunner.run("/usr/bin/false", arguments: [])
        XCTAssertFalse(success)
    }

    func testRunCaptureReturnsStdout() async throws {
        let output = await ProcessRunner.runCapture("/bin/echo", arguments: ["hello world"], timeoutSeconds: 2)
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testRunCaptureTimesOutGracefully() async throws {
        let start = Date()
        let output = await ProcessRunner.runCapture("/bin/sleep", arguments: ["10"], timeoutSeconds: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3.0)  // killed near the timeout
        XCTAssertNil(output)              // nil on timeout, NOT empty string
    }

    func testRunCaptureReturnsEmptyStringOnSuccessfulEmptyOutput() async throws {
        // /usr/bin/true exits 0 with no stdout — that's an empty string, not nil.
        // This distinction matters for callers that gate behavior on the result.
        let output = await ProcessRunner.runCapture("/usr/bin/true", arguments: [], timeoutSeconds: 2)
        XCTAssertEqual(output, "")
    }

    func testRunCaptureReturnsNilOnNonzeroExit() async throws {
        let output = await ProcessRunner.runCapture("/usr/bin/false", arguments: [], timeoutSeconds: 2)
        XCTAssertNil(output)
    }

    func testRunCaptureReturnsNilOnLaunchFailure() async throws {
        let output = await ProcessRunner.runCapture("/nonexistent-binary-xyz-12345", arguments: [], timeoutSeconds: 2)
        XCTAssertNil(output)
    }
}
