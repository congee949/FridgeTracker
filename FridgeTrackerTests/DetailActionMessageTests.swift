import XCTest
@testable import FridgeTracker

/// 详情页确认弹窗文案的模式分流：计数数量沿用「减 1 份」，
/// 自由文本数量必须明说「移除整项」，不能误导用户以为会按份递减。
final class DetailActionMessageTests: XCTestCase {

    func testConsumeMessageForCountableQuantityKeepsPerUnitWording() {
        let message = DetailAction.consumed.message(for: "牛奶", verb: "喝", hasFreeTextQuantity: false)
        XCTAssertTrue(message.contains("喝掉 1 份"))
        XCTAssertFalse(message.contains("自由文本"))
    }

    func testConsumeMessageForFreeTextQuantityStatesWholeItemRemoval() {
        let message = DetailAction.consumed.message(for: "牛奶", verb: "喝", hasFreeTextQuantity: true)
        XCTAssertTrue(message.contains("自由文本"))
        XCTAssertTrue(message.contains("整项"))
    }

    func testDiscardMessageForFreeTextQuantityStatesWholeItemRemoval() {
        let message = DetailAction.discarded.message(for: "面粉", verb: "吃", hasFreeTextQuantity: true)
        XCTAssertTrue(message.contains("自由文本"))
        XCTAssertTrue(message.contains("整项"))
    }

    func testDeleteMessageUnaffectedByQuantityMode() {
        let countable = DetailAction.delete.message(for: "牛奶", verb: "喝", hasFreeTextQuantity: false)
        let freeText = DetailAction.delete.message(for: "牛奶", verb: "喝", hasFreeTextQuantity: true)
        XCTAssertEqual(countable, freeText)
    }
}
