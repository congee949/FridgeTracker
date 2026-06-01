import Foundation
import SwiftUI

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
