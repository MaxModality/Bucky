import XCTest
@testable import Bucky

@MainActor
final class CountdownRecurringIntegrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CountdownIntegration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testCreationChoicesDefaultToNeverAndIncludeSupportedSchedules() {
        let stone = CountdownStone(store: CountdownStore(fileURL: directory.appendingPathComponent("countdowns.json")))
        XCTAssertEqual(stone.inlineCreationConfiguration.options.map(\.id), CountdownRecurrence.allCases.map(\.rawValue))
        XCTAssertEqual(stone.inlineCreationConfiguration.options.first?.title, "Never")
    }

    func testAsyncCreationPersistsChoiceAndPublishesOnlyOnSuccess() async throws {
        let file = directory.appendingPathComponent("countdowns.json")
        let store = CountdownStore(fileURL: file)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var publications = 0
        let stone = CountdownStone(store: store, now: { now }, countdownsDidChange: { _ in publications += 1 })
        let success = await stone.submitInlineCreationAsync(name: "Weekly review", targetDate: now.addingTimeInterval(60), optionID: "weekly")
        XCTAssertTrue(success)
        XCTAssertEqual(CountdownStore(fileURL: file).countdowns.first?.recurrence, .weekly)
        XCTAssertEqual(publications, 1)
        let rejected = await stone.submitInlineCreationAsync(name: "Unknown", targetDate: now.addingTimeInterval(60), optionID: "unexpected")
        XCTAssertFalse(rejected)
        XCTAssertEqual(publications, 1)
    }

    func testLegacyAsyncCreationRemainsOneTime() async throws {
        let store = CountdownStore(fileURL: directory.appendingPathComponent("countdowns.json"))
        let stone = CountdownStone(store: store)
        let success = await stone.submitInlineCreationAsync(name: "One time", targetDate: Date().addingTimeInterval(600))
        XCTAssertTrue(success)
        XCTAssertEqual(store.countdowns.first?.recurrence, CountdownRecurrence.none)
    }

    func testRowMenuChangesRepeatWithoutRemovingOrDuplicatingCountdown() async throws {
        let store = CountdownStore(fileURL: directory.appendingPathComponent("countdowns.json"))
        let countdown = try XCTUnwrap(store.add(name: "Review", targetDate: Date().addingTimeInterval(600)))
        let stone = CountdownStone(store: store)
        let row = try XCTUnwrap(stone.snapshot(for: "").rows.first)
        let weekly = try XCTUnwrap(row.options.first { $0.title == "Weekly" })
        let result = await stone.performAsync(weekly.activation, for: row)
        XCTAssertEqual(result, .handled(shouldRefresh: true, resetSelection: false, shouldHide: false))
        XCTAssertEqual(store.countdowns.map(\.id), [countdown.id])
        XCTAssertEqual(store.countdowns.first?.recurrence, .weekly)
        let updatedRow = try XCTUnwrap(stone.snapshot(for: "").rows.first)
        XCTAssertTrue(try XCTUnwrap(updatedRow.options.first { $0.title == "Weekly" }).isSelected)
        XCTAssertNotEqual(row.identityKey, updatedRow.identityKey)
    }

    func testRowActionCannotChangeDifferentCountdown() async throws {
        let store = CountdownStore(fileURL: directory.appendingPathComponent("countdowns.json"))
        let countdown = try XCTUnwrap(store.add(name: "Review", targetDate: Date().addingTimeInterval(600)))
        let stone = CountdownStone(store: store)
        let row = try XCTUnwrap(stone.snapshot(for: "").rows.first)
        let result = await stone.performAsync(.providerAction("repeat:\(UUID()):daily"), for: row)
        XCTAssertEqual(result, .unhandled)
        XCTAssertEqual(store.countdowns.first?.id, countdown.id)
        XCTAssertEqual(store.countdowns.first?.recurrence, CountdownRecurrence.none)
    }

    func testLauncherForwardsCreationChoiceThroughGenericContract() async throws {
        let store = CountdownStore(fileURL: directory.appendingPathComponent("countdowns.json"))
        let stone = CountdownStone(store: store)
        let model = LiquidGlassLauncherModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            inclusionStore: InclusionStore(fileURL: directory.appendingPathComponent("inclusions.json")),
            exclusionStore: ExclusionStore(fileURL: directory.appendingPathComponent("exclusions.json")),
            calculationHistoryStore: CalculationHistoryStore(fileURL: directory.appendingPathComponent("calculations.json")),
            dictionaryHistoryStore: DictionaryHistoryStore(fileURL: directory.appendingPathComponent("dictionary.json")),
            stoneProviders: [stone], applicationIndexLoader: { _ in [] }
        )
        model.show(mode: try XCTUnwrap(model.availableModes.first { $0.stoneID == .countdowns }))
        let success = await model.submitInlineCreationAsync(name: "Daily review", targetDate: Date().addingTimeInterval(600), optionID: "daily")
        XCTAssertTrue(success)
        XCTAssertEqual(store.countdowns.first?.recurrence, .daily)
        XCTAssertEqual(model.resultSnapshot.rows.first?.countdownRecurrence, .daily)
    }
}
