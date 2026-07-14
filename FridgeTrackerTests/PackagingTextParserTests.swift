import XCTest
@testable import FridgeTracker

/// Regression baseline for `PackagingTextParser`, the OCR post-processor that turns recognized
/// packaging text lines into an expiry date and a short list of product-name candidates.
///
/// All date assertions pass an explicit `Calendar(identifier: .gregorian)` so results do not
/// depend on the host locale/timezone, and dates are compared by calendar components.
/// Expected values were derived by tracing `PackagingTextParser.swift` and confirmed against the
/// real regex/`DateComponents` behavior.
final class PackagingTextParserTests: XCTestCase {

    private let gregorian = Calendar(identifier: .gregorian)

    private func assertSameDay(
        _ date: Date?,
        year: Int,
        month: Int,
        day: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let date = try XCTUnwrap(date, "expected a parsed date but got nil", file: file, line: line)
        let comps = gregorian.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(comps.year, year, "year", file: file, line: line)
        XCTAssertEqual(comps.month, month, "month", file: file, line: line)
        XCTAssertEqual(comps.day, day, "day", file: file, line: line)
    }

    // MARK: - Direct expiry keywords

    func testDirectKeywordExpiryAtYieldsDate() throws {
        // 保质期至 + a dotted date -> that exact date.
        let date = PackagingTextParser.expiryDate(from: ["保质期至2025.12.31"], calendar: gregorian)
        try assertSameDay(date, year: 2025, month: 12, day: 31)
    }

    func testDirectKeywordYouXiaoQiZhiYieldsDate() throws {
        // 有效期至 with 年/月 separators and a trailing 日.
        let date = PackagingTextParser.expiryDate(from: ["有效期至2026年03月08日"], calendar: gregorian)
        try assertSameDay(date, year: 2026, month: 3, day: 8)
    }

    func testExpKeywordIsCaseInsensitive() throws {
        // "EXP" is matched via localizedCaseInsensitiveContains, so lowercase "exp" still triggers it.
        let date = PackagingTextParser.expiryDate(from: ["exp 2026-01-15"], calendar: gregorian)
        try assertSameDay(date, year: 2026, month: 1, day: 15)
    }

    // MARK: - Production date + shelf life arithmetic

    func testProductionDatePlusShelfLifeInMonths() throws {
        // 生产日期 2025.01.01 + 保质期 12 个月 -> add 12 months.
        let lines = ["生产日期2025.01.01", "保质期12个月"]
        let date = PackagingTextParser.expiryDate(from: lines, calendar: gregorian)
        try assertSameDay(date, year: 2026, month: 1, day: 1)
    }

    func testProductionDatePlusShelfLifeInSingleCharMonthUnit() throws {
        // The unit "月" (not just "个月") also maps to Calendar.Component.month.
        let lines = ["生产日期：2025.03.10", "保质期6月"]
        let date = PackagingTextParser.expiryDate(from: lines, calendar: gregorian)
        try assertSameDay(date, year: 2025, month: 9, day: 10)
    }

    func testProductionDatePlusShelfLifeInDays() throws {
        // 生产日期 2025.06.15 + 保质期 30 天 -> add 30 days -> 2025-07-15.
        let lines = ["生产日期：2025.06.15", "保质期30天"]
        let date = PackagingTextParser.expiryDate(from: lines, calendar: gregorian)
        try assertSameDay(date, year: 2025, month: 7, day: 15)
    }

    func testProductionDatePlusShelfLifeWithRiUnit() throws {
        // The unit "日" maps to days, same as "天".
        let lines = ["生产日期2025.06.15", "保质期10日"]
        let date = PackagingTextParser.expiryDate(from: lines, calendar: gregorian)
        try assertSameDay(date, year: 2025, month: 6, day: 25)
    }

    // MARK: - Compact yyyymmdd format

    func testCompactYyyymmddUnderDirectKeyword() throws {
        // The dotted dateRegex needs separators and fails on "20251201"; the compactDateRegex then
        // matches the separator-less ink-jet style date.
        let date = PackagingTextParser.expiryDate(from: ["保质期至20251201"], calendar: gregorian)
        try assertSameDay(date, year: 2025, month: 12, day: 1)
    }

    // MARK: - Rejection of invalid / non-fabricated dates

    func testInvalidOcrDateIsRejected() throws {
        // 2025-13-45 matches the date regex shape but is not a valid calendar date, so it is rejected
        // rather than rolled over into a different (fabricated) date.
        let date = PackagingTextParser.expiryDate(from: ["保质期至2025-13-45"], calendar: gregorian)
        XCTAssertNil(date)
    }

    func testCompactDateGuardRejectsBarcodeFragment() throws {
        // The compact regex uses (?<!\d)/(?!\d) boundaries, so a date-like run embedded in a longer
        // digit string (batch/barcode) is not extracted.
        let date = PackagingTextParser.expiryDate(from: ["保质期至6920211201"], calendar: gregorian)
        XCTAssertNil(date)
    }

    func testShelfLifeWithoutProductionDateDoesNotFabricate() throws {
        // Only a shelf-life duration is present (no direct "...至" date and no 生产日期 anchor),
        // so there is nothing to add the duration to -> nil, not a fabricated date.
        let date = PackagingTextParser.expiryDate(from: ["保质期12个月"], calendar: gregorian)
        XCTAssertNil(date)
    }

    func testNoDateAtAllReturnsNil() throws {
        // Ambiguous, date-free lines never produce a date.
        let date = PackagingTextParser.expiryDate(from: ["蒙牛纯牛奶", "净含量250ml"], calendar: gregorian)
        XCTAssertNil(date)
    }

    func testRangeUnderKeywordReturnsFirstMatchedDate() throws {
        // CURRENT behavior: a "from-to" range under a direct keyword does NOT abstain; the parser
        // returns the first matched valid date (the range start), not the end. Pinned as-is; see
        // suspectedBugs — for an expiry keyword the later bound would be the safer choice.
        let date = PackagingTextParser.expiryDate(from: ["保质期至2025.01.01-2025.12.31"], calendar: gregorian)
        try assertSameDay(date, year: 2025, month: 1, day: 1)
    }

    // MARK: - parse(lines:) wiring

    func testParsePopulatesAllFields() throws {
        let lines = ["  蒙牛纯牛奶  ", "", "保质期至2025.12.31"]
        let result = PackagingTextParser.parse(lines: lines, calendar: gregorian)

        // rawText: trimmed, empty lines dropped, joined by newline.
        XCTAssertEqual(result.rawText, "蒙牛纯牛奶\n保质期至2025.12.31")
        try assertSameDay(result.expiryDate, year: 2025, month: 12, day: 31)
        XCTAssertEqual(result.nameCandidates, ["蒙牛纯牛奶"])
    }

    func testExplicitGregorianYearIsNotReinterpretedByBuddhistDeviceCalendar() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(secondsFromGMT: 0)!

        let date = PackagingTextParser.expiryDate(from: ["保质期至2026-07-14"], calendar: buddhist)

        var verificationCalendar = Calendar(identifier: .gregorian)
        verificationCalendar.timeZone = buddhist.timeZone
        let parsedDate = try XCTUnwrap(date)
        let components = verificationCalendar.dateComponents([.year, .month, .day], from: parsedDate)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 14)
    }

    // MARK: - nameCandidates filtering & ordering

    func testNameCandidatesExcludesBlockedAndNumericLines() {
        let lines = [
            "蒙牛纯牛奶",        // plausible product name -> kept
            "配料表：生牛乳",     // blocked keyword 配料
            "净含量500g",        // blocked keyword 净含量
            "保质期至2026.01.01", // blocked keyword 保质期 (and a date)
            "6921168509256",     // pure number / barcode line
            "2025.01.01",        // date-only line
            "X"                  // too short (count < 2)
        ]
        let names = PackagingTextParser.nameCandidates(from: lines)
        XCTAssertEqual(names, ["蒙牛纯牛奶"])
    }

    func testNameCandidatesSortsByScoreAndCapsAtThree() {
        // Four valid candidates; only the top three by nameScore survive (酸奶 has the lowest score
        // and is dropped). Ordering is score-descending.
        let lines = ["特仑苏有机纯牛奶", "巧克力味饼干", "蒙牛纯牛奶", "酸奶"]
        let names = PackagingTextParser.nameCandidates(from: lines)
        XCTAssertEqual(names, ["特仑苏有机纯牛奶", "巧克力味饼干", "蒙牛纯牛奶"])
        XCTAssertEqual(names.count, 3)
        XCTAssertFalse(names.contains("酸奶"))
    }

    func testNameCandidatesRejectsTooLongLine() {
        // Lines longer than 24 characters are excluded (here 25 Chinese characters).
        let tooLong = String(repeating: "牛", count: 25)
        XCTAssertFalse(PackagingTextParser.nameCandidates(from: [tooLong]).contains(tooLong))
    }
}
