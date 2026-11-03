import XCTest
@testable import VaultSSH

final class BitwardenCLITests: XCTestCase {
    func testCancellationStopsCLIProcess() async {
        let cancellation = CLIProcessCancellation()
        let task = Task.detached {
            try BitwardenCLI(path: "/bin/sleep").run(["10"], cancellation: cancellation)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        cancellation.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled command succeeded")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCredentialPipeHandlesAnEarlyExit() async {
        let completed = expectation(description: "early exit closes credential input")
        Task.detached {
            _ = try? BitwardenCLI(path: "/usr/bin/true").run([], timeout: 2, input: Data(repeating: 120, count: 65536))
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 4)
    }

    func testLargeStderrDoesNotBlockStdout() throws {
        let output = try BitwardenCLI(path: "/usr/bin/python3").run(
            ["-c", "import sys; sys.stderr.write('x' * 200000); print('ok')"], timeout: 5)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }
}
