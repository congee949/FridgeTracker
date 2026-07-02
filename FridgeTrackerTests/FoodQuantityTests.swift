import XCTest
import SwiftData
@testable import FridgeTracker

/// Regression baseline for the `FoodQuantity` value type and the `FoodItem`
/// quantity helpers (`reduceQuantityByOne()` / `mergeQuantity(from:)`).
///
/// These tests pin the *current* behavior of the parser and arithmetic exactly
/// as implemented in `FridgeTracker/Models/FoodItem.swift`. Where a behavior
/// looks questionable it is still asserted as-is and flagged separately.
@MainActor
final class FoodQuantityTests: XCTestCase {

    // MARK: - parse: success cases

    func testParseSingleNumberWithUnit() throws {
        let quantity = try XCTUnwrap(FoodQuantity.parse("3袋"))
        XCTAssertEqual(quantity.current, 3)
        XCTAssertEqual(quantity.total, 3)
        XCTAssertEqual(quantity.unit, "袋")
    }

    func testParseCurrentOverTotalWithUnit() throws {
        let quantity = try XCTUnwrap(FoodQuantity.parse("2/5袋"))
        XCTAssertEqual(quantity.current, 2)
        XCTAssertEqual(quantity.total, 5)
        XCTAssertEqual(quantity.unit, "袋")
    }

    func testParseBareNumberDefaultsUnitToGe() throws {
        // No unit suffix -> normalizedUnit returns "个".
        let quantity = try XCTUnwrap(FoodQuantity.parse("4"))
        XCTAssertEqual(quantity.current, 4)
        XCTAssertEqual(quantity.total, 4)
        XCTAssertEqual(quantity.unit, "个")
    }

    func testParseFractionWithoutUnitDefaultsToGe() throws {
        let quantity = try XCTUnwrap(FoodQuantity.parse("1/3"))
        XCTAssertEqual(quantity.current, 1)
        XCTAssertEqual(quantity.total, 3)
        XCTAssertEqual(quantity.unit, "个")
    }

    func testParseEqualCurrentAndTotalFraction() throws {
        // total == current is allowed (total >= current).
        let quantity = try XCTUnwrap(FoodQuantity.parse("3/3瓶"))
        XCTAssertEqual(quantity.current, 3)
        XCTAssertEqual(quantity.total, 3)
        XCTAssertEqual(quantity.unit, "瓶")
    }

    func testParseTrimsSurroundingWhitespace() throws {
        // Leading/trailing whitespace is trimmed before parsing the number.
        let quantity = try XCTUnwrap(FoodQuantity.parse("  5瓶  "))
        XCTAssertEqual(quantity.current, 5)
        XCTAssertEqual(quantity.total, 5)
        XCTAssertEqual(quantity.unit, "瓶")
    }

    func testParseTrimsWhitespaceInsideUnit() throws {
        // The unit substring is itself trimmed by normalizedUnit.
        let quantity = try XCTUnwrap(FoodQuantity.parse("2 盒"))
        XCTAssertEqual(quantity.current, 2)
        XCTAssertEqual(quantity.total, 2)
        XCTAssertEqual(quantity.unit, "盒")
    }

    func testParseMultiDigitNumbers() throws {
        let quantity = try XCTUnwrap(FoodQuantity.parse("10/12个"))
        XCTAssertEqual(quantity.current, 10)
        XCTAssertEqual(quantity.total, 12)
        XCTAssertEqual(quantity.unit, "个")
    }

    func testParseStopsUnitAtTrailingText() throws {
        // Everything after the (second) number is the unit, verbatim after trim.
        let quantity = try XCTUnwrap(FoodQuantity.parse("1/2大瓶"))
        XCTAssertEqual(quantity.current, 1)
        XCTAssertEqual(quantity.total, 2)
        XCTAssertEqual(quantity.unit, "大瓶")
    }

    // MARK: - parse: nil cases

    func testParseNilInput() {
        XCTAssertNil(FoodQuantity.parse(nil))
    }

    func testParseEmptyStringIsNil() {
        XCTAssertNil(FoodQuantity.parse(""))
    }

    func testParseWhitespaceOnlyIsNil() {
        XCTAssertNil(FoodQuantity.parse("   "))
    }

    func testParseZeroCurrentIsNil() {
        // current must be > 0; "0..." reads value 0 -> nil.
        XCTAssertNil(FoodQuantity.parse("0个"))
        XCTAssertNil(FoodQuantity.parse("0/5个"))
    }

    func testParseTotalLessThanCurrentIsNil() {
        // total >= current is required.
        XCTAssertNil(FoodQuantity.parse("5/3个"))
    }

    func testParseNonAsciiNumberWordIsNil() {
        // "半袋" begins with a non-numeric CJK char -> no leading digits -> nil.
        XCTAssertNil(FoodQuantity.parse("半袋"))
    }

    func testParsePureLettersIsNil() {
        XCTAssertNil(FoodQuantity.parse("abc"))
    }

    func testParseLeadingUnitBeforeNumberIsNil() {
        // Parser only reads digits from the start; a leading non-digit -> nil.
        XCTAssertNil(FoodQuantity.parse("袋3"))
    }

    // MARK: - displayText / storageText

    func testDisplayTextEqualCurrentAndTotal() {
        let quantity = FoodQuantity(current: 3, total: 3, unit: "袋")
        XCTAssertEqual(quantity.displayText, "3袋")
        // storageText delegates to displayText.
        XCTAssertEqual(quantity.storageText, "3袋")
    }

    func testDisplayTextPartial() {
        let quantity = FoodQuantity(current: 2, total: 5, unit: "袋")
        XCTAssertEqual(quantity.displayText, "2/5袋")
        XCTAssertEqual(quantity.storageText, "2/5袋")
    }

    // MARK: - reducedByOne

    func testReducedByOneFromMultiUnit() throws {
        let quantity = FoodQuantity(current: 3, total: 5, unit: "袋")
        let reduced = try XCTUnwrap(quantity.reducedByOne())
        XCTAssertEqual(reduced.current, 2)
        XCTAssertEqual(reduced.total, 5)
        XCTAssertEqual(reduced.unit, "袋")
    }

    func testReducedByOneReturnsNilAtLastUnit() {
        // current == 1 is the last unit; guard current > 1 fails -> nil.
        let quantity = FoodQuantity(current: 1, total: 5, unit: "袋")
        XCTAssertNil(quantity.reducedByOne())
    }

    // MARK: - adding

    func testAddingCombinesCurrentAndTotalSeparately() {
        // newCurrent = current + other.current; newTotal = total + other.total.
        let base = FoodQuantity(current: 2, total: 5, unit: "袋")
        let other = FoodQuantity(current: 3, total: 3, unit: "袋")
        let sum = base.adding(other)
        XCTAssertEqual(sum.current, 5)
        XCTAssertEqual(sum.total, 8)
        XCTAssertEqual(sum.unit, "袋")
        XCTAssertEqual(sum.displayText, "5/8袋")
    }

    func testAddingKeepsReceiverUnitAndIgnoresOtherUnit() {
        // adding() never inspects other.unit; it keeps the receiver's unit.
        let base = FoodQuantity(current: 1, total: 1, unit: "瓶")
        let other = FoodQuantity(current: 2, total: 2, unit: "盒")
        let sum = base.adding(other)
        XCTAssertEqual(sum.current, 3)
        XCTAssertEqual(sum.total, 3)
        XCTAssertEqual(sum.unit, "瓶")
        XCTAssertEqual(sum.displayText, "3瓶")
    }

    // MARK: - FoodItem.reduceQuantityByOne()

    /// Builds a FoodItem with a given quantity string. Requires the main actor
    /// because FoodItem is a SwiftData @Model. The container is created so the
    /// schema is realized, matching how the rest of the suite operates.
    private func makeItem(quantity: String?) throws -> FoodItem {
        _ = try TestModelContainer.make()
        return FoodItem(
            name: "测试食材",
            category: .other,
            storageZone: .fridge,
            expiryDate: Date(),
            quantity: quantity
        )
    }

    func testReduceQuantityByOneReturnsTrueForNilQuantity() throws {
        // parse(nil) -> nil -> early return true; quantity stays nil.
        let item = try makeItem(quantity: nil)
        XCTAssertTrue(item.reduceQuantityByOne())
        XCTAssertNil(item.quantity)
    }

    func testReduceQuantityByOneReturnsTrueForUnparseableQuantity() throws {
        // Unparseable -> parse returns nil -> returns true; quantity unchanged.
        let item = try makeItem(quantity: "半袋")
        XCTAssertTrue(item.reduceQuantityByOne())
        XCTAssertEqual(item.quantity, "半袋")
    }

    func testReduceQuantityByOneReturnsTrueForSingleLastUnit() throws {
        // Parses to current == 1 -> reducedByOne() nil -> returns true; unchanged.
        let item = try makeItem(quantity: "1袋")
        XCTAssertTrue(item.reduceQuantityByOne())
        XCTAssertEqual(item.quantity, "1袋")
    }

    func testReduceQuantityByOneDecrementsMultiUnitAndReturnsFalse() throws {
        let item = try makeItem(quantity: "3/5袋")
        XCTAssertFalse(item.reduceQuantityByOne())
        XCTAssertEqual(item.quantity, "2/5袋")
    }

    func testReduceQuantityByOneFromEqualPairDropsToPartial() throws {
        // "3袋" parses as current == total == 3; after reduce -> 2/3袋.
        let item = try makeItem(quantity: "3袋")
        XCTAssertFalse(item.reduceQuantityByOne())
        XCTAssertEqual(item.quantity, "2/3袋")
    }

    // MARK: - FoodItem.mergeQuantity(from:)

    func testMergeQuantitySameUnitSucceeds() throws {
        let item = try makeItem(quantity: "2/5袋")
        XCTAssertTrue(item.mergeQuantity(from: "3袋"))
        // current 2+3 = 5, total 5+3 = 8.
        XCTAssertEqual(item.quantity, "5/8袋")
    }

    func testMergeQuantityDifferentUnitFails() throws {
        let item = try makeItem(quantity: "2袋")
        XCTAssertFalse(item.mergeQuantity(from: "1瓶"))
        // Units differ -> no change.
        XCTAssertEqual(item.quantity, "2袋")
    }

    func testMergeQuantityUnparseableAddedFails() throws {
        let item = try makeItem(quantity: "2袋")
        XCTAssertFalse(item.mergeQuantity(from: "半袋"))
        XCTAssertEqual(item.quantity, "2袋")
    }

    func testMergeQuantityUnparseableExistingFails() throws {
        let item = try makeItem(quantity: "半袋")
        XCTAssertFalse(item.mergeQuantity(from: "3袋"))
        XCTAssertEqual(item.quantity, "半袋")
    }

    func testMergeQuantityNilExistingFails() throws {
        let item = try makeItem(quantity: nil)
        XCTAssertFalse(item.mergeQuantity(from: "3袋"))
        XCTAssertNil(item.quantity)
    }

    // MARK: - FoodItem.hasCountableQuantity (计数 vs 自由文本两种模式)

    func testHasCountableQuantityTrueForParseableQuantities() throws {
        XCTAssertTrue(try makeItem(quantity: "3袋").hasCountableQuantity)
        XCTAssertTrue(try makeItem(quantity: "2/5盒").hasCountableQuantity)
        XCTAssertTrue(try makeItem(quantity: "4").hasCountableQuantity)
    }

    func testHasCountableQuantityFalseForFreeTextQuantities() throws {
        // 小数、汉字数量、纯文字都是自由文本：仅展示，消耗时整项移除。
        XCTAssertFalse(try makeItem(quantity: "半盒").hasCountableQuantity)
        XCTAssertFalse(try makeItem(quantity: "0.5kg").hasCountableQuantity)
        XCTAssertFalse(try makeItem(quantity: "一点点").hasCountableQuantity)
    }

    func testHasCountableQuantityFalseForNilQuantity() throws {
        XCTAssertFalse(try makeItem(quantity: nil).hasCountableQuantity)
    }
}
