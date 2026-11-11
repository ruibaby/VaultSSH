import XCTest
@testable import VaultSSH

@MainActor
final class AgentControllerTests: XCTestCase {
    func testApprovalGraceChangedWhileStoppedIsRetainedForNextStart() {
        let agent = AgentController(loadHistory: false)
        agent.setApprovalGrace(seconds: 1800)
        agent.setApprovalGrace(seconds: 3600)
        XCTAssertEqual(agent.desiredGraceSeconds, 3600)
        XCTAssertEqual(agent.approvalWindowCommand().graceSeconds, 3600)
    }

    func testApprovalWindowAckOnlyChecksLatestRequest() {
        var state = ApprovalWindowState()
        state.setDesired(300)
        state.recordSent()
        state.setDesired(1800)
        state.recordSent()

        XCTAssertFalse(state.acknowledge(300))
        XCTAssertEqual(state.awaitingAcks, 1)
        XCTAssertFalse(state.acknowledge(1800))
        XCTAssertEqual(state.awaitingAcks, 0)
    }

    func testApprovalWindowAckFlagsRejectedLatestWindow() {
        var state = ApprovalWindowState()
        state.setDesired(1800)
        state.recordSent()
        XCTAssertTrue(state.acknowledge(300))
    }

    func testApprovalWindowAckIsDecoded() throws {
        let data = Data(#"{"type":"approvalWindow","graceSeconds":1800}"#.utf8)
        let event = try JSONDecoder().decode(ControlEvent.self, from: data)
        XCTAssertEqual(event.type, "approvalWindow")
        XCTAssertEqual(event.graceSeconds, 1800)
    }
}
