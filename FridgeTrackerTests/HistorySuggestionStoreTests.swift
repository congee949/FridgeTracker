import XCTest
@testable import FridgeTracker

/// Regression baseline for `HistorySuggestionStore` and `HistorySuggestionOverride`
/// in `FridgeTracker/Utilities/HistorySuggestionStore.swift`.
///
/// Covers the pure mapping/filtering surface:
/// - name normalization (`override(for:)`, `isHidden(_:)`, `save`) trims whitespace
///   and newlines but does NOT case-fold.
/// - `applyOverrides(to:)` overlays matching overrides and drops hidden templates.
/// - `template(for:from:)` resolves + overlays, and rejects blank / hidden names.
/// - `HistorySuggestionOverride` Codable round-trip.
///
/// CAUTION: `HistorySuggestionStore.shared` is a singleton that persists to
/// `UserDefaults.standard` under the key `"historySuggestionOverrides"`. To avoid
/// bleeding global state across tests (and into the real app's defaults), each test
/// snapshots that key in `setUp`, removes every override it adds in `tearDown`, and
/// restores the original UserDefaults payload. `overrides` is `private(set)`, so the
/// only supported reset path is `save` / `removeOverride`; tests track the keys they
/// touch and clean them up explicitly.
///
/// These are pure-logic tests: they use `FoodTemplate.common` (a plain struct, no
/// `@Model`), so no `ModelContext` / main actor / container is required.
final class HistorySuggestionStoreTests: XCTestCase {

    private let defaultsKey = "historySuggestionOverrides"
    private var savedDefaultsPayload: Data?
    /// Normalized keys this test inserted via `save`, removed in tearDown.
    private var insertedKeys: Set<String> = []

    private var store: HistorySuggestionStore { .shared }

    override func setUp() {
        super.setUp()
        // Snapshot whatever the singleton/app already persisted so we can restore it.
        savedDefaultsPayload = UserDefaults.standard.data(forKey: defaultsKey)
        insertedKeys = []
    }

    override func tearDown() {
        // Remove every override this test added so the in-memory singleton is clean
        // for the next test (overrides is private(set); removeOverride is the only path).
        for key in insertedKeys {
            store.removeOverride(for: key)
        }
        insertedKeys = []
        // Restore the original persisted payload (or clear it if there was none).
        if let payload = savedDefaultsPayload {
            UserDefaults.standard.set(payload, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        savedDefaultsPayload = nil
        super.tearDown()
    }

    // MARK: - Test helpers

    /// Build an override and track its normalized key for tearDown cleanup.
    @discardableResult
    private func makeOverride(
        name: String,
        category: FoodCategory = .other,
        storageZone: StorageZone = .pantry,
        customIcon: String? = nil,
        defaultShelfLifeDays: Int = 5,
        isHidden: Bool = false
    ) -> HistorySuggestionOverride {
        HistorySuggestionOverride(
            name: name,
            category: category,
            storageZone: storageZone,
            customIcon: customIcon,
            defaultShelfLifeDays: defaultShelfLifeDays,
            isHidden: isHidden
        )
    }

    /// Save through the store and remember the trimmed key for cleanup.
    private func saveTracked(_ override: HistorySuggestionOverride) {
        store.save(override)
        insertedKeys.insert(override.name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - HistorySuggestionOverride.normalizedName

    func testOverrideNormalizedNameTrimsWhitespaceAndNewlines() {
        let override = makeOverride(name: "  牛奶 \n")
        XCTAssertEqual(override.normalizedName, "牛奶")
    }

    func testOverrideNormalizedNameDoesNotCaseFold() {
        // Documents actual behavior: normalization is trim-only, no lowercasing.
        let override = makeOverride(name: "  Milk ")
        XCTAssertEqual(override.normalizedName, "Milk")
    }

    // MARK: - HistorySuggestionOverride Codable

    func testOverrideCodableRoundTrip() throws {
        let original = makeOverride(
            name: "酸奶",
            category: .dairy,
            storageZone: .fridge,
            customIcon: "🥛",
            defaultShelfLifeDays: 14,
            isHidden: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HistorySuggestionOverride.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testOverrideDictionaryCodableRoundTrip() throws {
        // The store persists [String: HistorySuggestionOverride]; verify that shape too.
        let dict: [String: HistorySuggestionOverride] = [
            "牛奶": makeOverride(name: "牛奶", category: .dairy, storageZone: .fridge),
            "草莓": makeOverride(name: "草莓", category: .fruit, isHidden: true)
        ]

        let data = try JSONEncoder().encode(dict)
        let decoded = try JSONDecoder().decode([String: HistorySuggestionOverride].self, from: data)

        XCTAssertEqual(decoded, dict)
    }

    // MARK: - save / override(for:)

    func testSaveStoresOverrideRetrievableByExactName() throws {
        saveTracked(makeOverride(name: "牛奶", category: .dairy, storageZone: .fridge, defaultShelfLifeDays: 9))

        let fetched = try XCTUnwrap(store.override(for: "牛奶"))
        XCTAssertEqual(fetched.category, .dairy)
        XCTAssertEqual(fetched.storageZone, .fridge)
        XCTAssertEqual(fetched.defaultShelfLifeDays, 9)
    }

    func testSaveTrimsKeyAndStoredName() throws {
        saveTracked(makeOverride(name: "  牛奶  ", category: .dairy))

        // Stored under the trimmed key...
        let viaTrimmed = try XCTUnwrap(store.override(for: "牛奶"))
        // ...and the override's own name is trimmed on save.
        XCTAssertEqual(viaTrimmed.name, "牛奶")
    }

    func testOverrideLookupNormalizesQueryName() throws {
        saveTracked(makeOverride(name: "牛奶", category: .dairy))

        // Lookup with surrounding whitespace still hits the trimmed key.
        XCTAssertNotNil(store.override(for: "  牛奶 \n"))
    }

    func testOverrideLookupIsCaseSensitive() throws {
        // Normalization trims but does not case-fold, so case mismatches miss.
        saveTracked(makeOverride(name: "Milk", category: .dairy))

        XCTAssertNotNil(store.override(for: "Milk"))
        XCTAssertNil(store.override(for: "milk"))
    }

    func testSaveWithBlankNameIsIgnored() {
        // guard !key.isEmpty: whitespace-only names produce an empty key and are dropped.
        store.save(makeOverride(name: "   \n  "))

        XCTAssertNil(store.override(for: "   \n  "))
        XCTAssertNil(store.override(for: ""))
    }

    func testSaveOverwritesExistingOverrideForSameNormalizedKey() throws {
        saveTracked(makeOverride(name: "牛奶", category: .dairy, defaultShelfLifeDays: 7))
        saveTracked(makeOverride(name: " 牛奶 ", category: .beverage, defaultShelfLifeDays: 30))

        let fetched = try XCTUnwrap(store.override(for: "牛奶"))
        XCTAssertEqual(fetched.category, .beverage)
        XCTAssertEqual(fetched.defaultShelfLifeDays, 30)
    }

    // MARK: - removeOverride

    func testRemoveOverrideDeletesByNormalizedName() throws {
        saveTracked(makeOverride(name: "牛奶", category: .dairy))
        XCTAssertNotNil(store.override(for: "牛奶"))

        // Removal also normalizes its argument.
        store.removeOverride(for: "  牛奶  ")

        XCTAssertNil(store.override(for: "牛奶"))
    }

    // MARK: - isHidden

    func testIsHiddenTrueWhenOverrideHidden() {
        saveTracked(makeOverride(name: "草莓", category: .fruit, isHidden: true))
        XCTAssertTrue(store.isHidden("草莓"))
    }

    func testIsHiddenFalseWhenOverrideVisible() {
        saveTracked(makeOverride(name: "草莓", category: .fruit, isHidden: false))
        XCTAssertFalse(store.isHidden("草莓"))
    }

    func testIsHiddenFalseWhenNoOverride() {
        // No override at all -> nil?.isHidden == true is false.
        XCTAssertFalse(store.isHidden("不存在的食材"))
    }

    func testIsHiddenNormalizesName() {
        saveTracked(makeOverride(name: "草莓", isHidden: true))
        XCTAssertTrue(store.isHidden("  草莓 \n"))
    }

    // MARK: - applyOverrides(to:)

    func testApplyOverridesLeavesTemplatesWithoutOverridesUnchanged() {
        // No overrides saved: every common template passes through untouched.
        let result = store.applyOverrides(to: FoodTemplate.common)

        XCTAssertEqual(result.count, FoodTemplate.common.count)
        for (out, original) in zip(result, FoodTemplate.common) {
            XCTAssertEqual(out.name, original.name)
            XCTAssertEqual(out.category, original.category)
            XCTAssertEqual(out.storageZone, original.storageZone)
            XCTAssertEqual(out.customIcon, original.customIcon)
            XCTAssertEqual(out.defaultShelfLifeDays, original.defaultShelfLifeDays)
        }
    }

    func testApplyOverridesOverlaysMatchingTemplate() throws {
        // 牛奶 in common: dairy / fridge / 🥛 / 7 days. Override it.
        saveTracked(makeOverride(
            name: "牛奶",
            category: .beverage,
            storageZone: .pantry,
            customIcon: "🍼",
            defaultShelfLifeDays: 99,
            isHidden: false
        ))

        let result = store.applyOverrides(to: FoodTemplate.common)
        let milk = try XCTUnwrap(result.first { $0.normalizedName == "牛奶" })

        XCTAssertEqual(milk.category, .beverage)
        XCTAssertEqual(milk.storageZone, .pantry)
        XCTAssertEqual(milk.customIcon, "🍼")
        XCTAssertEqual(milk.defaultShelfLifeDays, 99)
        // Name is preserved by FoodTemplate.applying.
        XCTAssertEqual(milk.name, "牛奶")
        // Count unchanged (overlay, not drop).
        XCTAssertEqual(result.count, FoodTemplate.common.count)
    }

    func testApplyOverridesDropsHiddenTemplate() {
        saveTracked(makeOverride(name: "牛奶", category: .dairy, isHidden: true))

        let result = store.applyOverrides(to: FoodTemplate.common)

        XCTAssertFalse(result.contains { $0.normalizedName == "牛奶" })
        XCTAssertEqual(result.count, FoodTemplate.common.count - 1)
    }

    func testApplyOverridesOnlyAffectsMatchingNames() throws {
        // Hide 牛奶, overlay 鸡蛋, leave the rest alone.
        saveTracked(makeOverride(name: "牛奶", isHidden: true))
        saveTracked(makeOverride(name: "鸡蛋", category: .other, storageZone: .pantry, defaultShelfLifeDays: 1))

        let result = store.applyOverrides(to: FoodTemplate.common)

        XCTAssertFalse(result.contains { $0.normalizedName == "牛奶" })
        let egg = try XCTUnwrap(result.first { $0.normalizedName == "鸡蛋" })
        XCTAssertEqual(egg.category, .other)
        XCTAssertEqual(egg.defaultShelfLifeDays, 1)
        // 草莓 untouched.
        let berry = try XCTUnwrap(result.first { $0.normalizedName == "草莓" })
        XCTAssertEqual(berry.category, .fruit)
        XCTAssertEqual(berry.defaultShelfLifeDays, 3)
        // One dropped (牛奶), so count is one less.
        XCTAssertEqual(result.count, FoodTemplate.common.count - 1)
    }

    func testApplyOverridesEmptyInputReturnsEmpty() {
        saveTracked(makeOverride(name: "牛奶", isHidden: true))
        XCTAssertTrue(store.applyOverrides(to: []).isEmpty)
    }

    func testApplyOverridesMatchesTemplateNormalizedNameAcrossWhitespace() throws {
        // Template name carries whitespace; override saved under the trimmed key
        // must still match via template.normalizedName.
        let padded = FoodTemplate(
            name: "  自定义 ",
            category: .other,
            storageZone: .pantry,
            customIcon: nil,
            defaultShelfLifeDays: 4,
            quantity: nil,
            notes: nil,
            purchaseDate: nil
        )
        saveTracked(makeOverride(name: "自定义", category: .snack, defaultShelfLifeDays: 12))

        let result = store.applyOverrides(to: [padded])
        let overlaid = try XCTUnwrap(result.first)
        XCTAssertEqual(overlaid.category, .snack)
        XCTAssertEqual(overlaid.defaultShelfLifeDays, 12)
        XCTAssertEqual(overlaid.name, "  自定义 ") // name preserved verbatim
    }

    // MARK: - template(for:from:)

    func testTemplateFromTemplatesReturnsOverlaidMatch() throws {
        saveTracked(makeOverride(name: "草莓", category: .other, storageZone: .pantry, customIcon: "🫐", defaultShelfLifeDays: 2))

        let template = try XCTUnwrap(store.template(for: "草莓", from: FoodTemplate.common))

        XCTAssertEqual(template.name, "草莓")
        XCTAssertEqual(template.category, .other)
        XCTAssertEqual(template.storageZone, .pantry)
        XCTAssertEqual(template.customIcon, "🫐")
        XCTAssertEqual(template.defaultShelfLifeDays, 2)
    }

    func testTemplateFromTemplatesReturnsUnmodifiedWhenNoOverride() throws {
        // No override -> applying(nil) returns the matched template unchanged.
        let template = try XCTUnwrap(store.template(for: "草莓", from: FoodTemplate.common))

        XCTAssertEqual(template.category, .fruit)
        XCTAssertEqual(template.storageZone, .fridge)
        XCTAssertEqual(template.customIcon, "🍓")
        XCTAssertEqual(template.defaultShelfLifeDays, 3)
    }

    func testTemplateFromTemplatesNormalizesQueryName() throws {
        let template = try XCTUnwrap(store.template(for: "  草莓 \n", from: FoodTemplate.common))
        XCTAssertEqual(template.name, "草莓")
    }

    func testTemplateFromTemplatesReturnsNilForBlankName() {
        XCTAssertNil(store.template(for: "   ", from: FoodTemplate.common))
        XCTAssertNil(store.template(for: "", from: FoodTemplate.common))
    }

    func testTemplateFromTemplatesReturnsNilWhenHidden() {
        saveTracked(makeOverride(name: "草莓", isHidden: true))
        XCTAssertNil(store.template(for: "草莓", from: FoodTemplate.common))
    }

    func testTemplateFromTemplatesReturnsNilWhenNoMatchingTemplate() {
        // Name has no override and no matching template in the list.
        XCTAssertNil(store.template(for: "不存在的食材", from: FoodTemplate.common))
    }
}