import Foundation

struct PackagingOCRResult {
    let nameCandidates: [String]
    let expiryDate: Date?
    let rawText: String
}

/// OCR 识别日期的合理性预警：过去的日期多半是生产日期误读，太远的未来日期多半是批号/条码误读。
/// 只提示不拦截，是否应用由确认页的用户决定。
enum PackagingDateSanity {
    static let maxReasonableYearsAhead = 2

    static func warning(for date: Date, relativeTo now: Date = Date(), calendar: Calendar = .current) -> String? {
        let calendar = PackagingTextParser.gregorianCalendar(in: calendar.timeZone)
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if day < today {
            return "识别到的日期已是过去，可能是生产日期或批号，请核对包装"
        }
        if let limit = calendar.date(byAdding: .year, value: maxReasonableYearsAhead, to: today), day > limit {
            return "识别到的日期在 \(maxReasonableYearsAhead) 年以后，可能是批号或误读，请核对包装"
        }
        return nil
    }

    /// 确认页「填入表单」时是否应用当前日期：
    /// 未识别到日期时始终放行（此时日期只是表单回填值，是否真正写入由表单侧按有无改动判断）；
    /// 识别到且异常时需要用户显式确认。
    static func shouldApplyDate(recognized: Bool, warning: String?, userConfirmed: Bool) -> Bool {
        guard recognized else { return true }
        return warning == nil || userConfirmed
    }
}

struct PackagingTextParser {
    // 容忍「保质期：12个月」「保质期，12个月」等常见标点写法
    private static let shelfLifeRegex = try? NSRegularExpression(pattern: #"保质期[：:，,、]?\s*(\d+)\s*(天|日|个月|月)"#)
    private static let dateRegex = try? NSRegularExpression(pattern: #"(20\d{2})[.\-/年](\d{1,2})[.\-/月](\d{1,2})日?"#)
    // 喷码常见的无分隔紧凑格式：20251201（前后不能再有数字，避免命中条码/批号片段）
    private static let compactDateRegex = try? NSRegularExpression(pattern: #"(?<!\d)(20\d{2})(1[0-2]|0[1-9])(3[01]|[12]\d|0[1-9])(?!\d)"#)

    static func parse(lines: [String], calendar: Calendar = .current) -> PackagingOCRResult {
        let calendar = gregorianCalendar(in: calendar.timeZone)
        let normalizedLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let rawText = normalizedLines.joined(separator: "\n")

        return PackagingOCRResult(
            nameCandidates: nameCandidates(from: normalizedLines),
            expiryDate: expiryDate(from: normalizedLines, calendar: calendar),
            rawText: rawText
        )
    }

    static func expiryDate(from lines: [String], calendar: Calendar = .current) -> Date? {
        let calendar = gregorianCalendar(in: calendar.timeZone)
        let directKeywords = ["保质期至", "有效期至", "最佳食用日期", "到期日", "EXP"]
        for line in lines where directKeywords.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
            if let date = firstDate(in: line, calendar: calendar) {
                return date
            }
        }

        let text = lines.joined(separator: "，")
        if let productionDate = productionDate(in: text, calendar: calendar),
           let shelfLife = shelfLife(in: text) {
            return calendar.date(byAdding: shelfLife.component, value: shelfLife.value, to: productionDate)
        }

        return nil
    }

    static func nameCandidates(from lines: [String]) -> [String] {
        let blockedKeywords = [
            "营养成分表", "配料", "生产日期", "保质期", "有效期", "净含量", "执行标准", "许可证编号", "贮存条件", "储存条件", "厂家", "地址", "电话", "能量", "蛋白质", "脂肪", "碳水化合物", "钠"
        ]

        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard line.count >= 2, line.count <= 24 else { return false }
                guard !blockedKeywords.contains(where: { line.contains($0) }) else { return false }
                guard firstDate(in: line) == nil else { return false }
                guard line.range(of: #"^[0-9\s\-./条码:：]+$"#, options: .regularExpression) == nil else { return false }
                return line.contains { $0.isChinese || $0.isLetter }
            }
            .sorted { lhs, rhs in
                let lhsScore = nameScore(lhs)
                let rhsScore = nameScore(rhs)
                if lhsScore == rhsScore { return lhs.count < rhs.count }
                return lhsScore > rhsScore
            }
            .prefix(3)
            .map { String($0) }
    }

    private static func productionDate(in text: String, calendar: Calendar) -> Date? {
        guard let keywordRange = text.range(of: "生产日期") else { return nil }
        return firstDate(in: String(text[keywordRange.lowerBound...]), calendar: calendar)
    }

    private static func shelfLife(in text: String) -> (component: Calendar.Component, value: Int)? {
        guard let match = firstMatch(shelfLifeRegex, in: text), match.numberOfRanges >= 3,
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Int(text[valueRange]) else {
            return nil
        }

        let unit = String(text[unitRange])
        if unit == "个月" || unit == "月" {
            return (.month, value)
        }
        return (.day, value)
    }

    private static func firstDate(in text: String, calendar: Calendar = .current) -> Date? {
        firstValidDate(matching: dateRegex, in: text, calendar: calendar)
            ?? firstValidDate(matching: compactDateRegex, in: text, calendar: calendar)
    }

    /// 逐个候选校验合法性：OCR 误读出的「2025-13-45」要被拒绝，
    /// 而不是被 Calendar 翻滚成下一年的某天写进保质期。
    private static func firstValidDate(matching regex: NSRegularExpression?, in text: String, calendar: Calendar) -> Date? {
        guard let regex else { return nil }
        let fullRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: fullRange) where match.numberOfRanges >= 4 {
            guard let yearRange = Range(match.range(at: 1), in: text),
                  let monthRange = Range(match.range(at: 2), in: text),
                  let dayRange = Range(match.range(at: 3), in: text),
                  let year = Int(text[yearRange]),
                  let month = Int(text[monthRange]),
                  let day = Int(text[dayRange]) else {
                continue
            }
            let components = DateComponents(year: year, month: month, day: day)
            guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else {
                continue
            }
            return date
        }
        return nil
    }

    private static func firstMatch(_ regex: NSRegularExpression?, in text: String) -> NSTextCheckingResult? {
        guard let regex else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func nameScore(_ line: String) -> Int {
        let chineseCount = line.filter(\.isChinese).count
        let letterCount = line.filter(\.isLetter).count
        let digitCount = line.filter(\.isNumber).count
        return chineseCount * 3 + letterCount - digitCount * 2 - abs(line.count - 6)
    }

    /// 包装上的 20xx 年月日是公历民用日期；设备选择佛历、日历等系统日历时也不能改变其含义。
    static func gregorianCalendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}

private extension Character {
    var isChinese: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    var isLetter: Bool {
        unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    var isNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }
}
