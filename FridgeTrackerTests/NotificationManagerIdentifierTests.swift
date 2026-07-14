import XCTest
import SwiftData
@testable import FridgeTracker

@MainActor
final class NotificationManagerIdentifierTests: XCTestCase {
    private static let defaultsSuiteName = "NotificationManagerIdentifierTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: Self.defaultsSuiteName)!
        defaults.removePersistentDomain(forName: Self.defaultsSuiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.defaultsSuiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeItem(
        in context: ModelContext,
        name: String = "牛奶",
        category: FoodCategory = .dairy,
        expiryDate: Date = .now
    ) -> FoodItem {
        let item = FoodItem(name: name, category: category, storageZone: .fridge, expiryDate: expiryDate)
        context.insert(item)
        return item
    }

    // MARK: - Strict namespace

    func testIdentifiersUseStrictFoodNamespace() throws {
        let context = try TestModelContainer.makeContext()
        let item = makeItem(in: context)

        XCTAssertEqual(NotificationManager.advanceIdentifier(for: item), "food.\(item.uuid.uuidString).advance")
        XCTAssertEqual(NotificationManager.expiryIdentifier(for: item), "food.\(item.uuid.uuidString).expiry")
        XCTAssertTrue(NotificationManager.isFoodReminderIdentifier(NotificationManager.advanceIdentifier(for: item)))
        XCTAssertTrue(NotificationManager.isFoodReminderIdentifier(NotificationManager.expiryIdentifier(for: item)))
    }

    func testStrictMatcherRejectsLegacyAndOtherUUIDNamespaces() {
        let uuid = UUID().uuidString

        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier(uuid))
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier(uuid + ".advance"))
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier(uuid + ".expiry"))
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier("analytics.\(uuid).expiry"))
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier("food.\(uuid).other"))
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier("food.not-a-uuid.expiry"))
    }

    func testLegacyMatcherOnlyAcceptsKnownPreviousFormats() {
        let uuid = UUID().uuidString

        XCTAssertTrue(NotificationManager.isLegacyFoodReminderIdentifier(uuid))
        XCTAssertTrue(NotificationManager.isLegacyFoodReminderIdentifier(uuid + ".advance"))
        XCTAssertTrue(NotificationManager.isLegacyFoodReminderIdentifier(uuid + ".expiry"))
        XCTAssertFalse(NotificationManager.isLegacyFoodReminderIdentifier("prefix." + uuid))
        XCTAssertFalse(NotificationManager.isLegacyFoodReminderIdentifier(uuid + ".other"))
    }

    // MARK: - 60-event planner

    func testPlannerKeepsNearestSixtyEventsAndReportsOverflow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 12)))
        let expiry = try XCTUnwrap(calendar.date(byAdding: .day, value: 10, to: now))
        let context = try TestModelContainer.makeContext()
        let items = (0..<40).map { makeItem(in: context, name: "食材\($0)", expiryDate: expiry) }

        let plan = NotificationManager.planReminders(
            for: items,
            now: now,
            daysBeforeOverride: 1,
            limit: 60,
            calendar: calendar
        )

        XCTAssertEqual(plan.desiredCount, 80)
        XCTAssertEqual(plan.candidates.count, 60)
        XCTAssertEqual(plan.overflowCount, 20)
        XCTAssertTrue(zip(plan.candidates, plan.candidates.dropFirst()).allSatisfy { $0.fireDate <= $1.fireDate })
        XCTAssertEqual(Set(plan.candidates.map(\.identifier)).count, 60)
    }

    func testExpiryEventWinsBudgetTieOverAdvanceEvent() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Noon makes the first item's same-day advance reminder already missed, leaving a true
        // tie tomorrow between its expiry event and the second item's advance event.
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 12)))
        let context = try TestModelContainer.makeContext()
        let expiresTomorrow = makeItem(
            in: context,
            name: "明天到期",
            expiryDate: try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))
        )
        let advanceTomorrow = makeItem(
            in: context,
            name: "后天到期",
            expiryDate: try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: now))
        )

        let plan = NotificationManager.planReminders(
            for: [advanceTomorrow, expiresTomorrow],
            now: now,
            daysBeforeOverride: 1,
            limit: 1,
            calendar: calendar
        )

        XCTAssertEqual(plan.desiredCount, 3)
        XCTAssertEqual(plan.candidates.first?.foodID, expiresTomorrow.uuid)
        XCTAssertEqual(plan.candidates.first?.kind, .expiry)
    }

    func testImmediateFallbackIsOnlyAddedForExplicitItem() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 12)))
        let context = try TestModelContainer.makeContext()
        let first = makeItem(in: context, name: "甲", expiryDate: now)
        let second = makeItem(in: context, name: "乙", expiryDate: now)

        let plan = NotificationManager.planReminders(
            for: [first, second],
            now: now,
            immediateFallbackItemID: second.uuid,
            calendar: calendar
        )

        XCTAssertEqual(plan.candidates.count, 1)
        XCTAssertEqual(plan.candidates.first?.foodID, second.uuid)
        XCTAssertEqual(plan.candidates.first?.trigger, .interval(60))
    }

    // MARK: - Capacity-safe reconciliation

    func testDisjointSixtyToSixtyRemovesDeadFoodRemindersBeforeAdding() {
        let oldFoodIDs = (0..<60).map { _ in UUID() }
        let newFoodIDs = (0..<60).map { _ in UUID() }
        let oldIdentifiers = oldFoodIDs.map(NotificationManager.expiryIdentifier(for:))
        let desiredIdentifiers = Set(newFoodIDs.map(NotificationManager.expiryIdentifier(for:)))
        let unrelatedIdentifier = "analytics.daily-summary"

        let preflight = NotificationManager.reconciliationPreflight(
            pendingIdentifiers: oldIdentifiers + [unrelatedIdentifier],
            desiredIdentifiers: desiredIdentifiers,
            liveFoodIDs: Set(newFoodIDs),
            systemLimit: 64
        )

        XCTAssertEqual(Set(preflight.identifiersToRemoveBeforeAdding), Set(oldIdentifiers))
        XCTAssertFalse(preflight.identifiersToRemoveBeforeAdding.contains(unrelatedIdentifier))
        XCTAssertEqual(Set(preflight.missingDesiredIdentifiers), desiredIdentifiers)
        let finalCount = oldIdentifiers.count + 1
            - preflight.identifiersToRemoveBeforeAdding.count
            + desiredIdentifiers.count
        XCTAssertLessThanOrEqual(finalCount, 64)
    }

    func testCapacityPreflightRemovesOnlyRequiredLiveStaleReminders() {
        let liveFoodIDs = (0..<60).map { _ in UUID() }
        let staleIdentifiers = liveFoodIDs.map(NotificationManager.advanceIdentifier(for:))
        let desiredIdentifiers = Set(liveFoodIDs.map(NotificationManager.expiryIdentifier(for:)))

        let preflight = NotificationManager.reconciliationPreflight(
            pendingIdentifiers: staleIdentifiers,
            desiredIdentifiers: desiredIdentifiers,
            liveFoodIDs: Set(liveFoodIDs),
            systemLimit: 64
        )

        // Four slots are already free, so only 56 live-but-stale requests must be sacrificed.
        XCTAssertEqual(preflight.identifiersToRemoveBeforeAdding.count, 56)
        XCTAssertTrue(Set(preflight.identifiersToRemoveBeforeAdding).isSubset(of: Set(staleIdentifiers)))
    }

    func testPreflightCleansKnownLegacyFormatsButPreservesUnrelatedNotifications() {
        let deletedFoodID = UUID()
        let legacyIdentifiers = [
            deletedFoodID.uuidString,
            deletedFoodID.uuidString + ".advance",
            deletedFoodID.uuidString + ".expiry"
        ]
        let unrelatedIdentifiers = [
            "analytics.\(deletedFoodID.uuidString).expiry",
            "shopping.weekly-reminder",
            "food.not-a-uuid.expiry"
        ]

        let preflight = NotificationManager.reconciliationPreflight(
            pendingIdentifiers: legacyIdentifiers + unrelatedIdentifiers,
            desiredIdentifiers: [],
            liveFoodIDs: [],
            systemLimit: 64
        )

        XCTAssertEqual(Set(preflight.identifiersToRemoveBeforeAdding), Set(legacyIdentifiers))
        XCTAssertTrue(Set(preflight.identifiersToRemoveBeforeAdding).isDisjoint(with: unrelatedIdentifiers))
        XCTAssertEqual(NotificationManager.foodID(fromManagedReminderIdentifier: legacyIdentifiers[0]), deletedFoodID)
        XCTAssertEqual(NotificationManager.foodID(fromManagedReminderIdentifier: legacyIdentifiers[1]), deletedFoodID)
        XCTAssertNil(NotificationManager.foodID(fromManagedReminderIdentifier: unrelatedIdentifiers[0]))
    }

    func testVerificationTreatsAddCallbackFailureAsFailureEvenWhenIDRemainsPending() {
        let first = NotificationManager.expiryIdentifier(for: UUID())
        let second = NotificationManager.expiryIdentifier(for: UUID())

        let verification = NotificationManager.verifyReconciliation(
            desiredIdentifiers: [first, second],
            pendingIdentifiers: [first, second],
            addFailedIdentifiers: [second]
        )

        XCTAssertEqual(verification.scheduledCount, 2)
        XCTAssertEqual(verification.failedIdentifiers, [second])
        XCTAssertFalse(verification.isSuccessful)
    }

    func testVerificationDetectsSilentlyDroppedRequest() {
        let retained = NotificationManager.expiryIdentifier(for: UUID())
        let silentlyDropped = NotificationManager.expiryIdentifier(for: UUID())

        let verification = NotificationManager.verifyReconciliation(
            desiredIdentifiers: [retained, silentlyDropped],
            pendingIdentifiers: [retained, "analytics.keep"],
            addFailedIdentifiers: []
        )

        XCTAssertEqual(verification.scheduledCount, 1)
        XCTAssertEqual(verification.failedIdentifiers, [silentlyDropped])
        XCTAssertFalse(verification.isSuccessful)
    }

    func testPreRemovalConfirmationDetectsVoidRemovalNoOpBeforeAdding() {
        let oldIdentifiers = (0..<60).map { _ in NotificationManager.expiryIdentifier(for: UUID()) }

        let stillPending = NotificationManager.identifiersStillPending(
            expectedRemovedIdentifiers: Set(oldIdentifiers),
            pendingIdentifiers: oldIdentifiers + ["analytics.keep"]
        )
        let confirmedRemoved = NotificationManager.identifiersStillPending(
            expectedRemovedIdentifiers: Set(oldIdentifiers),
            pendingIdentifiers: ["analytics.keep"]
        )

        XCTAssertEqual(Set(stillPending), Set(oldIdentifiers))
        XCTAssertTrue(confirmedRemoved.isEmpty)
    }

    func testFinalStaleVerificationFindsManagedStaleAndIgnoresUnrelated() {
        let desired = NotificationManager.expiryIdentifier(for: UUID())
        let staleLegacy = UUID().uuidString + ".advance"
        let staleStrict = NotificationManager.advanceIdentifier(for: UUID())

        let remainingStale = NotificationManager.staleManagedIdentifiers(
            pendingIdentifiers: [desired, staleLegacy, staleStrict, "analytics.keep"],
            desiredIdentifiers: [desired]
        )

        XCTAssertEqual(Set(remainingStale), [staleLegacy, staleStrict])
        XCTAssertFalse(remainingStale.contains("analytics.keep"))
    }

    // MARK: - Notification-center timeout gate

    func testOneShotGateCanOnlyBeClaimedOnce() {
        let gate = NotificationOneShotGate()

        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    func testAwaitOneShotUsesFirstCallbackAndIgnoresDuplicateCompletion() async {
        let result = await NotificationManager.awaitOneShot(
            timeout: 1,
            timeoutValue: "timeout"
        ) { finish in
            finish("callback")
            finish("duplicate")
        }

        XCTAssertEqual(result, "callback")
    }

    func testAwaitOneShotTimesOutAndIgnoresLateCallback() async throws {
        let result = await NotificationManager.awaitOneShot(
            timeout: 0.005,
            timeoutValue: "timeout"
        ) { finish in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.02) {
                finish("late callback")
            }
        }

        XCTAssertEqual(result, "timeout")
        // Keep the test alive until the late callback runs. A missing one-shot gate would trigger
        // a checked-continuation double-resume failure here.
        try await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - Observable status

    func testSchedulingSuccessPersistsCountsAndClearsOldError() {
        defaults.set("旧错误", forKey: NotificationManager.lastSchedulingErrorKey)
        let summary = NotificationSchedulingSummary(desiredCount: 84, scheduledCount: 60, overflowCount: 24, failedCount: 0)

        NotificationManager.recordSchedulingSuccess(summary, defaults: defaults, now: Date(timeIntervalSince1970: 1234))

        XCTAssertEqual(defaults.integer(forKey: NotificationManager.desiredCountKey), 84)
        XCTAssertEqual(defaults.integer(forKey: NotificationManager.scheduledCountKey), 60)
        XCTAssertEqual(defaults.integer(forKey: NotificationManager.overflowCountKey), 24)
        XCTAssertEqual(defaults.double(forKey: NotificationManager.lastSchedulingTimestampKey), 1234)
        XCTAssertNil(defaults.object(forKey: NotificationManager.lastSchedulingErrorKey))
    }

    func testSchedulingFailureIsVisibleAndStatusTextPrefersIt() {
        let summary = NotificationSchedulingSummary(desiredCount: 2, scheduledCount: 1, overflowCount: 0, failedCount: 1)
        NotificationManager.recordSchedulingFailure("调度失败", summary: summary, defaults: defaults)

        let error = defaults.string(forKey: NotificationManager.lastSchedulingErrorKey) ?? ""
        XCTAssertEqual(error, "调度失败")
        XCTAssertEqual(
            NotificationManager.schedulingStatusText(desired: 2, scheduled: 1, overflow: 0, error: error),
            "调度失败"
        )
    }

    func testSchedulingStatusReportsOverflow() {
        XCTAssertEqual(
            NotificationManager.schedulingStatusText(desired: 84, scheduled: 60, overflow: 24, error: ""),
            "已安排 60 / 共 84，另有 24 条等待重排"
        )
    }
}
