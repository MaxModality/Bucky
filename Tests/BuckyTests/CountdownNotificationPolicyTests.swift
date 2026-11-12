import XCTest
import UserNotifications
@testable import Bucky

final class CountdownNotificationPolicyTests: XCTestCase {
    func testSchedulesOnlyUpcomingOneOffAndNeverBeforeFutureRecurringAnchor() throws {
        let now = date(2026, 1, 1)
        let anchor = date(2026, 2, 1)
        let recurring = Countdown(name: "Daily", targetDate: anchor, recurrence: .daily, timeZoneIdentifier: "UTC")
        let finished = Countdown(name: "Finished", targetDate: now.addingTimeInterval(-1))
        let upcoming = Countdown(name: "Upcoming", targetDate: now.addingTimeInterval(60))

        let occurrences = CountdownNotificationPolicy.occurrences(for: [recurring, finished, upcoming], after: now, limit: 4)

        XCTAssertEqual(occurrences.count, 4)
        XCTAssertEqual(occurrences.first?.countdown.id, upcoming.id)
        XCTAssertEqual(occurrences.filter { $0.countdown.id == recurring.id }.map(\.date), [
            anchor, date(2026, 2, 2), date(2026, 2, 3)
        ])
        XCTAssertFalse(occurrences.contains { $0.countdown.id == finished.id })
        for occurrence in occurrences {
            let trigger = UNCalendarNotificationTrigger(dateMatching: occurrence.dateComponents, repeats: false)
            XCTAssertFalse(trigger.repeats)
        }
    }

    func testGlobalQueueContainsNearestOccurrencesAndHasHardCap() {
        let now = date(2026, 1, 1)
        let daily = Countdown(name: "Daily", targetDate: date(2026, 1, 2), recurrence: .daily, timeZoneIdentifier: "UTC")
        let imminent = Countdown(name: "Soon", targetDate: now.addingTimeInterval(30))
        let distant = Countdown(name: "Later", targetDate: date(2028, 1, 1))
        let occurrences = CountdownNotificationPolicy.occurrences(for: [distant, daily, imminent], after: now, limit: 1_000)

        XCTAssertEqual(occurrences.count, 60)
        XCTAssertEqual(occurrences.first?.countdown.id, imminent.id)
        XCTAssertFalse(occurrences.contains { $0.countdown.id == distant.id })
        XCTAssertEqual(occurrences.map(\.date), occurrences.map(\.date).sorted())
        XCTAssertEqual(Set(occurrences.map(\.identifier)).count, occurrences.count)
        XCTAssertTrue(CountdownNotificationPolicy.occurrences(for: [daily], after: now, limit: -1).isEmpty)
    }

    func testLegacyAndOccurrenceIdentifiersResolveToSameCountdownForDeletion() throws {
        let countdown = Countdown(name: "Test", targetDate: date(2026, 2, 1))
        let occurrence = try XCTUnwrap(CountdownNotificationPolicy.occurrences(for: [countdown], after: date(2026, 1, 1)).first)
        XCTAssertEqual(CountdownNotificationPolicy.countdownID(for: occurrence.identifier), countdown.id)
        XCTAssertEqual(CountdownNotificationPolicy.countdownID(for: "bucky.countdown." + countdown.id.uuidString), countdown.id)
        XCTAssertNil(CountdownNotificationPolicy.countdownID(for: "other." + countdown.id.uuidString))
        XCTAssertNil(CountdownNotificationPolicy.countdownID(for: "bucky.countdown.invalid"))
    }

    func testNotificationComponentsUseStoredGregorianTimeZoneAndNeverRoundEarly() throws {
        let target = date(2026, 1, 2).addingTimeInterval(0.25)
        let countdown = Countdown(name: "Test", targetDate: target, timeZoneIdentifier: "America/Los_Angeles")
        let occurrence = try XCTUnwrap(CountdownNotificationPolicy.occurrences(for: [countdown], after: date(2026, 1, 1)).first)
        let components = occurrence.dateComponents
        XCTAssertEqual(components.calendar?.identifier, .gregorian)
        XCTAssertEqual(components.timeZone?.identifier, "America/Los_Angeles")
        let fireDate = try XCTUnwrap(components.date)
        XCTAssertGreaterThanOrEqual(fireDate, target)
        XCTAssertLessThan(fireDate.timeIntervalSince(target), 1)
    }

    func testRepeatedCountdownIDsDoNotConsumeQueueCapacityTwice() {
        let now = date(2026, 1, 1)
        let countdown = Countdown(name: "Test", targetDate: now.addingTimeInterval(60))
        XCTAssertEqual(CountdownNotificationPolicy.occurrences(for: [countdown, countdown], after: now).count, 1)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
