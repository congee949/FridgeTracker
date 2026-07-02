import XCTest
@testable import FridgeTracker

/// `PackagingDateSanity.warning(for:)` 的边界基线：
/// 过去日期（多半是生产日期/批号误读）与超过 2 年的未来日期要出警告，正常范围不打扰。
/// 全部用固定的 `relativeTo` 参考时间，结果与真实当前日期无关。
final class PackagingDateSanityTests: XCTestCase {

    private let calendar = Calendar.current
    private lazy var referenceNow: Date = {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 15))!
    }()

    private func day(offsetDays: Int = 0, offsetYears: Int = 0) -> Date {
        var date = calendar.startOfDay(for: referenceNow)
        if offsetYears != 0 {
            date = calendar.date(byAdding: .year, value: offsetYears, to: date)!
        }
        if offsetDays != 0 {
            date = calendar.date(byAdding: .day, value: offsetDays, to: date)!
        }
        return date
    }

    // MARK: - 过去日期

    func testYesterdayProducesPastWarning() {
        let warning = PackagingDateSanity.warning(for: day(offsetDays: -1), relativeTo: referenceNow, calendar: calendar)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("过去") == true)
    }

    func testFarPastProducesPastWarning() {
        let warning = PackagingDateSanity.warning(for: day(offsetYears: -3), relativeTo: referenceNow, calendar: calendar)
        XCTAssertTrue(warning?.contains("过去") == true)
    }

    // MARK: - 正常范围

    func testTodayProducesNoWarning() {
        // 「今天过期」合法（当天买当天到期的临期食品）。
        XCTAssertNil(PackagingDateSanity.warning(for: referenceNow, relativeTo: referenceNow, calendar: calendar))
    }

    func testTomorrowProducesNoWarning() {
        XCTAssertNil(PackagingDateSanity.warning(for: day(offsetDays: 1), relativeTo: referenceNow, calendar: calendar))
    }

    func testExactlyTwoYearsAheadProducesNoWarning() {
        // 恰好 2 年是边界内（day > limit 为严格大于）。
        XCTAssertNil(PackagingDateSanity.warning(for: day(offsetYears: 2), relativeTo: referenceNow, calendar: calendar))
    }

    // MARK: - 超远未来

    func testTwoYearsPlusOneDayProducesFutureWarning() {
        let warning = PackagingDateSanity.warning(for: day(offsetDays: 1, offsetYears: 2), relativeTo: referenceNow, calendar: calendar)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("以后") == true)
    }

    func testTenYearsAheadProducesFutureWarning() {
        let warning = PackagingDateSanity.warning(for: day(offsetYears: 10), relativeTo: referenceNow, calendar: calendar)
        XCTAssertTrue(warning?.contains("以后") == true)
    }

    // MARK: - shouldApplyDate 真值表（确认页「填入表单」的应用决策）

    func testShouldApplyDateAlwaysTrueWhenNotRecognized() {
        // 未识别到日期：放行（写回表单回填值是 no-op，是否真正写入由表单侧判断改动）。
        XCTAssertTrue(PackagingDateSanity.shouldApplyDate(recognized: false, warning: nil, userConfirmed: false))
        XCTAssertTrue(PackagingDateSanity.shouldApplyDate(recognized: false, warning: "任意警告", userConfirmed: false))
    }

    func testShouldApplyDateTrueWhenRecognizedWithoutWarning() {
        XCTAssertTrue(PackagingDateSanity.shouldApplyDate(recognized: true, warning: nil, userConfirmed: false))
        XCTAssertTrue(PackagingDateSanity.shouldApplyDate(recognized: true, warning: nil, userConfirmed: true))
    }

    func testShouldApplyDateRequiresConfirmationWhenRecognizedWithWarning() {
        // 异常识别日期默认不应用，用户显式打开开关才应用——本批 P0 修复的核心决策。
        XCTAssertFalse(PackagingDateSanity.shouldApplyDate(recognized: true, warning: "异常", userConfirmed: false))
        XCTAssertTrue(PackagingDateSanity.shouldApplyDate(recognized: true, warning: "异常", userConfirmed: true))
    }
}
