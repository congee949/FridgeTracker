import XCTest
import SwiftData
@testable import FridgeTracker

/// Regression coverage for backup export/import (`FoodBackup.swift`).
///
/// Guards the high-severity bug where the document encoded dates as ISO-8601 but decoded with a
/// default `JSONDecoder()` that expects `Double`, so every exported file failed to re-import.
@MainActor
final class FoodBackupTests: XCTestCase {

    private let expiry = Date(timeIntervalSince1970: 1_750_000_000)
    private let created = Date(timeIntervalSince1970: 1_740_000_000)
    private var validSettings: FoodBackupSettings {
        FoodBackupSettings(
            notificationsEnabled: true,
            reminderDaysBefore: -1,
            historyRetentionDays: -1,
            historySuggestionOverrides: nil
        )
    }

    private func sampleBackup(
        version: Int? = 2,
        category: FoodCategory = .dairy,
        settings: FoodBackupSettings? = nil
    ) -> FoodBackup {
        let item = FoodItem(
            name: category == .nut ? "核桃" : "牛奶", category: category, storageZone: .fridge, customIcon: "🥛",
            purchaseDate: nil, expiryDate: expiry, quantity: "2/6瓶", notes: "原味"
        )
        item.createdAt = created
        let record = FoodDispositionRecord(
            uuid: UUID(), foodName: "鸡蛋", category: .egg, storageZone: .fridge, customIcon: nil,
            quantity: nil, purchaseDate: nil, expiryDate: expiry, shelfLifeDaysEstimate: 10,
            action: .consumed, createdAt: created
        )
        let replenishment = ReplenishmentItem(
            uuid: UUID(), name: "面包", category: .baking, storageZone: .pantry, customIcon: nil,
            quantity: "1袋", notes: nil, defaultShelfLifeDays: 5, createdAt: created, completedAt: nil
        )
        return FoodBackup(
            version: version,
            items: [FoodBackupItem(item)],
            dispositionRecords: [DispositionBackupItem(record)],
            replenishmentItems: [ReplenishmentBackupItem(replenishment)],
            settings: settings
        )
    }

    private func assertValidationError(
        _ expected: FoodBackupValidationError,
        from data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try FoodBackupDocument.decode(from: data), file: file, line: line) { error in
            XCTAssertEqual(error as? FoodBackupValidationError, expected, file: file, line: line)
        }
    }

    private func assertValidationError<T>(
        _ expected: FoodBackupValidationError,
        performing operation: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? FoodBackupValidationError, expected, file: file, line: line)
        }
    }

    // MARK: - Round trip (the bug guard)

    func testRoundTripPreservesDatesAndFields() throws {
        let data = try FoodBackupDocument.encode(sampleBackup())
        // Pre-fix this line threw DecodingError.typeMismatch on the first Date field.
        let decoded = try FoodBackupDocument.decode(from: data)

        let item = try XCTUnwrap(decoded.items.first)
        XCTAssertEqual(item.name, "牛奶")
        XCTAssertEqual(item.category, .dairy)
        XCTAssertEqual(item.storageZone, .fridge)
        XCTAssertEqual(item.quantity, "2/6瓶")
        XCTAssertEqual(item.expiryDate.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(item.createdAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(decoded.dispositionRecords?.count, 1)
        XCTAssertEqual(decoded.replenishmentItems?.count, 1)
        XCTAssertEqual(decoded.dispositionRecords?.first?.action, .consumed)
    }

    func testV3RoundTripPreservesSettingsStableNutIDAndCivilDates() throws {
        let override = HistorySuggestionOverride(
            name: "核桃",
            category: .nut,
            storageZone: .pantry,
            customIcon: "🥜",
            defaultShelfLifeDays: 180,
            isHidden: false
        )
        let overrideData = try JSONEncoder().encode(["核桃": override])
        let settings = FoodBackupSettings(
            notificationsEnabled: false,
            reminderDaysBefore: 3,
            historyRetentionDays: 180,
            historySuggestionOverrides: overrideData
        )
        let backup = sampleBackup(version: 3, category: .nut, settings: settings)

        let decoded = try FoodBackupDocument.decode(from: FoodBackupDocument.encode(backup))
        let backupItem = try XCTUnwrap(decoded.items.first)
        let restored = backupItem.foodItem

        XCTAssertEqual(decoded.effectiveVersion, 3)
        XCTAssertEqual(decoded.settings, settings)
        XCTAssertEqual(backupItem.categoryID, .nut)
        XCTAssertEqual(restored.category, .nut)
        XCTAssertEqual(restored.stableCategoryID, .nut)
        XCTAssertEqual(restored.expiryLocalDate, backupItem.expiryDayKey)
        XCTAssertEqual(decoded.dispositionRecords?.first?.categoryID, .egg)
        XCTAssertEqual(decoded.replenishmentItems?.first?.categoryID, .baking)
    }

    func testEncoderWritesISO8601DateStrings() throws {
        let data = try FoodBackupDocument.encode(sampleBackup())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // ISO-8601 dates render as "…T…Z" strings, never bare numeric seconds.
        XCTAssertTrue(json.contains("T") && json.contains("Z"), "dates should serialize as ISO-8601 strings")
    }

    func testSharedFoodTextConstraintAcceptsBoundaryThatBackupCanExport() throws {
        let boundaryName = String(repeating: "坚", count: FoodTextConstraints.nameMaximum)
        try FoodTextConstraints.validateFoodInput(
            name: boundaryName,
            quantity: String(repeating: "1", count: FoodTextConstraints.quantityMaximum),
            notes: String(repeating: "好", count: FoodTextConstraints.notesMaximum),
            customIcon: "🥜"
        )

        let item = FoodItem(
            name: boundaryName,
            category: .nut,
            storageZone: .pantry,
            expiryDate: Date().addingTimeInterval(86_400)
        )
        XCTAssertNoThrow(try FoodBackupDocument.encode(FoodBackup(
            version: 3,
            items: [FoodBackupItem(item)],
            dispositionRecords: [],
            replenishmentItems: [],
            settings: FoodBackupSettings(
                notificationsEnabled: true,
                reminderDaysBefore: -1,
                historyRetentionDays: -1,
                historySuggestionOverrides: nil
            )
        )))
    }

    func testSharedFoodTextConstraintRejectsOverlongAndInvisibleNames() {
        XCTAssertThrowsError(try FoodTextConstraints.validateFoodInput(
            name: String(repeating: "坚", count: FoodTextConstraints.nameMaximum + 1),
            quantity: nil,
            notes: nil,
            customIcon: nil
        )) { error in
            XCTAssertEqual(
                error as? FoodInputValidationError,
                .tooLong(field: "食材名称", maximum: FoodTextConstraints.nameMaximum)
            )
        }

        XCTAssertThrowsError(try FoodTextConstraints.validateFoodInput(
            name: "\u{2060}",
            quantity: nil,
            notes: nil,
            customIcon: nil
        )) { error in
            XCTAssertEqual(error as? FoodInputValidationError, .empty(field: "食材名称"))
        }

        XCTAssertThrowsError(try FoodTextConstraints.validateFoodInput(
            name: "核\u{0000}桃",
            quantity: nil,
            notes: nil,
            customIcon: nil
        )) { error in
            XCTAssertEqual(error as? FoodInputValidationError, .invalidCharacters(field: "食材名称"))
        }
    }

    // MARK: - Backwards compatibility / mapping

    func testV1BackupDecodesAndRecomputesShelfLife() throws {
        // v1: no version / uuid / originalShelfLifeDays. createdAt -> expiry spans 30 days.
        let json = """
        {"items":[{"name":"酸奶","category":"乳制品","storageZone":"冷藏",\
        "expiryDate":"2025-01-31T12:00:00Z","createdAt":"2025-01-01T12:00:00Z"}]}
        """
        let decoded = try FoodBackupDocument.decode(from: Data(json.utf8))
        let backupItem = try XCTUnwrap(decoded.items.first)
        XCTAssertNil(decoded.version)
        XCTAssertNil(backupItem.uuid)
        XCTAssertNil(backupItem.originalShelfLifeDays)

        // The `foodItem` getter recomputes originalShelfLifeDays from the real createdAt->expiry span.
        let model = backupItem.foodItem
        let shelfLife = try XCTUnwrap(model.originalShelfLifeDays)
        XCTAssertTrue((29...31).contains(shelfLife), "expected ~30 days, got \(shelfLife)")
    }

    func testDecodesChineseEnumRawValues() throws {
        let json = """
        {"version":2,"items":[{"name":"牛肉","category":"肉类","storageZone":"冷冻",\
        "expiryDate":"2025-06-01T12:00:00Z","createdAt":"2025-05-01T12:00:00Z"}],\
        "dispositionRecords":[],"replenishmentItems":[]}
        """
        let decoded = try FoodBackupDocument.decode(from: Data(json.utf8))
        let item = try XCTUnwrap(decoded.items.first)
        XCTAssertEqual(item.category, .meat)       // 肉类
        XCTAssertEqual(item.storageZone, .freezer) // 冷冻
    }

    func testV3StableNutCategoryIDWinsOverLegacyDisplayField() throws {
        let json = """
        {"version":3,"items":[{"uuid":"76C67B7A-F4C9-4D4C-9D35-73B7D64DA80E",\
        "name":"腰果","category":"其他","categoryID":"nut",\
        "storageZone":"常温","expiryDate":"2026-08-01T12:00:00Z",\
        "expiryDayKey":"2026-08-01","createdAt":"2026-07-01T12:00:00Z",\
        "updatedAt":"2026-07-01T12:00:00Z","originalShelfLifeDays":31}],\
        "dispositionRecords":[],"replenishmentItems":[],\
        "settings":{"notificationsEnabled":true,"reminderDaysBefore":-1,"historyRetentionDays":-1}}
        """

        let decoded = try FoodBackupDocument.decode(from: Data(json.utf8))
        let item = try XCTUnwrap(decoded.items.first)

        XCTAssertEqual(item.category, .other, "legacy display field remains decodable for one compatibility cycle")
        XCTAssertEqual(item.categoryID, .nut)
        XCTAssertEqual(item.foodItem.category, .nut, "stable category ID is authoritative during restore")
        XCTAssertEqual(item.foodItem.stableCategoryID, .nut)
    }

    func testV3CivilDateKeysSurviveConflictingTimestampTimezones() throws {
        let json = """
        {"version":3,"items":[{"uuid":"6C84C24E-5395-437D-AE59-12D318DD2D0C",\
        "name":"杏仁","category":"坚果","categoryID":"nut",\
        "storageZone":"常温","purchaseDate":"2026-03-07T16:30:00Z",\
        "expiryDate":"2026-03-08T16:30:00Z","purchaseDayKey":"2026-03-08",\
        "expiryDayKey":"2026-03-09","createdAt":"2026-03-07T00:00:00Z",\
        "updatedAt":"2026-03-07T00:00:00Z"}],\
        "dispositionRecords":[],"replenishmentItems":[],\
        "settings":{"notificationsEnabled":true,"reminderDaysBefore":-1,"historyRetentionDays":-1}}
        """

        let decoded = try FoodBackupDocument.decode(from: Data(json.utf8))
        let item = try XCTUnwrap(decoded.items.first)
        let restored = item.foodItem

        XCTAssertEqual(item.purchaseDayKey?.iso8601DateString, "2026-03-08")
        XCTAssertEqual(item.expiryDayKey?.iso8601DateString, "2026-03-09")
        XCTAssertEqual(restored.purchaseLocalDate?.iso8601DateString, "2026-03-08")
        XCTAssertEqual(restored.expiryLocalDate.iso8601DateString, "2026-03-09")
    }

    // MARK: - Adversarial validation

    func testRejectsOversizedFileBeforeJSONDecoding() {
        let data = Data(repeating: 0x20, count: FoodBackup.maximumFileSize + 1)
        assertValidationError(.fileTooLarge(actualBytes: data.count), from: data)
    }

    func testVersionedBackupRequiresItsCompleteShape() {
        let v2 = Data("{\"version\":2,\"items\":[]}".utf8)
        assertValidationError(.missingRequiredField("dispositionRecords"), from: v2)

        let v3 = Data("{\"version\":3,\"items\":[],\"dispositionRecords\":[],\"replenishmentItems\":[]}".utf8)
        assertValidationError(.missingRequiredField("settings"), from: v3)

        XCTAssertNoThrow(try FoodBackupDocument.decode(from: Data("{\"items\":[]}".utf8)))
    }

    func testV3RequiresStableIdentityCategoryAndCivilDateFields() {
        let missingUUID = Data("""
        {"version":3,"items":[{"name":"核桃","category":"坚果","categoryID":"nut",\
        "storageZone":"常温","expiryDate":"2026-08-01T00:00:00Z",\
        "expiryDayKey":"2026-08-01","createdAt":"2026-07-01T00:00:00Z",\
        "updatedAt":"2026-07-01T00:00:00Z","originalShelfLifeDays":31}],\
        "dispositionRecords":[],"replenishmentItems":[],\
        "settings":{"notificationsEnabled":true,"reminderDaysBefore":-1,"historyRetentionDays":-1}}
        """.utf8)
        assertValidationError(.missingRequiredField("items[0].uuid"), from: missingUUID)

        let missingExpiryDay = Data("""
        {"version":3,"items":[{"uuid":"1D545246-0038-4269-8C15-63C2EF2A7D9A",\
        "name":"核桃","category":"坚果","categoryID":"nut","storageZone":"常温",\
        "expiryDate":"2026-08-01T00:00:00Z","createdAt":"2026-07-01T00:00:00Z",\
        "updatedAt":"2026-07-01T00:00:00Z","originalShelfLifeDays":31}],\
        "dispositionRecords":[],"replenishmentItems":[],\
        "settings":{"notificationsEnabled":true,"reminderDaysBefore":-1,"historyRetentionDays":-1}}
        """.utf8)
        assertValidationError(.missingRequiredField("items[0].expiryDayKey"), from: missingExpiryDay)

        let missingRecordCategory = Data("""
        {"version":3,"items":[],"dispositionRecords":[{\
        "uuid":"B505650D-62F0-4210-B9E7-7C03E9FB95C8","foodName":"牛奶",\
        "category":"乳制品","storageZone":"冷藏","expiryDate":"2026-07-20T00:00:00Z",\
        "expiryDayKey":"2026-07-20","shelfLifeDaysEstimate":7,"action":"consumed",\
        "createdAt":"2026-07-13T00:00:00Z","updatedAt":"2026-07-13T00:00:00Z"}],\
        "replenishmentItems":[],\
        "settings":{"notificationsEnabled":true,"reminderDaysBefore":-1,"historyRetentionDays":-1}}
        """.utf8)
        assertValidationError(
            .missingRequiredField("dispositionRecords[0].categoryID"),
            from: missingRecordCategory
        )
    }

    func testV3RejectsRequiredNamesWithoutVisibleContent() {
        let blankName = Data("""
        {"version":3,"items":[{"uuid":"0E342754-428F-4288-A8F0-63BC34D5243B",\
        "name":" \\t ","category":"坚果","categoryID":"nut","storageZone":"常温",\
        "expiryDate":"2026-08-01T00:00:00Z","expiryDayKey":"2026-08-01",\
        "createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z",\
        "originalShelfLifeDays":31}],"dispositionRecords":[],"replenishmentItems":[],\
        "settings":{"notificationsEnabled":true,"reminderDaysBefore":-1,"historyRetentionDays":-1}}
        """.utf8)

        assertValidationError(
            .emptyRequiredField(field: "食材名称", index: 0),
            from: blankName
        )

        let blankDispositionName = Data("""
        {"version":3,"items":[],"dispositionRecords":[{\
        "uuid":"8E99DC3A-84BF-44B2-9892-6678D03AB52C","foodName":" \\t ",\
        "category":"乳制品","categoryID":"dairy","storageZone":"冷藏",\
        "expiryDate":"2026-08-01T00:00:00Z","expiryDayKey":"2026-08-01",\
        "shelfLifeDaysEstimate":31,"action":"consumed",\
        "createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"}],\
        "replenishmentItems":[],\
        "settings":{"notificationsEnabled":true,"reminderDaysBefore":-1,"historyRetentionDays":-1}}
        """.utf8)
        assertValidationError(
            .emptyRequiredField(field: "历史食材名称", index: 0),
            from: blankDispositionName
        )

        let blankReplenishmentName = Data("""
        {"version":3,"items":[],"dispositionRecords":[],"replenishmentItems":[{\
        "uuid":"C8906475-03FB-4CA1-A93D-2CD746F2F7C3","name":" \\t ",\
        "category":"坚果","categoryID":"nut","storageZone":"常温",\
        "defaultShelfLifeDays":180,"createdAt":"2026-07-01T00:00:00Z",\
        "updatedAt":"2026-07-01T00:00:00Z"}],\
        "settings":{"notificationsEnabled":true,"reminderDaysBefore":-1,"historyRetentionDays":-1}}
        """.utf8)
        assertValidationError(
            .emptyRequiredField(field: "补货名称", index: 0),
            from: blankReplenishmentName
        )
    }

    func testV3RejectsPurchaseDayAfterExpiryDay() {
        let reversedDates = Data("""
        {"version":3,"items":[{"uuid":"D2451831-D5F8-4572-BAD6-C46236128BD0",\
        "name":"牛奶","category":"乳制品","categoryID":"dairy","storageZone":"冷藏",\
        "purchaseDate":"2026-07-10T00:00:00Z","expiryDate":"2026-07-11T00:00:00Z",\
        "purchaseDayKey":"2026-07-12","expiryDayKey":"2026-07-11",\
        "createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"}],\
        "dispositionRecords":[],"replenishmentItems":[],\
        "settings":{"notificationsEnabled":true,"reminderDaysBefore":-1,"historyRetentionDays":-1}}
        """.utf8)

        assertValidationError(.invalidDateOrder(kind: "食材", index: 0), from: reversedDates)

        let reversedDispositionDates = Data("""
        {"version":3,"items":[],"dispositionRecords":[{\
        "uuid":"C47D702E-CBFE-4167-90E4-32615191872D","foodName":"牛奶",\
        "category":"乳制品","categoryID":"dairy","storageZone":"冷藏",\
        "purchaseDate":"2026-07-10T00:00:00Z","expiryDate":"2026-07-11T00:00:00Z",\
        "purchaseDayKey":"2026-07-12","expiryDayKey":"2026-07-11",\
        "shelfLifeDaysEstimate":1,"action":"consumed",\
        "createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"}],\
        "replenishmentItems":[],\
        "settings":{"notificationsEnabled":true,"reminderDaysBefore":-1,"historyRetentionDays":-1}}
        """.utf8)
        assertValidationError(
            .invalidDateOrder(kind: "历史记录", index: 0),
            from: reversedDispositionDates
        )
    }

    func testV1MergeNameNormalizationIsCanonical() {
        XCTAssertEqual(
            BackupMergeIdentity.normalizedName("e\u{301}"),
            BackupMergeIdentity.normalizedName("é")
        )
    }

    func testV1MergeFingerprintUsesBusinessFieldsAndMatchesRestoredLot() throws {
        let json = """
        {"items":[
          {"name":"  杏仁  ","category":"坚果","storageZone":"常温","customIcon":"🥜",\
           "purchaseDate":"2025-01-02T12:00:00Z","expiryDate":"2025-06-01T12:00:00Z",\
           "quantity":"2袋","notes":"烘焙用","createdAt":"2025-01-02T12:34:56Z"},
          {"name":"杏仁","category":"坚果","storageZone":"常温","customIcon":"🥜",\
           "purchaseDate":"2025-01-02T12:00:00Z","expiryDate":"2025-06-02T12:00:00Z",\
           "quantity":"2袋","notes":"烘焙用","createdAt":"2025-01-02T12:34:56Z"},
          {"name":"杏仁","category":"乳制品","storageZone":"常温","customIcon":"🥜",\
           "purchaseDate":"2025-01-02T12:00:00Z","expiryDate":"2025-06-01T12:00:00Z",\
           "quantity":"2袋","notes":"烘焙用","createdAt":"2025-01-02T12:34:56Z"}
        ]}
        """

        let items = try FoodBackupDocument.decode(from: Data(json.utf8)).items
        let first = try XCTUnwrap(items.first)
        let firstFingerprint = BackupMergeIdentity.fingerprint(first)

        let restored = first.foodItem
        restored.createdAt = restored.createdAt.addingTimeInterval(0.987)
        XCTAssertEqual(firstFingerprint, BackupMergeIdentity.fingerprint(restored))
        XCTAssertEqual(firstFingerprint.name, "杏仁")
        XCTAssertEqual(firstFingerprint.categoryID, FoodCategoryID.nut.rawValue)
        XCTAssertEqual(firstFingerprint.storageZone, StorageZone.pantry.rawValue)
        XCTAssertEqual(firstFingerprint.quantity, "2袋")
        XCTAssertEqual(firstFingerprint.notes, "烘焙用")
        XCTAssertNotEqual(firstFingerprint, BackupMergeIdentity.fingerprint(items[1]))
        XCTAssertNotEqual(firstFingerprint, BackupMergeIdentity.fingerprint(items[2]))
    }

    func testV1MergeFingerprintRemainsStableAcrossExtremeTimezoneChange() throws {
        let json = """
        {"items":[
          {"name":"杏仁","category":"坚果","storageZone":"常温",\
           "purchaseDate":"2025-01-02T12:00:00Z","expiryDate":"2025-06-01T12:00:00Z",\
           "quantity":"2袋","createdAt":"2025-01-02T12:34:56Z"}
        ]}
        """
        let incoming = try XCTUnwrap(
            FoodBackupDocument.decode(from: Data(json.utf8)).items.first
        )
        let purchaseDate = try XCTUnwrap(incoming.purchaseDate)
        let plusFourteen = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3_600))
        let minusEleven = try XCTUnwrap(TimeZone(secondsFromGMT: -11 * 3_600))
        XCTAssertNotEqual(
            LocalDate(date: purchaseDate, timeZone: plusFourteen),
            LocalDate(date: purchaseDate, timeZone: minusEleven)
        )

        // Simulate a first v1 import in UTC+14. On a later merge in UTC-11, deriving identity from
        // current-zone civil days would differ. The fingerprint instead uses preserved raw dates.
        let restored = incoming.foodItem
        restored.purchaseDayKey = LocalDate(
            date: purchaseDate, timeZone: plusFourteen
        ).iso8601DateString
        restored.expiryDayKey = LocalDate(
            date: incoming.expiryDate, timeZone: plusFourteen
        ).iso8601DateString

        XCTAssertEqual(
            BackupMergeIdentity.fingerprint(restored),
            BackupMergeIdentity.fingerprint(incoming)
        )
    }

    func testV1MergeMultisetPreservesIdenticalLotsThenBecomesIdempotent() throws {
        let json = """
        {"items":[
          {"name":"核桃","category":"坚果","storageZone":"常温",\
           "expiryDate":"2025-12-31T00:00:00Z","quantity":"1袋",\
           "createdAt":"2025-01-01T00:00:00Z"},
          {"name":"核桃","category":"坚果","storageZone":"常温",\
           "expiryDate":"2025-12-31T00:00:00Z","quantity":"1袋",\
           "createdAt":"2025-01-01T00:00:00Z"}
        ]}
        """

        let incoming = try FoodBackupDocument.decode(from: Data(json.utf8)).items
            .map(BackupMergeIdentity.fingerprint)
        let fingerprint = try XCTUnwrap(incoming.first)

        // First merge keeps both distinct inventory lots even though their legacy payloads match.
        XCTAssertEqual(
            BackupMergeIdentity.uuidlessInsertionMask(
                existing: [], incoming: incoming, replacing: false
            ),
            [true, true]
        )
        // A local multiplicity of one only satisfies one incoming occurrence.
        XCTAssertEqual(
            BackupMergeIdentity.uuidlessInsertionMask(
                existing: [fingerprint], incoming: incoming, replacing: false
            ),
            [false, true]
        )
        // Re-merging the same backup is idempotent once both lots already exist.
        XCTAssertEqual(
            BackupMergeIdentity.uuidlessInsertionMask(
                existing: [fingerprint, fingerprint],
                incoming: incoming,
                replacing: false
            ),
            [false, false]
        )

        // Full replacement reproduces backup cardinality instead of treating equal payloads as
        // one lot; existing rows are deleted by the caller before both incoming rows are inserted.
        XCTAssertEqual(
            BackupMergeIdentity.uuidlessInsertionMask(
                existing: [fingerprint, fingerprint, fingerprint],
                incoming: incoming,
                replacing: true
            ),
            [true, true]
        )
    }

    func testReplacementDetectsDuplicateIdentityInEveryBackupCollection() throws {
        let backup = sampleBackup()
        let item = try XCTUnwrap(backup.items.first)
        let record = try XCTUnwrap(backup.dispositionRecords?.first)
        let replenishment = try XCTUnwrap(backup.replenishmentItems?.first)

        XCTAssertEqual(
            BackupMergeIdentity.firstDuplicateIdentity(
                in: FoodBackup(
                    version: 2,
                    items: [item, item],
                    dispositionRecords: [record],
                    replenishmentItems: [replenishment]
                )
            ),
            .foodItem(try XCTUnwrap(item.uuid))
        )
        XCTAssertEqual(
            BackupMergeIdentity.firstDuplicateIdentity(
                in: FoodBackup(
                    version: 2,
                    items: [item],
                    dispositionRecords: [record, record],
                    replenishmentItems: [replenishment]
                )
            ),
            .dispositionRecord(record.uuid)
        )
        XCTAssertEqual(
            BackupMergeIdentity.firstDuplicateIdentity(
                in: FoodBackup(
                    version: 2,
                    items: [item],
                    dispositionRecords: [record],
                    replenishmentItems: [replenishment, replenishment]
                )
            ),
            .replenishmentItem(replenishment.uuid)
        )
        XCTAssertNil(BackupMergeIdentity.firstDuplicateIdentity(in: backup))
    }

    func testReplacementPreservesDistinctUUIDPendingReplenishmentMultiplicity() {
        let pendingNames: Set<String> = ["杏仁"]

        XCTAssertTrue(
            BackupMergeIdentity.shouldSkipPendingReplenishment(
                normalizedName: "杏仁",
                completedAt: nil,
                existingPendingNames: pendingNames,
                merging: true
            )
        )
        XCTAssertFalse(
            BackupMergeIdentity.shouldSkipPendingReplenishment(
                normalizedName: "杏仁",
                completedAt: nil,
                existingPendingNames: pendingNames,
                merging: false
            )
        )
    }

    func testRejectsUnsupportedVersions() throws {
        for version in [0, FoodBackup.currentVersion + 1, Int.max] {
            assertValidationError(.unsupportedVersion(version)) {
                try FoodBackupDocument.encode(sampleBackup(version: version))
            }
        }
    }

    func testRejectsMoreThanMaximumAggregateObjectCount() throws {
        let seed = try XCTUnwrap(sampleBackup().items.first)
        let backup = FoodBackup(
            version: 3,
            items: Array(repeating: seed, count: FoodBackup.maximumObjectCount + 1),
            dispositionRecords: nil,
            replenishmentItems: nil
        )

        XCTAssertThrowsError(try backup.validate()) { error in
            XCTAssertEqual(
                error as? FoodBackupValidationError,
                .tooManyObjects(FoodBackup.maximumObjectCount + 1)
            )
        }
    }

    func testWireBackupPreservesLegacyTextOutsideCurrentEditingLimits() throws {
        let legacyName = " \n\t " + String(repeating: "坚", count: FoodTextConstraints.nameMaximum + 1)
        let legacyIcon = String(repeating: "🥜", count: FoodTextConstraints.customIconMaximum + 1)
        let legacyNotes = String(repeating: "旧", count: FoodTextConstraints.notesMaximum + 1)
        let item = FoodItem(
            name: legacyName,
            category: .nut,
            storageZone: .pantry,
            customIcon: legacyIcon,
            expiryDate: expiry,
            notes: legacyNotes
        )
        let backup = FoodBackup(
            version: 3,
            items: [FoodBackupItem(item)],
            dispositionRecords: [],
            replenishmentItems: [],
            settings: validSettings
        )

        let decoded = try FoodBackupDocument.decode(from: FoodBackupDocument.encode(backup))

        XCTAssertEqual(decoded.items.first?.name, legacyName)
        XCTAssertEqual(decoded.items.first?.customIcon, legacyIcon)
        XCTAssertEqual(decoded.items.first?.notes, legacyNotes)
    }

    func testV2LegacyRestoreThenV3ReexportPreservesTextAndClampsDerivedShelfLife() throws {
        let legacyTextItem = FoodItem(
            name: String(repeating: "牛", count: FoodTextConstraints.nameMaximum + 1),
            category: .dairy,
            storageZone: .fridge,
            purchaseDate: expiry.addingTimeInterval(-86_400), expiryDate: expiry
        )
        let invalidShelfLife = FoodItem(
            name: "牛奶", category: .dairy, storageZone: .fridge, expiryDate: expiry
        )
        invalidShelfLife.originalShelfLifeDays = FoodShelfLifeConstraints.maximumDays + 1
        let legacyBackup = FoodBackup(
            version: 2,
            items: [FoodBackupItem(legacyTextItem), FoodBackupItem(invalidShelfLife)],
            dispositionRecords: [],
            replenishmentItems: []
        )
        let decodedLegacy = try FoodBackupDocument.decode(
            from: FoodBackupDocument.encode(legacyBackup)
        )
        let restored = decodedLegacy.items.map(\.foodItem)
        let currentDocument = FoodBackupDocument(
            items: restored,
            records: [],
            replenishments: [],
            settings: validSettings
        )
        let current = try FoodBackupDocument.decode(
            from: FoodBackupDocument.encode(currentDocument.backup)
        )

        XCTAssertEqual(current.effectiveVersion, 3)
        XCTAssertEqual(current.items.first?.name, legacyTextItem.name)
        XCTAssertEqual(
            current.items.first?.purchaseDayKey,
            legacyTextItem.purchaseDate.map { LocalDate(date: $0) }
        )
        XCTAssertEqual(
            current.items.first?.expiryDayKey,
            LocalDate(date: legacyTextItem.expiryDate)
        )
        XCTAssertEqual(
            current.items.last?.originalShelfLifeDays,
            FoodShelfLifeConstraints.maximumDays
        )
    }

    func testRejectsMalformedGregorianCivilDateAndUnknownStableCategory() {
        let invalidDate = """
        {"version":3,"items":[{"name":"测试","category":"其他","storageZone":"常温",\
        "expiryDate":"2026-03-01T00:00:00Z","expiryDayKey":"2026-02-30",\
        "createdAt":"2026-01-01T00:00:00Z"}]}
        """
        XCTAssertThrowsError(try FoodBackupDocument.decode(from: Data(invalidDate.utf8)))

        let unknownCategory = """
        {"version":3,"items":[{"name":"测试","category":"其他","categoryID":"future-category",\
        "storageZone":"常温","expiryDate":"2026-03-01T00:00:00Z",\
        "createdAt":"2026-01-01T00:00:00Z"}]}
        """
        XCTAssertThrowsError(try FoodBackupDocument.decode(from: Data(unknownCategory.utf8)))
    }

    func testRejectsInvalidSettingsAndOversizedSuggestionPayload() throws {
        let invalidReminder = FoodBackupSettings(
            notificationsEnabled: true,
            reminderDaysBefore: 365,
            historyRetentionDays: -1,
            historySuggestionOverrides: nil
        )
        XCTAssertThrowsError(try invalidReminder.validate()) { error in
            XCTAssertEqual(error as? FoodBackupValidationError, .invalidSetting("默认提前提醒"))
        }

        let invalidRetention = FoodBackupSettings(
            notificationsEnabled: true,
            reminderDaysBefore: -1,
            historyRetentionDays: 1,
            historySuggestionOverrides: nil
        )
        XCTAssertThrowsError(try invalidRetention.validate()) { error in
            XCTAssertEqual(error as? FoodBackupValidationError, .invalidSetting("历史保留期"))
        }

        let oversizedOverrides = FoodBackupSettings(
            notificationsEnabled: true,
            reminderDaysBefore: -1,
            historyRetentionDays: -1,
            historySuggestionOverrides: Data(repeating: 0x61, count: 1_024 * 1_024 + 1)
        )
        XCTAssertThrowsError(try oversizedOverrides.validate()) { error in
            XCTAssertEqual(error as? FoodBackupValidationError, .invalidSetting("历史建议设置过大"))
        }

        let corruptOverrides = FoodBackupSettings(
            notificationsEnabled: true,
            reminderDaysBefore: -1,
            historyRetentionDays: -1,
            historySuggestionOverrides: Data("not-json".utf8)
        )
        XCTAssertThrowsError(try corruptOverrides.validate()) { error in
            XCTAssertEqual(error as? FoodBackupValidationError, .invalidSetting("历史建议设置损坏"))
        }

        let invalidOverride = HistorySuggestionOverride(
            name: "   ",
            category: .nut,
            storageZone: .pantry,
            customIcon: nil,
            defaultShelfLifeDays: 180,
            isHidden: false
        )
        let invalidOverrideData = try JSONEncoder().encode(["invalid": invalidOverride])
        let invalidOverrideSettings = FoodBackupSettings(
            notificationsEnabled: true,
            reminderDaysBefore: -1,
            historyRetentionDays: -1,
            historySuggestionOverrides: invalidOverrideData
        )
        XCTAssertThrowsError(try invalidOverrideSettings.validate()) { error in
            XCTAssertEqual(error as? FoodBackupValidationError, .invalidSetting("历史建议设置内容"))
        }

        let mismatchedName = HistorySuggestionOverride(
            name: "鸡蛋",
            category: .egg,
            storageZone: .fridge,
            customIcon: nil,
            defaultShelfLifeDays: 14,
            isHidden: false
        )
        let mismatchedData = try JSONEncoder().encode(["牛奶": mismatchedName])
        let mismatchedSettings = FoodBackupSettings(
            notificationsEnabled: true,
            reminderDaysBefore: -1,
            historyRetentionDays: -1,
            historySuggestionOverrides: mismatchedData
        )
        XCTAssertThrowsError(try mismatchedSettings.validate()) { error in
            XCTAssertEqual(error as? FoodBackupValidationError, .invalidSetting("历史建议设置内容"))
        }
    }

    func testRejectsControlCharactersAndInvalidTimestampOrdering() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let controlCharacterName = FoodItem(
            name: "牛\u{0000}奶", category: .dairy, storageZone: .fridge,
            expiryDate: expiry
        )
        controlCharacterName.createdAt = now.addingTimeInterval(-100)
        controlCharacterName.updatedAt = now.addingTimeInterval(-50)
        let controlBackup = FoodBackup(
            version: 3,
            items: [FoodBackupItem(controlCharacterName)],
            dispositionRecords: nil,
            replenishmentItems: nil
        )
        XCTAssertThrowsError(try controlBackup.validate(now: now)) { error in
            XCTAssertEqual(
                error as? FoodBackupValidationError,
                .invalidText(field: "食材名称", index: 0)
            )
        }

        let reversedTimestamps = FoodItem(
            name: "牛奶", category: .dairy, storageZone: .fridge,
            expiryDate: expiry
        )
        reversedTimestamps.createdAt = now.addingTimeInterval(-100)
        reversedTimestamps.updatedAt = now.addingTimeInterval(-200)
        let timestampBackup = FoodBackup(
            version: 3,
            items: [FoodBackupItem(reversedTimestamps)],
            dispositionRecords: nil,
            replenishmentItems: nil
        )
        XCTAssertThrowsError(try timestampBackup.validate(now: now)) { error in
            XCTAssertEqual(
                error as? FoodBackupValidationError,
                .invalidTimestamp(kind: "食材", index: 0)
            )
        }

        let futureTimestamp = FoodItem(
            name: "牛奶", category: .dairy, storageZone: .fridge,
            expiryDate: expiry
        )
        futureTimestamp.createdAt = now.addingTimeInterval(2 * 86_400)
        futureTimestamp.updatedAt = futureTimestamp.createdAt
        let futureBackup = FoodBackup(
            version: 3,
            items: [FoodBackupItem(futureTimestamp)],
            dispositionRecords: nil,
            replenishmentItems: nil
        )
        XCTAssertThrowsError(try futureBackup.validate(now: now)) { error in
            XCTAssertEqual(
                error as? FoodBackupValidationError,
                .invalidTimestamp(kind: "食材", index: 0)
            )
        }
    }

    func testEncoderRefusesJSONLargerThanImporterLimit() throws {
        let largeItem = FoodItem(
            name: "批量测试", category: .other, storageZone: .pantry,
            expiryDate: Date().addingTimeInterval(86_400),
            notes: String(repeating: "x", count: 10_000)
        )
        let seed = FoodBackupItem(largeItem)
        let backup = FoodBackup(
            version: 3,
            items: Array(repeating: seed, count: 2_700),
            dispositionRecords: [],
            replenishmentItems: [],
            settings: validSettings
        )

        XCTAssertThrowsError(try FoodBackupDocument.encode(backup)) { error in
            guard let validationError = error as? FoodBackupValidationError,
                  case .fileTooLarge(let actualBytes) = validationError else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(actualBytes, FoodBackup.maximumFileSize)
        }
    }

    func testSettingsApplyRoundTripsValidSuggestionOverrides() throws {
        let suiteName = "FoodBackupTests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let override = HistorySuggestionOverride(
            name: "核桃",
            category: .nut,
            storageZone: .pantry,
            customIcon: nil,
            defaultShelfLifeDays: 180,
            isHidden: true
        )
        let overrideData = try JSONEncoder().encode(["核桃": override])
        let settings = FoodBackupSettings(
            notificationsEnabled: false,
            reminderDaysBefore: 7,
            historyRetentionDays: 365,
            historySuggestionOverrides: overrideData
        )

        try settings.validate()
        settings.apply(to: defaults)

        XCTAssertEqual(defaults.object(forKey: "notificationsEnabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "reminderDaysBefore") as? Int, 7)
        XCTAssertEqual(defaults.object(forKey: HistoryMaintenance.retentionDaysKey) as? Int, 365)
        let restoredData = try XCTUnwrap(defaults.data(forKey: HistorySuggestionStore.storageKey))
        let restoredOverrides = try JSONDecoder().decode([String: HistorySuggestionOverride].self, from: restoredData)
        XCTAssertEqual(restoredOverrides["核桃"], override)
        XCTAssertEqual(restoredOverrides["核桃"]?.category, .nut)
    }

    func testSettingsApplyWithNilOverridesClearsPreviouslyStoredOverrides() throws {
        let suiteName = "FoodBackupTests.clear-settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("stale".utf8), forKey: HistorySuggestionStore.storageKey)
        let settings = FoodBackupSettings(
            notificationsEnabled: true,
            reminderDaysBefore: -1,
            historyRetentionDays: -1,
            historySuggestionOverrides: nil
        )

        settings.apply(to: defaults)

        XCTAssertNil(defaults.data(forKey: HistorySuggestionStore.storageKey))
    }

    func testStoreRecoveryLocationRemainsReachableAfterRecoveryScreenDisappears() throws {
        let suiteName = "FoodBackupTests.store-recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FridgeTracker-Recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        StoreRecoveryLocation.record(directory, defaults: defaults)

        XCTAssertEqual(StoreRecoveryLocation.latestAvailableURL(defaults: defaults), directory)
        try FileManager.default.removeItem(at: directory)
        XCTAssertNil(StoreRecoveryLocation.latestAvailableURL(defaults: defaults))
    }
}
