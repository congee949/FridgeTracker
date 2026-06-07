import Foundation
import SwiftUI

// ⚠️ 跨 target 共享契约 —— 本文件同时编译进 FridgeTracker(app) 与 FridgeTrackerWidget(extension)
// 两个 target（project.pbxproj 中有两条 PBXBuildFile 指向同一个 fileRef）。
// 它承载 app ↔ widget 的全部共享约定：ExpiringFoodSnapshot 数据结构、App Group 标识、
// 快照文件 URL、JSON 编解码器，以及 expiryStatusText / expiryStatusColor 展示辅助。
// 修改时请勿移除任一 target 的 membership，否则 widget 或 app 会因找不到符号而编译失败。
let fridgeTrackerAppGroupIdentifier = "group.com.congee.FridgeTracker"
let expiringFoodsSnapshotFileName = "expiring-foods.json"

func expiryStatusText(daysUntilExpiry days: Int) -> String {
    if days < 0 { return "已过期 \(-days) 天" }
    if days == 0 { return "今天过期" }
    return "\(days) 天后过期"
}

func expiryStatusColor(daysUntilExpiry days: Int) -> Color {
    if days < 0 { return .red }
    if days <= 3 { return .orange }
    return .green
}

struct ExpiringFoodSnapshot: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let category: String
    let categoryIcon: String
    let displayIcon: String
    let storageZone: String
    let storageIcon: String
    let expiryDate: Date
    let daysUntilExpiry: Int

    var currentDaysUntilExpiry: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: expiryDate)).day ?? daysUntilExpiry
    }

    var expiryText: String {
        expiryStatusText(daysUntilExpiry: currentDaysUntilExpiry)
    }
}

extension FileManager {
    var expiringFoodsSnapshotURL: URL? {
        containerURL(forSecurityApplicationGroupIdentifier: fridgeTrackerAppGroupIdentifier)?
            .appendingPathComponent(expiringFoodsSnapshotFileName)
    }
}

extension JSONEncoder {
    static var expiringFoods: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var expiringFoods: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
