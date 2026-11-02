import XCTest
@testable import VaultSSH

final class ControlStreamTests: XCTestCase {
    func testSmallMessagesArriveBeforePipeCloses() async throws {
        let pipe = Pipe()
        let received = expectation(description: "incremental message")
        let reader = Task.detached {
            try await ControlStream.read(from: pipe.fileHandleForReading) { message in
                if message.type == "revoked" { received.fulfill() }
            }
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("{\"type\":\"revoked\"}\n".utf8))
        await fulfillment(of: [received], timeout: 1)
        try pipe.fileHandleForWriting.close()
        try await reader.value
        try pipe.fileHandleForReading.close()
    }
}
