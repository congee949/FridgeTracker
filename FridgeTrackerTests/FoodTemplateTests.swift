import XCTest
import SwiftData
@testable import FridgeTracker

/// Regression baseline for `FoodTemplate`: `normalizedName`, `fromHistory(_:records:)` aggregation
/// (dedup by normalized name keeping the newest source across both live items and disposition
/// records, order-independence), and `applying(_:)` override overlay.
///
/// `@MainActor` because most tests build `@Model` instances (`FoodItem`, `FoodDispositionRecord`).
@MainActor
final class FoodTemplateTests: XCTestCase {

    // MARK: - Helpers

    /// A whole-day-aligned date `daysFromNow` from the start of today, so that day-component math
    /// (used by `shelfLifeDaysEstimate`) yields exact integers regardless of wall-clock time.
    private func dayAligned(_ daysFromNow: Int) -> Date {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: daysFromNow, to: startOfToday)!
    }

    /// Builds a `FoodItem` with an explicit `createdAt` for deterministic ordering.
    /// Note: `originalShelfLifeDays` is computed at init from the init-time `createdAt` (= now),
    /// so callers that assert `defaultShelfLifeDays` should pass a `purchaseDate` to pin the estimate.
    private func makeItem(
        name: String,
        category: FoodCategory = .other,
        storageZone: StorageZone = .fridge,
        customIcon: String? = nil,
        purchaseDate: Date? = nil,
        expiryDate: Date,
        quantity: String? = nil,
        notes: String? = nil,
        createdAt: Date
    ) -> FoodItem {
        let item = FoodItem(
            name: name,
            category: category,
            storageZone: storageZone,
            customIcon: customIcon,
            purchaseDate: purchaseDate,
            expiryDate: expiryDate,
            quantity: quantity,
            notes: notes
        )
        item.createdAt = createdAt
        return item
    }

    /// Builds a `FoodDispositionRecord` via the field-level initializer so `createdAt` and
    /// `shelfLifeDaysEstimate` are fully controlled.
    private func makeRecord(
        foodName: String,
        category: FoodCategory = .other,
        storageZone: StorageZone = .fridge,
        customIcon: String? = nil,
        quantity: String? = nil,
        purchaseDate: Date? = nil,
        expiryDate: Date,
        shelfLifeDaysEstimate: Int,
        action: FoodDispositionAction = .consumed,
        createdAt: Date
    ) -> FoodDispositionRecord {
        FoodDispositionRecord(
            uuid: UUID(),
            foodName: foodName,
            category: category,
            storageZone: storageZone,
            customIcon: customIcon,
            quantity: quantity,
            purchaseDate: purchaseDate,
            expiryDate: expiryDate,
            shelfLifeDaysEstimate: shelfLifeDaysEstimate,
            action: action,
            createdAt: createdAt
        )
    }

    // MARK: - normalizedName / id / icon

    func testNormalizedNameTrimsWhitespaceAndNewlines() {
        let template = FoodTemplate(
            name: "  牛奶 \n",
            category: .dairy,
            storageZone: .fridge,
            customIcon: nil,
            defaultShelfLifeDays: 7,
            quantity: nil,
            notes: nil,
            purchaseDate: nil
        )
        XCTAssertEqual(template.normalizedName, "牛奶")
        // id is defined as normalizedName.
        XCTAssertEqual(template.id, "牛奶")
    }

    func testIconFallsBackToCategoryIconWhenCustomIconNil() {
        let template = FoodTemplate(
            name: "番茄",
            category: .vegetable,
            storageZone: .fridge,
            customIcon: nil,
            defaultShelfLifeDays: 5,
            quantity: nil,
            notes: nil,
            purchaseDate: nil
        )
        XCTAssertEqual(template.icon, FoodCategory.vegetable.icon)
    }

    func testIconUsesCustomIconWhenPresent() {
        let template = FoodTemplate(
            name: "番茄",
            category: .vegetable,
            storageZone: .fridge,
            customIcon: "🍅",
            defaultShelfLifeDays: 5,
            quantity: nil,
            notes: nil,
            purchaseDate: nil
        )
        XCTAssertEqual(template.icon, "🍅")
    }

    // MARK: - fromHistory: basic shape

    func testFromHistoryEmptyInputsProduceEmptyOutput() {
        XCTAssertTrue(FoodTemplate.fromHistory([]).isEmpty)
        XCTAssertTrue(FoodTemplate.fromHistory([], records: []).isEmpty)
    }

    func testFromHistoryMapsItemFieldsAndUsesPurchaseDateForShelfLife() {
        // purchaseDate pins shelfLifeDaysEstimate to startOfDay(purchase)->startOfDay(expiry) = 4 days.
        let item = makeItem(
            name: "酸奶",
            category: .dairy,
            storageZone: .fridge,
            customIcon: "🥛",
            purchaseDate: dayAligned(0),
            expiryDate: dayAligned(4),
            quantity: "2瓶",
            notes: "促销",
            createdAt: dayAligned(0)
        )
        let templates = FoodTemplate.fromHistory([item])
        XCTAssertEqual(templates.count, 1)
        let t = templates[0]
        XCTAssertEqual(t.name, "酸奶")
        XCTAssertEqual(t.category, .dairy)
        XCTAssertEqual(t.storageZone, .fridge)
        XCTAssertEqual(t.customIcon, "🥛")
        XCTAssertEqual(t.defaultShelfLifeDays, 4)
        XCTAssertEqual(t.quantity, "2瓶")
        XCTAssertEqual(t.notes, "促销")
        XCTAssertEqual(t.purchaseDate, dayAligned(0))
    }

    func testFromHistoryRecordNotesAlwaysNilAndShelfLifeFlooredToOne() {
        // Records never carry notes into the template, and defaultShelfLifeDays is max(estimate, 1).
        let record = makeRecord(
            foodName: "西兰花",
            category: .vegetable,
            storageZone: .fridge,
            customIcon: "🥦",
            quantity: "1颗",
            expiryDate: dayAligned(2),
            shelfLifeDaysEstimate: 0,
            createdAt: dayAligned(-1)
        )
        let templates = FoodTemplate.fromHistory([], records: [record])
        XCTAssertEqual(templates.count, 1)
        let t = templates[0]
        XCTAssertEqual(t.name, "西兰花")
        XCTAssertEqual(t.category, .vegetable)
        XCTAssertEqual(t.storageZone, .fridge)
        XCTAssertEqual(t.customIcon, "🥦")
        XCTAssertEqual(t.quantity, "1颗")
        XCTAssertNil(t.notes)
        // shelfLifeDaysEstimate of 0 -> floored to 1.
        XCTAssertEqual(t.defaultShelfLifeDays, 1)
    }

    func testFromHistorySkipsBlankNormalizedNames() {
        let blankItem = makeItem(name: "   ", expiryDate: dayAligned(3), createdAt: dayAligned(0))
        let realItem = makeItem(name: "苹果", purchaseDate: dayAligned(0), expiryDate: dayAligned(3), createdAt: dayAligned(0))
        let templates = FoodTemplate.fromHistory([blankItem, realItem])
        XCTAssertEqual(templates.map(\.name), ["苹果"])
    }

    // MARK: - fromHistory: dedup keeps the newest source

    func testFromHistoryDedupsByNormalizedNameAcrossWhitespaceVariants() {
        // "牛奶" and " 牛奶 " normalize to the same key, so only one survives.
        let older = makeItem(name: "牛奶", expiryDate: dayAligned(5), createdAt: dayAligned(-2))
        let newer = makeItem(name: " 牛奶 ", expiryDate: dayAligned(5), createdAt: dayAligned(0))
        let templates = FoodTemplate.fromHistory([older, newer])
        XCTAssertEqual(templates.count, 1)
        XCTAssertEqual(templates[0].normalizedName, "牛奶")
    }

    func testFromHistoryKeepsNewestAmongItemsAndDrawsFieldsFromIt() {
        // Same name, two items; newest createdAt wins and its fields are used.
        let older = makeItem(
            name: "牛奶",
            category: .other,
            storageZone: .pantry,
            customIcon: "📦",
            purchaseDate: dayAligned(-2),
            expiryDate: dayAligned(0),
            quantity: "1盒",
            createdAt: dayAligned(-2)
        )
        let newer = makeItem(
            name: "牛奶",
            category: .dairy,
            storageZone: .fridge,
            customIcon: "🥛",
            purchaseDate: dayAligned(0),
            expiryDate: dayAligned(7),
            quantity: "2盒",
            createdAt: dayAligned(0)
        )
        let templates = FoodTemplate.fromHistory([older, newer])
        XCTAssertEqual(templates.count, 1)
        let t = templates[0]
        // Fields drawn from the newer item.
        XCTAssertEqual(t.category, .dairy)
        XCTAssertEqual(t.storageZone, .fridge)
        XCTAssertEqual(t.customIcon, "🥛")
        XCTAssertEqual(t.quantity, "2盒")
        XCTAssertEqual(t.defaultShelfLifeDays, 7)
    }

    func testFromHistoryRecordWinsOverOlderItemWhenRecordIsNewer() {
        // The disposition record is newer than the live item -> the record's fields are used.
        let item = makeItem(
            name: "鸡蛋",
            category: .other,
            storageZone: .pantry,
            customIcon: "📦",
            purchaseDate: dayAligned(-5),
            expiryDate: dayAligned(0),
            quantity: "6个",
            createdAt: dayAligned(-5)
        )
        let record = makeRecord(
            foodName: "鸡蛋",
            category: .egg,
            storageZone: .fridge,
            customIcon: "🥚",
            quantity: "12个",
            expiryDate: dayAligned(10),
            shelfLifeDaysEstimate: 21,
            createdAt: dayAligned(-1)
        )
        let templates = FoodTemplate.fromHistory([item], records: [record])
        XCTAssertEqual(templates.count, 1)
        let t = templates[0]
        XCTAssertEqual(t.category, .egg)
        XCTAssertEqual(t.storageZone, .fridge)
        XCTAssertEqual(t.customIcon, "🥚")
        XCTAssertEqual(t.quantity, "12个")
        XCTAssertEqual(t.defaultShelfLifeDays, 21)
        // notes always nil for record-sourced templates.
        XCTAssertNil(t.notes)
    }

    func testFromHistoryItemWinsOverOlderRecordWhenItemIsNewer() {
        // The live item is newer than the disposition record -> the item's fields are used.
        let record = makeRecord(
            foodName: "鸡胸肉",
            category: .other,
            storageZone: .pantry,
            customIcon: "📦",
            quantity: "1块",
            expiryDate: dayAligned(0),
            shelfLifeDaysEstimate: 5,
            createdAt: dayAligned(-3)
        )
        let item = makeItem(
            name: "鸡胸肉",
            category: .meat,
            storageZone: .freezer,
            customIcon: "🥩",
            purchaseDate: dayAligned(0),
            expiryDate: dayAligned(30),
            quantity: "3块",
            notes: "分装冷冻",
            createdAt: dayAligned(0)
        )
        let templates = FoodTemplate.fromHistory([item], records: [record])
        XCTAssertEqual(templates.count, 1)
        let t = templates[0]
        XCTAssertEqual(t.category, .meat)
        XCTAssertEqual(t.storageZone, .freezer)
        XCTAssertEqual(t.customIcon, "🥩")
        XCTAssertEqual(t.quantity, "3块")
        XCTAssertEqual(t.defaultShelfLifeDays, 30)
        XCTAssertEqual(t.notes, "分装冷冻")
    }

    // MARK: - fromHistory: order-independence

    func testFromHistoryIsOrderIndependentForItems() {
        let older = makeItem(name: "牛奶", category: .other, expiryDate: dayAligned(5), createdAt: dayAligned(-2))
        let newer = makeItem(name: "牛奶", category: .dairy, expiryDate: dayAligned(5), createdAt: dayAligned(0))

        let ascending = FoodTemplate.fromHistory([older, newer])
        let descending = FoodTemplate.fromHistory([newer, older])

        XCTAssertEqual(ascending.count, 1)
        XCTAssertEqual(descending.count, 1)
        // Regardless of input order, the newest source's category wins.
        XCTAssertEqual(ascending[0].category, .dairy)
        XCTAssertEqual(descending[0].category, .dairy)
    }

    func testFromHistoryOverallOrderingIsNewestFirst() {
        // Distinct names with known createdAt -> output is sorted newest-first.
        let a = makeItem(name: "A", expiryDate: dayAligned(3), createdAt: dayAligned(-3))
        let b = makeItem(name: "B", expiryDate: dayAligned(3), createdAt: dayAligned(-1))
        let c = makeRecord(foodName: "C", expiryDate: dayAligned(3), shelfLifeDaysEstimate: 3, createdAt: dayAligned(-2))

        let templates = FoodTemplate.fromHistory([a, b], records: [c])
        // b (-1) newest, then c (-2), then a (-3).
        XCTAssertEqual(templates.map(\.name), ["B", "C", "A"])
    }

    func testFromHistoryUsesStableNameOrderWhenUniqueSourcesHaveEqualDates() {
        let sameDate = dayAligned(-1)
        let milk = makeItem(name: "牛奶", expiryDate: dayAligned(3), createdAt: sameDate)
        let apple = makeItem(name: "苹果", expiryDate: dayAligned(3), createdAt: sameDate)

        let forward = FoodTemplate.fromHistory([milk, apple])
        let reversed = FoodTemplate.fromHistory([apple, milk])

        XCTAssertEqual(forward.map(\.normalizedName), reversed.map(\.normalizedName))
    }

    func testFromHistoryMultipleNamesEachKeepNewestSource() {
        // Two names, each appearing in both items and records at different times.
        let appleOld = makeItem(name: "苹果", category: .other, expiryDate: dayAligned(3), createdAt: dayAligned(-4))
        let appleNewRecord = makeRecord(foodName: "苹果", category: .fruit, expiryDate: dayAligned(3), shelfLifeDaysEstimate: 7, createdAt: dayAligned(-1))
        let milkNewItem = makeItem(name: "牛奶", category: .dairy, expiryDate: dayAligned(5), createdAt: dayAligned(0))
        let milkOldRecord = makeRecord(foodName: "牛奶", category: .other, expiryDate: dayAligned(5), shelfLifeDaysEstimate: 5, createdAt: dayAligned(-6))

        let templates = FoodTemplate.fromHistory([appleOld, milkNewItem], records: [appleNewRecord, milkOldRecord])
        XCTAssertEqual(templates.count, 2)

        let apple = try? XCTUnwrap(templates.first { $0.name == "苹果" })
        let milk = try? XCTUnwrap(templates.first { $0.name == "牛奶" })
        // 苹果: newest source is the record (-1) -> .fruit.
        XCTAssertEqual(apple?.category, .fruit)
        // 牛奶: newest source is the item (0) -> .dairy.
        XCTAssertEqual(milk?.category, .dairy)
    }

    // MARK: - applying(override)

    func testApplyingNilOverrideReturnsUnchangedTemplate() {
        let base = FoodTemplate(
            name: "牛奶",
            category: .dairy,
            storageZone: .fridge,
            customIcon: "🥛",
            defaultShelfLifeDays: 7,
            quantity: "1盒",
            notes: "原味",
            purchaseDate: dayAligned(0)
        )
        let result = base.applying(nil)
        XCTAssertEqual(result.name, "牛奶")
        XCTAssertEqual(result.category, .dairy)
        XCTAssertEqual(result.storageZone, .fridge)
        XCTAssertEqual(result.customIcon, "🥛")
        XCTAssertEqual(result.defaultShelfLifeDays, 7)
        XCTAssertEqual(result.quantity, "1盒")
        XCTAssertEqual(result.notes, "原味")
        XCTAssertEqual(result.purchaseDate, dayAligned(0))
    }

    func testApplyingOverrideOverlaysCategoryZoneIconAndShelfLifeButKeepsRest() {
        let base = FoodTemplate(
            name: "牛奶",
            category: .dairy,
            storageZone: .fridge,
            customIcon: "🥛",
            defaultShelfLifeDays: 7,
            quantity: "1盒",
            notes: "原味",
            purchaseDate: dayAligned(0)
        )
        let override = HistorySuggestionOverride(
            name: "牛奶",
            category: .beverage,
            storageZone: .pantry,
            customIcon: "🧃",
            defaultShelfLifeDays: 14,
            isHidden: false
        )
        let result = base.applying(override)
        // Overlaid from the override.
        XCTAssertEqual(result.category, .beverage)
        XCTAssertEqual(result.storageZone, .pantry)
        XCTAssertEqual(result.customIcon, "🧃")
        XCTAssertEqual(result.defaultShelfLifeDays, 14)
        // Preserved from the base template (override.name is NOT applied to the template name).
        XCTAssertEqual(result.name, "牛奶")
        XCTAssertEqual(result.quantity, "1盒")
        XCTAssertEqual(result.notes, "原味")
        XCTAssertEqual(result.purchaseDate, dayAligned(0))
    }

    func testApplyingOverrideWithNilCustomIconClearsIconAndFallsBackToCategoryIcon() {
        let base = FoodTemplate(
            name: "牛奶",
            category: .dairy,
            storageZone: .fridge,
            customIcon: "🥛",
            defaultShelfLifeDays: 7,
            quantity: nil,
            notes: nil,
            purchaseDate: nil
        )
        let override = HistorySuggestionOverride(
            name: "牛奶",
            category: .beverage,
            storageZone: .fridge,
            customIcon: nil,
            defaultShelfLifeDays: 7,
            isHidden: false
        )
        let result = base.applying(override)
        XCTAssertNil(result.customIcon)
        // With customIcon cleared, icon falls back to the (overridden) category's icon.
        XCTAssertEqual(result.icon, FoodCategory.beverage.icon)
    }

    func testApplyingOverlaysRegardlessOfIsHiddenFlag() {
        // `applying` itself does not consult isHidden; the overlay happens even when hidden.
        // (Hidden filtering lives in HistorySuggestionStore.applyOverrides, not here.)
        let base = FoodTemplate(
            name: "牛奶",
            category: .dairy,
            storageZone: .fridge,
            customIcon: "🥛",
            defaultShelfLifeDays: 7,
            quantity: nil,
            notes: nil,
            purchaseDate: nil
        )
        let override = HistorySuggestionOverride(
            name: "牛奶",
            category: .beverage,
            storageZone: .pantry,
            customIcon: "🧃",
            defaultShelfLifeDays: 99,
            isHidden: true
        )
        let result = base.applying(override)
        XCTAssertEqual(result.category, .beverage)
        XCTAssertEqual(result.storageZone, .pantry)
        XCTAssertEqual(result.customIcon, "🧃")
        XCTAssertEqual(result.defaultShelfLifeDays, 99)
    }
}
