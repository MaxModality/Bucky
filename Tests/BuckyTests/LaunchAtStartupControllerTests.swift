import ServiceManagement
import XCTest
@testable import Bucky

final class LaunchAtStartupControllerTests: XCTestCase {
    func testMissingRecordCanBeRegisteredAndAlreadyRemovedItemCanBeDisabled() throws {
        for status in [SMAppService.Status.notRegistered, .notFound] {
            let service = LoginItemStub(status: status)
            try LaunchAtStartupController.setEnabled(false, service: service)
            XCTAssertEqual(service.operations, [])

            try LaunchAtStartupController.setEnabled(true, service: service)
            XCTAssertEqual(service.operations, ["register"])
        }
    }

    func testApprovalRequiredOpensSettingsWithoutReregisteringOrUnregistering() throws {
        let service = LoginItemStub(status: .requiresApproval)
        var settingsOpened = 0
        for enabled in [false, true] {
            try LaunchAtStartupController.setEnabled(enabled, service: service) {
                settingsOpened += 1
            }
        }
        XCTAssertEqual(settingsOpened, 2)
        XCTAssertEqual(service.operations, [])
    }

    func testEnabledItemIsUnregisteredAndRealServiceFailuresArePreserved() throws {
        let service = LoginItemStub(status: .enabled)
        try LaunchAtStartupController.setEnabled(true, service: service)
        XCTAssertEqual(service.operations, [])
        try LaunchAtStartupController.setEnabled(false, service: service)
        XCTAssertEqual(service.operations, ["unregister"])

        service.failure = .denied
        XCTAssertThrowsError(try LaunchAtStartupController.setEnabled(false, service: service)) {
            XCTAssertEqual($0 as? LoginItemStub.Failure, .denied)
        }
    }
}

private final class LoginItemStub: LaunchAtStartupService {
    enum Failure: Error { case denied }
    let status: SMAppService.Status
    var operations: [String] = []
    var failure: Failure?

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        operations.append("register")
        if let failure { throw failure }
    }

    func unregister() throws {
        operations.append("unregister")
        if let failure { throw failure }
    }
}
