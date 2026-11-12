import XCTest
@testable import Bucky

final class CountdownRecurrenceTests: XCTestCase {
    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func countdown(_ anchor: String, _ recurrence: CountdownRecurrence,
                           zone: String = "UTC") -> Countdown {
        Countdown(name: "Example", targetDate: date(anchor), recurrence: recurrence,
                  timeZoneIdentifier: zone)
    }

    func testOneTimeCompletesAndFutureAnchorIsUnchanged() {
        let anchor = date("2026-10-16T09:00:00Z")
        let once = countdown("2026-10-16T09:00:00Z", .none)
        XCTAssertEqual(once.nextTargetDate(after: anchor.addingTimeInterval(-1)), anchor)
        XCTAssertNil(once.nextTargetDate(after: anchor))
        for recurrence in CountdownRecurrence.allCases where recurrence != .none {
            XCTAssertEqual(countdown("2026-10-16T09:00:00Z", recurrence)
                .nextTargetDate(after: anchor.addingTimeInterval(-1)), anchor)
        }
    }

    func testDailyExactBoundaryAdvancesAndPreservesSubseconds() {
        var value = countdown("2026-10-16T09:00:00Z", .daily)
        value.targetDate = value.targetDate.addingTimeInterval(0.25)
        XCTAssertEqual(value.nextTargetDate(after: value.targetDate),
                       date("2026-10-17T09:00:00Z").addingTimeInterval(0.25))
        XCTAssertEqual(value.nextTargetDate(after: date("2026-10-17T08:59:00Z")),
                       date("2026-10-17T09:00:00Z").addingTimeInterval(0.25))
    }

    func testWeekdaysSkipsWeekendEvenWhenAnchorIsStillInFuture() {
        let value = countdown("2026-10-17T09:00:00Z", .weekdays)
        XCTAssertEqual(value.nextTargetDate(after: date("2026-10-16T08:00:00Z")),
                       date("2026-10-19T09:00:00Z"))
        XCTAssertEqual(value.nextTargetDate(after: date("2026-10-23T09:00:00Z")),
                       date("2026-10-26T09:00:00Z"))
    }

    func testWeeklyRetainsOriginalWeekdayAfterLongGap() {
        let value = countdown("2000-01-03T09:00:00Z", .weekly)
        XCTAssertEqual(value.nextTargetDate(after: date("2100-01-04T10:00:00Z")),
                       date("2100-01-11T09:00:00Z"))
    }

    func testMonthlySkipsShortMonthsWithoutDrifting() {
        let value = countdown("2026-01-31T09:00:00Z", .monthly)
        XCTAssertEqual(value.nextTargetDate(after: date("2026-01-31T09:00:00Z")),
                       date("2026-03-31T09:00:00Z"))
        XCTAssertEqual(value.nextTargetDate(after: date("2026-03-31T09:00:00Z")),
                       date("2026-05-31T09:00:00Z"))
    }

    func testLeapAnniversarySkipsNonLeapYearsIncludingCentury() {
        let value = countdown("2024-02-29T09:00:00Z", .yearly)
        XCTAssertEqual(value.nextTargetDate(after: date("2025-01-01T00:00:00Z")),
                       date("2028-02-29T09:00:00Z"))
        XCTAssertEqual(value.nextTargetDate(after: date("2099-01-01T00:00:00Z")),
                       date("2104-02-29T09:00:00Z"))
    }

    func testDailyDSTSpringMissingTimeMovesForwardThenReturnsToAnchorTime() {
        let value = countdown("2026-03-07T10:30:00Z", .daily, zone: "America/Los_Angeles")
        XCTAssertEqual(value.nextTargetDate(after: date("2026-03-08T08:00:00Z")),
                       date("2026-03-08T10:00:00Z"))
        XCTAssertEqual(value.nextTargetDate(after: date("2026-03-08T10:00:00Z")),
                       date("2026-03-09T09:30:00Z"))
    }

    func testMissingMidnightDoesNotSkipADayWithAValidTargetTime() {
        let daily = countdown("2026-04-23T07:00:00Z", .daily, zone: "Africa/Cairo")
        XCTAssertEqual(daily.nextTargetDate(after: date("2026-04-23T21:00:00Z")),
                       date("2026-04-24T06:00:00Z"))
        let monthly = countdown("2026-03-24T07:00:00Z", .monthly, zone: "Africa/Cairo")
        XCTAssertEqual(monthly.nextTargetDate(after: date("2026-04-23T21:00:00Z")),
                       date("2026-04-24T06:00:00Z"))
    }

    func testDailyDSTFallUsesFirstOccurrenceOnly() {
        let value = countdown("2026-10-31T08:30:00Z", .daily, zone: "America/Los_Angeles")
        XCTAssertEqual(value.nextTargetDate(after: date("2026-11-01T07:00:00Z")),
                       date("2026-11-01T08:30:00Z"))
        XCTAssertEqual(value.nextTargetDate(after: date("2026-11-01T08:30:00Z")),
                       date("2026-11-02T09:30:00Z"))
    }

    func testDailyJumpsOverDecadesOfMissedOccurrences() {
        let value = countdown("1980-01-01T09:00:00Z", .daily)
        XCTAssertEqual(value.nextTargetDate(after: date("2100-10-16T10:00:00Z")),
                       date("2100-10-17T09:00:00Z"))
    }

    func testLegacyDecodeAndNewRoundTrip() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Example","targetDate":100}
        """
        let decoded = try JSONDecoder().decode(Countdown.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.recurrence, .none)
        XCTAssertEqual(decoded.timeZoneIdentifier, TimeZone.current.identifier)
        let recurring = countdown("2026-10-16T09:00:00Z", .weekdays, zone: "Europe/London")
        XCTAssertEqual(try JSONDecoder().decode(Countdown.self, from: JSONEncoder().encode(recurring)), recurring)
    }

    func testInvalidPersistedTimezonePreservesFileAndDisablesWrites() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let invalid = Countdown(name: "Example", targetDate: Date(), recurrence: .daily,
                                timeZoneIdentifier: "Invalid/Timezone")
        let data = try JSONEncoder().encode(CountdownsFile(countdowns: [invalid]))
        try data.write(to: url)
        let store = CountdownStore(fileURL: url)
        XCTAssertNotNil(store.lastError)
        XCTAssertNil(store.add(name: "Example", targetDate: Date()))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertNil(invalid.nextTargetDate(after: Date()))
    }

    func testStoreNormalizationAndUpdatesPreserveSchedule() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let value = Countdown(name: "  Example   countdown  ", targetDate: Date(), recurrence: .yearly,
                              timeZoneIdentifier: "Europe/London")
        try JSONEncoder().encode(CountdownsFile(countdowns: [value])).write(to: url)
        let store = CountdownStore(fileURL: url)
        XCTAssertEqual(store.countdowns.first?.name, "Example countdown")
        XCTAssertEqual(store.countdowns.first?.recurrence, .yearly)
        XCTAssertEqual(store.countdowns.first?.timeZoneIdentifier, "Europe/London")
        XCTAssertTrue(store.update(id: value.id, name: "Example", targetDate: value.targetDate))
        XCTAssertEqual(CountdownStore(fileURL: url).countdowns.first?.recurrence, .yearly)
        XCTAssertEqual(CountdownStore(fileURL: url).countdowns.first?.timeZoneIdentifier, "Europe/London")
        XCTAssertNil(store.add(name: "Invalid", targetDate: Date(), timeZoneIdentifier: "Invalid/Timezone"))
    }

    @MainActor
    func testAsyncAddAndRecurrenceUpdatePersistWithoutChangingAnchorOrTimezone() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CountdownStore(fileURL: url)
        let target = date("2026-10-16T09:00:00Z")
        let added = await store.addAsync(name: "Example", targetDate: target, recurrence: .daily,
                                         timeZoneIdentifier: "Europe/London")
        let value = try XCTUnwrap(added)
        let updated = await store.updateAsync(id: value.id, recurrence: .monthly)
        XCTAssertTrue(updated)
        let reloaded = try XCTUnwrap(CountdownStore(fileURL: url).countdowns.first)
        XCTAssertEqual(reloaded.recurrence, .monthly)
        XCTAssertEqual(reloaded.targetDate, target)
        XCTAssertEqual(reloaded.timeZoneIdentifier, "Europe/London")
    }

    @MainActor
    func testTurningOffRepeatKeepsTheUpcomingOccurrence() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CountdownStore(fileURL: url)
        let added = await store.addAsync(name: "Example", targetDate: date("2026-10-15T09:00:00Z"),
                                         recurrence: .daily, timeZoneIdentifier: "UTC")
        let value = try XCTUnwrap(added)
        let updated = await store.updateAsync(id: value.id, recurrence: .none,
                                               now: date("2026-10-16T10:00:00Z"))
        XCTAssertTrue(updated)
        let reloaded = try XCTUnwrap(CountdownStore(fileURL: url).countdowns.first)
        XCTAssertEqual(reloaded.recurrence, .none)
        XCTAssertEqual(reloaded.targetDate, date("2026-10-17T09:00:00Z"))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BuckyRecurrence-\(UUID()).json")
    }
}
