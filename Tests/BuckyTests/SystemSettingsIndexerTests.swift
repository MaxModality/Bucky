import XCTest
@testable import Bucky

final class SystemSettingsIndexerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuckySystemSettingsIndexerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testLoadsTopLevelSystemSettingsPanesFromSidebarAndMatchingExtensions() throws {
        let sidebarURL = temporaryDirectory.appendingPathComponent("Sidebar.plist")
        try writePropertyList(
            [
                ["content": [
                    "com.apple.Displays-Settings.extension",
                    "com.apple.Wallpaper-Settings.extension",
                    "com.apple.Hidden-Settings.extension"
                ]]
            ],
            to: sidebarURL
        )

        let extensionsRoot = temporaryDirectory.appendingPathComponent("Extensions", isDirectory: true)
        try writeExtension(
            bundleDirectoryName: "DisplaysExt.appex",
            bundleIdentifier: "com.apple.Displays-Settings.extension",
            displayName: "Displays",
            allowsSystemPreferencesURL: true,
            under: extensionsRoot
        )
        try writeExtension(
            bundleDirectoryName: "Wallpaper.appex",
            bundleIdentifier: "com.apple.Wallpaper-Settings.extension",
            displayName: "Wallpaper",
            allowsSystemPreferencesURL: true,
            under: extensionsRoot
        )
        try writeExtension(
            bundleDirectoryName: "Hidden.appex",
            bundleIdentifier: "com.apple.Hidden-Settings.extension",
            displayName: "Hidden",
            allowsSystemPreferencesURL: false,
            under: extensionsRoot
        )

        let items = SystemSettingsIndexer(
            sidebarResourcesDirectory: temporaryDirectory,
            extensionRoots: [extensionsRoot]
        ).load()

        XCTAssertEqual(items.map(\.title), ["Displays", "Wallpaper"])
        XCTAssertEqual(items.map(\.subtitle), ["System Settings", "System Settings"])
        XCTAssertEqual(items.map(\.category), [.settings, .settings])
        XCTAssertEqual(
            items.map(\.launchTarget),
            [
                .url(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!),
                .url(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
            ]
        )
        XCTAssertEqual(items.map(\.searchText), ["displays system settings", "wallpaper system settings"])
    }

    func testDoesNotCreateDeepSectionItemsFromSearchTermsFiles() throws {
        let sidebarURL = temporaryDirectory.appendingPathComponent("Sidebar.plist")
        try writePropertyList(
            [["content": ["com.apple.Displays-Settings.extension"]]],
            to: sidebarURL
        )

        let extensionsRoot = temporaryDirectory.appendingPathComponent("Extensions", isDirectory: true)
        let extensionURL = try writeExtension(
            bundleDirectoryName: "DisplaysExt.appex",
            bundleIdentifier: "com.apple.Displays-Settings.extension",
            displayName: "Displays",
            allowsSystemPreferencesURL: true,
            under: extensionsRoot
        )
        let searchTermsURL = extensionURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: searchTermsURL, withIntermediateDirectories: true)
        try writePropertyList(
            [
                "nightShiftSection": [
                    "localizableStrings": [
                        ["title": "Night Shift options", "index": "warm color"]
                    ]
                ]
            ],
            to: searchTermsURL.appendingPathComponent("DisplaysSearchGroups.searchTerms")
        )

        let items = SystemSettingsIndexer(
            sidebarResourcesDirectory: temporaryDirectory,
            extensionRoots: [extensionsRoot]
        ).load()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Displays")
        XCTAssertFalse(items.contains { $0.title == "Night Shift options" })
    }

    func testMergesAllSidebarFilenamesAndContentFormatsWithoutDuplicatePanes() throws {
        let displaysID = "com.apple.Displays-Settings.extension"
        let wallpaperID = "com.apple.Wallpaper-Settings.extension"
        let privacyID = "com.apple.PrivacySecurity-Settings.extension"
        try writePropertyList(
            [["content": [displaysID]]],
            to: temporaryDirectory.appendingPathComponent("Sidebar.plist")
        )
        try writePropertyList(
            [[
                "content": [displaysID],
                "ordered_content": [wallpaperID, displaysID],
                "sortable_content": [privacyID, wallpaperID]
            ]],
            to: temporaryDirectory.appendingPathComponent("SidebarFutureLayout.plist")
        )
        let extensionsRoot = temporaryDirectory.appendingPathComponent("Extensions", isDirectory: true)
        for (index, entry) in [(displaysID, "Displays"), (wallpaperID, "Wallpaper"), (privacyID, "Privacy & Security")].enumerated() {
            try writeExtension(
                bundleDirectoryName: "Pane\(index).appex",
                bundleIdentifier: entry.0,
                displayName: entry.1,
                allowsSystemPreferencesURL: true,
                under: extensionsRoot
            )
        }

        let items = SystemSettingsIndexer(
            sidebarResourcesDirectory: temporaryDirectory,
            extensionRoots: [extensionsRoot]
        ).load()

        XCTAssertEqual(items.map(\.title), ["Displays", "Wallpaper", "Privacy & Security"])
        XCTAssertEqual(Set(items.map(\.launchTarget)).count, items.count)
    }

    func testIgnoresMalformedUnrelatedAndNestedSidebarFiles() throws {
        let displaysID = "com.apple.Displays-Settings.extension"
        let unrelatedID = "com.apple.Unrelated-Settings.extension"
        try Data("invalid property list".utf8).write(to: temporaryDirectory.appendingPathComponent("SidebarBroken.plist"))
        try writePropertyList(
            ["unexpected": "root structure"],
            to: temporaryDirectory.appendingPathComponent("SidebarWrongShape.plist")
        )
        try writePropertyList(
            [["content": [unrelatedID]]],
            to: temporaryDirectory.appendingPathComponent("Other.plist")
        )
        let nestedDirectory = temporaryDirectory.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try writePropertyList(
            [["content": [unrelatedID]]],
            to: nestedDirectory.appendingPathComponent("SidebarNested.plist")
        )
        try writePropertyList(
            [["ordered_content": [displaysID]]],
            to: temporaryDirectory.appendingPathComponent("Sidebar999.plist")
        )
        let extensionsRoot = temporaryDirectory.appendingPathComponent("Extensions", isDirectory: true)
        for (identifier, name) in [(displaysID, "Displays"), (unrelatedID, "Unrelated")] {
            try writeExtension(
                bundleDirectoryName: "\(name).appex",
                bundleIdentifier: identifier,
                displayName: name,
                allowsSystemPreferencesURL: true,
                under: extensionsRoot
            )
        }

        let items = SystemSettingsIndexer(
            sidebarResourcesDirectory: temporaryDirectory,
            extensionRoots: [extensionsRoot]
        ).load()

        XCTAssertEqual(items.map(\.title), ["Displays"])
    }

    func testIncludesHostedLoginItemsPageAndStopsAtCyclesAndIneligibleExtensions() throws {
        let generalID = "com.apple.systempreferences.GeneralSettings"
        let loginItemsID = "com.apple.LoginItems-Settings.extension"
        let disabledID = "com.apple.Disabled-Settings.extension"
        let unlistedID = "com.apple.Unlisted-Settings.extension"
        try writePropertyList(
            [["ordered_content": [generalID]]],
            to: temporaryDirectory.appendingPathComponent("SidebarAnyVersion.plist")
        )
        let extensionsRoot = temporaryDirectory.appendingPathComponent("Extensions", isDirectory: true)
        try writeExtension(
            bundleDirectoryName: "General.appex",
            bundleIdentifier: generalID,
            displayName: "General",
            allowsSystemPreferencesURL: true,
            hostedBundleIDs: [loginItemsID, "com.apple.Missing-Settings.extension", disabledID],
            under: extensionsRoot
        )
        try writeExtension(
            bundleDirectoryName: "LoginItems.appex",
            bundleIdentifier: loginItemsID,
            displayName: "Login Items",
            allowsSystemPreferencesURL: true,
            hostedBundleIDs: [generalID, loginItemsID],
            under: extensionsRoot
        )
        try writeExtension(
            bundleDirectoryName: "Disabled.appex",
            bundleIdentifier: disabledID,
            displayName: "Disabled",
            allowsSystemPreferencesURL: false,
            hostedBundleIDs: [unlistedID],
            under: extensionsRoot
        )
        try writeExtension(
            bundleDirectoryName: "Unlisted.appex",
            bundleIdentifier: unlistedID,
            displayName: "Unlisted",
            allowsSystemPreferencesURL: true,
            under: extensionsRoot
        )

        let items = SystemSettingsIndexer(
            sidebarResourcesDirectory: temporaryDirectory,
            extensionRoots: [extensionsRoot]
        ).load()

        XCTAssertEqual(items.map(\.title), ["General", "Login Items"])
        XCTAssertEqual(items.last?.launchTarget, .url(URL(string: "x-apple.systempreferences:\(loginItemsID)")!))
        XCTAssertTrue(items.allSatisfy { $0.category == .settings })
    }

    func testRejectsBundleIdentifiersContainingURLComponents() throws {
        let identifiers = [
            "com.apple.Invalid-Settings.extension?section=private",
            "com.apple.Invalid-Settings.extension#private",
            "com.apple.Invalid:Settings.extension"
        ]
        try writePropertyList(
            [["content": identifiers]],
            to: temporaryDirectory.appendingPathComponent("Sidebar.plist")
        )
        let extensionsRoot = temporaryDirectory.appendingPathComponent("Extensions", isDirectory: true)
        for (index, identifier) in identifiers.enumerated() {
            try writeExtension(
                bundleDirectoryName: "Invalid\(index).appex",
                bundleIdentifier: identifier,
                displayName: "Invalid",
                allowsSystemPreferencesURL: true,
                under: extensionsRoot
            )
        }

        let items = SystemSettingsIndexer(
            sidebarResourcesDirectory: temporaryDirectory,
            extensionRoots: [extensionsRoot]
        ).load()

        XCTAssertTrue(items.isEmpty)
    }

    func testApplicationLaunchItemsDefaultToAppCategory() {
        let url = URL(fileURLWithPath: "/Applications/Notes.app")

        let item = LaunchItem(
            title: "Notes",
            subtitle: url.path,
            url: url,
            searchText: "notes"
        )

        XCTAssertEqual(item.category, .app)
        XCTAssertEqual(LaunchItemCategory.app.title, "App")
        XCTAssertEqual(LaunchItemCategory.settings.title, "Settings")
        XCTAssertEqual(LaunchItemCategory.action.title, "Action")
    }

    @discardableResult
    private func writeExtension(
        bundleDirectoryName: String,
        bundleIdentifier: String,
        displayName: String,
        allowsSystemPreferencesURL: Bool,
        hostedBundleIDs: [String] = [],
        under root: URL
    ) throws -> URL {
        let contentsURL = root
            .appendingPathComponent(bundleDirectoryName, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        try writePropertyList(
            [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleDisplayName": displayName,
                "EXAppExtensionAttributes": [
                    "SettingsExtensionAttributes": [
                        "allowsXAppleSystemPreferencesURLScheme": allowsSystemPreferencesURL,
                        "hosted_bundles": hostedBundleIDs
                    ]
                ]
            ],
            to: contentsURL.appendingPathComponent("Info.plist")
        )
        return contentsURL.deletingLastPathComponent()
    }

    private func writePropertyList(_ propertyList: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}
