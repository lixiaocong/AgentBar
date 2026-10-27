import XCTest
import ServiceManagement
@testable import AgentBar

final class LaunchAtLoginTests: XCTestCase {
    @MainActor
    func testRegistrationApprovalAndRemoval() async {
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        var removals = 0
        let model = LaunchAtLoginModel(
            readStatus: { status },
            register: { registrations += 1; status = .requiresApproval },
            unregister: { removals += 1; status = .notRegistered }
        )
        XCTAssertFalse(model.isRegistered)
        XCTAssertEqual(registrations, 0)
        await model.setEnabled(true)
        XCTAssertTrue(model.isRegistered)
        XCTAssertEqual(model.status, .requiresApproval)
        await model.setEnabled(true)
        XCTAssertEqual(registrations, 1)
        status = .enabled
        model.refresh()
        XCTAssertEqual(model.status, .enabled)
        await model.setEnabled(false)
        XCTAssertFalse(model.isRegistered)
        XCTAssertEqual(removals, 1)
        XCTAssertFalse(model.isUpdating)
    }

    @MainActor
    func testFailuresPreserveSystemState() async {
        struct Failure: Error {}
        var status = SMAppService.Status.notRegistered
        let model = LaunchAtLoginModel(
            readStatus: { status },
            register: { throw Failure() },
            unregister: { throw Failure() }
        )
        await model.setEnabled(true)
        XCTAssertFalse(model.isRegistered)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isUpdating)
        status = .enabled
        model.refresh()
        await model.setEnabled(false)
        XCTAssertTrue(model.isRegistered)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isUpdating)
    }
}
