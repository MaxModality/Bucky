import AppKit
import XCTest
@testable import Bucky

@MainActor
final class StatusMenuControllerTests: XCTestCase {
    private var controller: StatusMenuController?

    override func tearDown() {
        if let controller {
            NSStatusBar.system.removeStatusItem(controller.statusItem)
        }
        controller = nil
        super.tearDown()
    }

    func testStatusItemUsesCompactAccessibleNativePresentation() throws {
        var openCount = 0
        var reindexCount = 0
        var settingsCount = 0
        controller = StatusMenuController(
            openAction: { openCount += 1 },
            reindexAction: { reindexCount += 1 },
            settingsAction: { settingsCount += 1 }
        )

        let statusItem = try XCTUnwrap(controller?.statusItem)
        let button = try XCTUnwrap(statusItem.button)
        let image = try XCTUnwrap(button.image)
        let menu = try XCTUnwrap(statusItem.menu)
        let openItem = menu.items[0]
        let reindexItem = menu.items[1]
        let settingsItem = menu.items[2]
        let separatorItem = menu.items[3]
        let quitItem = menu.items[4]
        let versionSeparatorItem = menu.items[5]
        let versionItem = menu.items[6]

        XCTAssertEqual(statusItem.length, NSStatusItem.squareLength)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(button.imageScaling, .scaleProportionallyDown)
        XCTAssertTrue(statusItem.isVisible)
        XCTAssertEqual(image.accessibilityDescription, "Bucky")
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.toolTip, "Bucky")
        XCTAssertEqual(menu.items.map(\.title), [
            "Open Bucky",
            "Reindex Applications",
            "Settings...",
            "",
            "Quit Bucky",
            "",
            "Bucky \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown version")"
        ])

        XCTAssertMenuItem(openItem, targets: controller, action: "open", keyEquivalent: "")
        XCTAssertMenuItem(reindexItem, targets: controller, action: "reindex", keyEquivalent: "")
        XCTAssertMenuItem(settingsItem, targets: controller, action: "settings", keyEquivalent: ",")
        XCTAssertTrue(separatorItem.isSeparatorItem)
        XCTAssertMenuItem(quitItem, targets: controller, action: "quit", keyEquivalent: "q")
        XCTAssertTrue(versionSeparatorItem.isSeparatorItem)
        XCTAssertFalse(versionItem.isEnabled)

        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 2)

        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(reindexCount, 1)
        XCTAssertEqual(settingsCount, 1)
    }

    func testStatusButtonFallsBackToCompactLabelWhenSymbolImageIsUnavailable() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)

        StatusMenuController.configureButton(button, image: nil)

        XCTAssertNil(button.image)
        XCTAssertEqual(button.title, "B")
        XCTAssertEqual(button.imagePosition, .noImage)
        XCTAssertEqual(button.toolTip, "Bucky")
    }

    private func XCTAssertMenuItem(
        _ item: NSMenuItem,
        targets controller: StatusMenuController?,
        action: String,
        keyEquivalent: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(item.target === controller, file: file, line: line)
        XCTAssertEqual(item.action.map(NSStringFromSelector), action, file: file, line: line)
        XCTAssertEqual(item.keyEquivalent, keyEquivalent, file: file, line: line)
    }
}
