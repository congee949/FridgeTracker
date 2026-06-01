import Foundation

struct PackagingOCRResult {
    let nameCandidates: [String]
    let expiryDate: Date?
    let rawText: String
}

struct PackagingTextParser {
    private static let shelfLifeRegex = try? NSRegularExpression(pattern: #"保质期\s*(\d+)\s*(天|日|个月|月)"#)
    private static let dateRegex = try? NSRegularExpression(pattern: #"(20\d{2})[.\-/年](\d{1,2})[.\-/月](\d{1,2})日?"#)

    static func parse(lines: [String], calendar: Calendar = .current) -> PackagingOCRResult {
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
        guard let match = firstMatch(dateRegex, in: text), match.numberOfRanges >= 4,
              let yearRange = Range(match.range(at: 1), in: text),
              let monthRange = Range(match.range(at: 2), in: text),
              let dayRange = Range(match.range(at: 3), in: text),
              let year = Int(text[yearRange]),
              let month = Int(text[monthRange]),
              let day = Int(text[dayRange]) else {
            return nil
        }

        return calendar.date(from: DateComponents(year: year, month: month, day: day))
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
