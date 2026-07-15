import XCTest
import SwiftUI
@testable import FridgeTracker

/// Regression baseline for the pure helpers and the `ExpiringFoodSnapshot` value type in
/// `FridgeTracker/Utilities/ExpiringFoodSnapshot.swift`.
///
/// No SwiftData / `@Model` types are involved, so this case needs neither `TestModelContainer`
/// nor `@MainActor`. Expected strings, colors, and thresholds are taken verbatim from the source.
final class ExpiringFoodSnapshotTests: XCTestCase {

    // MARK: - expiryStatusText(daysUntilExpiry:)

    func testExpiryStatusTextNegativeReportsExpiredWithAbsoluteDays() {
        // days < 0 -> "已过期 \(-days) 天"
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: -1), "已过期 1 天")
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: -5), "已过期 5 天")
    }

    func testExpiryStatusTextZeroReportsToday() {
        // days == 0 -> "今天过期"
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: 0), "今天过期")
    }

    func testExpiryStatusTextPositiveReportsDaysRemaining() {
        // days > 0 -> "\(days) 天后过期"
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: 1), "1 天后过期")
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: 3), "3 天后过期")
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: 30), "30 天后过期")
    }

    // MARK: - expiryStatusColor(daysUntilExpiry:)

    func testExpiryStatusColorNegativeIsRed() {
        // days < 0 -> .red
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: -1), Color.red)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: -10), Color.red)
    }

    func testExpiryStatusColorWithinSoonThresholdIsOrange() {
        // 0 <= days <= 3 -> .orange  (zero is orange, not red)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: 0), Color.orange)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: 1), Color.orange)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: 3), Color.orange)
    }

    func testExpiryStatusColorBeyondThresholdIsGreen() {
        // days > 3 -> .green  (4 is the first green day)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: 4), Color.green)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: 100), Color.green)
    }

    // MARK: - Codable round-trip via JSONEncoder/JSONDecoder.expiringFoods

    func testCodableRoundTripPreservesAllFields() throws {
        let original = ExpiringFoodSnapshot(
            id: UUID(),
            name: "牛奶",
            category: "乳制品",
            categoryIcon: "🥛",
            displayIcon: "🥛",
            storageZone: "冷藏",
            storageIcon: "❄️",
            // .iso8601 strategy has whole-second resolution, so use a sub-second-free date.
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            daysUntilExpiry: 2,
            categoryID: .dairy,
            expiryDayKey: LocalDate(iso8601DateString: "2023-11-15")
        )

        let data = try JSONEncoder.expiringFoods.encode(original)
        let decoded = try JSONDecoder.expiringFoods.decode(ExpiringFoodSnapshot.self, from: data)

        // Hashable/Equatable round-trip equality (covers every stored property).
        XCTAssertEqual(decoded, original)

        // Spot-check fields explicitly to localize any future regression.
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, "牛奶")
        XCTAssertEqual(decoded.category, "乳制品")
        XCTAssertEqual(decoded.categoryIcon, "🥛")
        XCTAssertEqual(decoded.displayIcon, "🥛")
        XCTAssertEqual(decoded.storageZone, "冷藏")
        XCTAssertEqual(decoded.storageIcon, "❄️")
        XCTAssertEqual(decoded.expiryDate, original.expiryDate)
        XCTAssertEqual(decoded.daysUntilExpiry, 2)
        XCTAssertEqual(decoded.categoryID, .dairy)
        XCTAssertEqual(decoded.expiryDayKey?.iso8601DateString, "2023-11-15")
    }

    func testEncoderUsesISO8601DateStrategy() throws {
        // The stored `expiryDate` must serialize as an ISO-8601 string (the contract both
        // encoder and decoder rely on). Confirm the encoded payload contains an ISO-8601 form.
        let snapshot = ExpiringFoodSnapshot(
            id: UUID(),
            name: "鸡蛋",
            category: "蛋类",
            categoryIcon: "🥚",
            displayIcon: "🥚",
            storageZone: "冷藏",
            storageIcon: "❄️",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            daysUntilExpiry: 0
        )

        let data = try JSONEncoder.expiringFoods.encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // ISO8601DateFormatter renders 1_700_000_000 as "2023-11-14T22:13:20Z".
        XCTAssertTrue(json.contains("2023-11-14T22:13:20Z"),
                      "expiryDate should be encoded as an ISO-8601 string, got: \(json)")
    }

    // MARK: - currentDaysUntilExpiry (clock-relative)

    func testCurrentDaysUntilExpiryForFutureDateMatchesCalendarDayDiff() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let future = try XCTUnwrap(calendar.date(byAdding: .day, value: 5, to: today))

        let snapshot = makeSnapshot(expiryDate: future, daysUntilExpiry: 999)

        // Computed live from the clock; the stale stored `daysUntilExpiry` (999) is ignored.
        XCTAssertEqual(snapshot.currentDaysUntilExpiry, 5)
    }

    func testCurrentDaysUntilExpiryForTodayIsZero() throws {
        let snapshot = makeSnapshot(expiryDate: Date(), daysUntilExpiry: 42)
        XCTAssertEqual(snapshot.currentDaysUntilExpiry, 0)
    }

    func testCurrentDaysUntilExpiryForPastDateIsNegative() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let past = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))

        let snapshot = makeSnapshot(expiryDate: past, daysUntilExpiry: 0)
        XCTAssertEqual(snapshot.currentDaysUntilExpiry, -3)
    }

    // MARK: - expiryText (derived from currentDaysUntilExpiry)

    func testExpiryTextUsesLiveDayCountForFutureDate() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let future = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: today))

        let snapshot = makeSnapshot(expiryDate: future, daysUntilExpiry: 999)
        XCTAssertEqual(snapshot.expiryText, "2 天后过期")
    }

    func testExpiryTextForTodayIsToday() throws {
        let snapshot = makeSnapshot(expiryDate: Date(), daysUntilExpiry: 999)
        XCTAssertEqual(snapshot.expiryText, "今天过期")
    }

    func testExpiryTextForPastDateReportsExpired() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let past = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))

        let snapshot = makeSnapshot(expiryDate: past, daysUntilExpiry: 999)
        XCTAssertEqual(snapshot.expiryText, "已过期 2 天")
    }

    // MARK: - v2 snapshot filtering contract

    func testLegacyArrayWithoutCategoryIDStillDecodesAndResolvesChineseCategory() throws {
        let legacyJSON = """
        [{"id":"12345678-1234-1234-1234-123456789012","name":"核桃","category":"坚果","categoryIcon":"🥜","displayIcon":"🥜","storageZone":"常温","storageIcon":"🏠","expiryDate":"2026-07-14T00:00:00Z","daysUntilExpiry":3}]
        """
        let decoded = try decodeExpiringFoodSnapshots(from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].categoryID)
        XCTAssertEqual(decoded[0].resolvedCategoryID, .nut)
    }

    func testEnvelopeRoundTripUsesVersionAndStableNutCategoryID() throws {
        let item = makeSnapshot(expiryDate: .now, daysUntilExpiry: 0, category: "坚果", categoryID: .nut)
        let data = try JSONEncoder.expiringFoods.encode(ExpiringFoodSnapshotEnvelope(items: [item]))
        let envelope = try JSONDecoder.expiringFoods.decode(ExpiringFoodSnapshotEnvelope.self, from: data)

        XCTAssertEqual(envelope.version, ExpiringFoodSnapshotEnvelope.currentVersion)
        XCTAssertEqual(try decodeExpiringFoodSnapshots(from: data).first?.resolvedCategoryID, .nut)
    }

    func testAsyncSnapshotReaderUsesSameTenMiBLimitAsWriter() {
        XCTAssertEqual(expiringFoodsSnapshotMaximumByteCount, 10 * 1_024 * 1_024)
        XCTAssertEqual(expiringFoodsSnapshotMaximumByteCount, WidgetDataStore.maximumSnapshotSize)
    }

    func testAsyncSnapshotReaderReturnsFallbackForOversizedOtherwiseValidPayload() async throws {
        let item = makeSnapshot(expiryDate: .now, daysUntilExpiry: 0)
        var data = try JSONEncoder.expiringFoods.encode(ExpiringFoodSnapshotEnvelope(items: [item]))
        data.append(Data(repeating: 0x20, count: 32)) // JSON trailing whitespace remains valid.
        XCTAssertEqual(try decodeExpiringFoodSnapshots(from: data).count, 1)

        let url = temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        XCTAssertNil(try readBoundedExpiringFoodSnapshotData(
            from: url,
            maximumByteCount: data.count - 1
        ))
        XCTAssertNil(try readBoundedExpiringFoodSnapshotData(
            from: url,
            maximumByteCount: .max
        ))
        let result = await loadFilteredExpiringFoodSnapshots(
            from: url,
            categoryID: nil,
            relativeTo: .now,
            maximumByteCount: data.count - 1
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testAsyncSnapshotReaderReturnsFallbackForCorruptPayload() async throws {
        let url = temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not-json".utf8).write(to: url)

        let result = await loadFilteredExpiringFoodSnapshots(
            from: url,
            categoryID: nil,
            relativeTo: .now
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testAsyncSnapshotReaderKeepsLegacyArrayCompatibility() async throws {
        let legacyJSON = """
        [{"id":"12345678-1234-1234-1234-123456789012","name":"核桃","category":"坚果","categoryIcon":"🥜","displayIcon":"🥜","storageZone":"常温","storageIcon":"🏠","expiryDate":"2026-07-14T00:00:00Z","daysUntilExpiry":3}]
        """
        let url = temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(legacyJSON.utf8).write(to: url)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 14)))

        let result = await loadFilteredExpiringFoodSnapshots(
            from: url,
            categoryID: .nut,
            relativeTo: now,
            calendar: calendar
        )

        XCTAssertEqual(result.map(\.name), ["核桃"])
    }

    func testAsyncSnapshotReaderDecodesV2ThenFiltersAndSorts() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 14)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))
        let laterNut = makeSnapshot(
            expiryDate: tomorrow,
            daysUntilExpiry: 1,
            name: "腰果",
            category: "坚果",
            categoryID: .nut
        )
        let firstNut = makeSnapshot(
            expiryDate: now,
            daysUntilExpiry: 0,
            name: "核桃",
            category: "坚果",
            categoryID: .nut
        )
        let other = makeSnapshot(
            expiryDate: now,
            daysUntilExpiry: 0,
            name: "牛奶",
            category: "乳制品",
            categoryID: .dairy
        )
        let data = try JSONEncoder.expiringFoods.encode(
            ExpiringFoodSnapshotEnvelope(items: [laterNut, other, firstNut])
        )
        let url = temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let result = await loadFilteredExpiringFoodSnapshots(
            from: url,
            categoryID: .nut,
            relativeTo: now,
            calendar: calendar
        )

        XCTAssertEqual(result.map(\.id), [firstNut.id, laterNut.id])
    }

    func testAsyncSnapshotReaderHonorsPreexistingCancellation() async throws {
        let item = makeSnapshot(expiryDate: .now, daysUntilExpiry: 0)
        let data = try JSONEncoder.expiringFoods.encode(ExpiringFoodSnapshotEnvelope(items: [item]))
        let url = temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await loadFilteredExpiringFoodSnapshots(
                from: url,
                categoryID: nil,
                relativeTo: .now
            )
        }.value

        XCTAssertTrue(result.isEmpty)
    }

    func testFutureInventoryBeyondThirtyDaysIsVisibleImmediately() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 14)))
        let expiry = try XCTUnwrap(calendar.date(byAdding: .day, value: 180, to: today))
        let nut = makeSnapshot(
            expiryDate: expiry,
            daysUntilExpiry: 180,
            name: "核桃",
            category: "坚果",
            categoryID: .nut
        )

        XCTAssertEqual(
            filteredExpiringFoodSnapshots(
                [nut],
                categoryID: .nut,
                relativeTo: today,
                calendar: calendar
            ).map(\.id),
            [nut.id]
        )
    }

    func testCategoryFilteringHappensBeforeFiftyItemLimit() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 14)))
        let dairy = (0..<50).map { index in
            makeSnapshot(expiryDate: now, daysUntilExpiry: 0, name: "乳制品\(index)", category: "乳制品", categoryID: .dairy)
        }
        let nut = makeSnapshot(expiryDate: now, daysUntilExpiry: 0, name: "核桃", category: "坚果", categoryID: .nut)

        let result = filteredExpiringFoodSnapshots(dairy + [nut], categoryID: .nut, relativeTo: now, calendar: calendar)

        XCTAssertEqual(result.map(\.id), [nut.id])
    }

    func testOldExpiredItemsFallOutOfWindowAtWidgetTimelineTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 14)))
        let oldExpiry = try XCTUnwrap(calendar.date(byAdding: .day, value: -15, to: today))
        let item = makeSnapshot(expiryDate: oldExpiry, daysUntilExpiry: -1)

        XCTAssertTrue(filteredExpiringFoodSnapshots([item], categoryID: nil, relativeTo: today, calendar: calendar).isEmpty)
    }

    func testWidgetRefreshContractUsesStableKindAndFifteenMinuteFallback() {
        XCTAssertEqual(fridgeTrackerWidgetKind, "FridgeTrackerWidget")
        XCTAssertEqual(fridgeTrackerWidgetRefreshInterval, 15 * 60)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            nextFridgeTrackerWidgetRefreshDate(after: now),
            now.addingTimeInterval(15 * 60)
        )
        XCTAssertEqual(
            nextFridgeTrackerWidgetRefreshDate(after: now, interval: 0),
            now.addingTimeInterval(60)
        )
    }

    func testAppGroupCandidatesPreserveCanonicalInstall() {
        XCTAssertEqual(
            FridgeTrackerAppGroup.candidateIdentifiers(bundleIdentifier: fridgeTrackerAppBundleIdentifier),
            [fridgeTrackerAppGroupIdentifier]
        )
        XCTAssertEqual(
            FridgeTrackerAppGroup.candidateIdentifiers(bundleIdentifier: fridgeTrackerWidgetBundleIdentifier),
            [fridgeTrackerAppGroupIdentifier]
        )
    }

    func testAppGroupCandidatesSupportResignedAppAndWidgetIdentifiers() {
        let expected = [
            fridgeTrackerAppGroupIdentifier,
            "\(fridgeTrackerAppGroupIdentifier).4ABD62UF7K"
        ]
        XCTAssertEqual(
            FridgeTrackerAppGroup.candidateIdentifiers(
                bundleIdentifier: "\(fridgeTrackerAppBundleIdentifier).4ABD62UF7K"
            ),
            expected
        )
        XCTAssertEqual(
            FridgeTrackerAppGroup.candidateIdentifiers(
                bundleIdentifier: "\(fridgeTrackerWidgetBundleIdentifier).4ABD62UF7K"
            ),
            expected
        )
        XCTAssertEqual(
            FridgeTrackerAppGroup.candidateIdentifiers(
                bundleIdentifier: "\(fridgeTrackerAppBundleIdentifier).4ABD62UF7K.FridgeTrackerWidget"
            ),
            expected
        )
    }

    func testAppGroupCandidatesRejectUnrelatedOrUnsafeRewrites() {
        XCTAssertEqual(
            FridgeTrackerAppGroup.candidateIdentifiers(bundleIdentifier: "com.example.FridgeTracker.BAD"),
            [fridgeTrackerAppGroupIdentifier]
        )
        XCTAssertEqual(
            FridgeTrackerAppGroup.candidateIdentifiers(
                bundleIdentifier: "\(fridgeTrackerAppBundleIdentifier).BAD.SUFFIX"
            ),
            [fridgeTrackerAppGroupIdentifier]
        )
        XCTAssertEqual(
            FridgeTrackerAppGroup.candidateIdentifiers(bundleIdentifier: nil),
            [fridgeTrackerAppGroupIdentifier]
        )
    }

    func testAppGroupResolutionFallsBackToResignedContainer() {
        let rewritten = "\(fridgeTrackerAppGroupIdentifier).4ABD62UF7K"
        let expectedURL = URL(fileURLWithPath: "/tmp/resigned-app-group", isDirectory: true)
        var attempted: [String] = []

        let resolved = FridgeTrackerAppGroup.resolveContainerURL(
            bundleIdentifier: "\(fridgeTrackerAppBundleIdentifier).4ABD62UF7K"
        ) { identifier in
            attempted.append(identifier)
            return identifier == rewritten ? expectedURL : nil
        }

        XCTAssertEqual(attempted, [fridgeTrackerAppGroupIdentifier, rewritten])
        XCTAssertEqual(resolved, expectedURL)
    }

    func testAppGroupResolutionPrefersCanonicalContainer() {
        let expectedURL = URL(fileURLWithPath: "/tmp/canonical-app-group", isDirectory: true)
        var attempted: [String] = []

        let resolved = FridgeTrackerAppGroup.resolveContainerURL(
            bundleIdentifier: "\(fridgeTrackerAppBundleIdentifier).4ABD62UF7K"
        ) { identifier in
            attempted.append(identifier)
            return identifier == fridgeTrackerAppGroupIdentifier ? expectedURL : nil
        }

        XCTAssertEqual(attempted, [fridgeTrackerAppGroupIdentifier])
        XCTAssertEqual(resolved, expectedURL)
    }

    func testLocalDateIsStrictGregorianAndCodableAsYYYYMMDD() throws {
        XCTAssertNil(LocalDate(year: 2026, month: 2, day: 30))
        let leapDay = try XCTUnwrap(LocalDate(year: 2028, month: 2, day: 29))
        XCTAssertEqual(leapDay.adding(days: 1)?.iso8601DateString, "2028-03-01")
        XCTAssertEqual(leapDay.days(until: try XCTUnwrap(LocalDate(iso8601DateString: "2028-03-02"))), 2)

        let data = try JSONEncoder().encode(leapDay)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"2028-02-29\"")
        XCTAssertEqual(try JSONDecoder().decode(LocalDate.self, from: data), leapDay)
    }

    func testLocalDateExtractionUsesExplicitTimezoneButCivilDateDoesNotShiftAfterward() throws {
        let instant = Date(timeIntervalSince1970: 1_752_448_800) // 2025-07-13 23:20:00Z
        let shanghaiTimeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let losAngelesTimeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let shanghai = LocalDate(date: instant, timeZone: shanghaiTimeZone)
        let losAngeles = LocalDate(date: instant, timeZone: losAngelesTimeZone)

        XCTAssertEqual(shanghai.iso8601DateString, "2025-07-14")
        XCTAssertEqual(losAngeles.iso8601DateString, "2025-07-13")
        let shanghaiNineAMInLA = try XCTUnwrap(shanghai.date(in: losAngelesTimeZone, hour: 9))
        XCTAssertEqual(LocalDate(date: shanghaiNineAMInLA, timeZone: losAngelesTimeZone), shanghai)
    }

    func testLocalDateRoundTripsAcrossDSTAndExtremeTimezones() throws {
        let civilDates = [
            try XCTUnwrap(LocalDate(iso8601DateString: "2026-03-08")),  // US DST start
            try XCTUnwrap(LocalDate(iso8601DateString: "2026-11-01")), // US DST end
            try XCTUnwrap(LocalDate(iso8601DateString: "2028-02-29"))
        ]
        let timeZones = try [
            "Pacific/Kiritimati",    // UTC+14
            "America/Los_Angeles",
            "Asia/Shanghai",
            "Pacific/Pago_Pago"     // UTC-11
        ].map { try XCTUnwrap(TimeZone(identifier: $0)) }

        for civilDate in civilDates {
            let encoded = try JSONEncoder().encode(civilDate)
            XCTAssertEqual(try JSONDecoder().decode(LocalDate.self, from: encoded), civilDate)

            for timeZone in timeZones {
                let localNoon = try XCTUnwrap(civilDate.date(in: timeZone, hour: 12))
                XCTAssertEqual(
                    LocalDate(date: localNoon, timeZone: timeZone),
                    civilDate,
                    "civil date shifted in \(timeZone.identifier)"
                )
            }
        }
    }

    // MARK: - Helpers

    private func temporarySnapshotURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FridgeTrackerSnapshotReader-\(UUID().uuidString).json")
    }

    private func makeSnapshot(
        expiryDate: Date,
        daysUntilExpiry: Int,
        name: String = "测试",
        category: String = "其他",
        categoryID: FoodCategoryID? = nil
    ) -> ExpiringFoodSnapshot {
        ExpiringFoodSnapshot(
            id: UUID(),
            name: name,
            category: category,
            categoryIcon: categoryID == .nut ? "🥜" : "📦",
            displayIcon: categoryID == .nut ? "🥜" : "📦",
            storageZone: "冷藏",
            storageIcon: "❄️",
            expiryDate: expiryDate,
            daysUntilExpiry: daysUntilExpiry,
            categoryID: categoryID,
            expiryDayKey: nil
        )
    }
}
