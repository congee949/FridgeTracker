import Foundation
import SwiftData
import SwiftUI

enum SortOption: String, CaseIterable {
    case expiryDate = "按过期日期"
    case createdDate = "按添加时间"
    case name = "按名称"
}

@Observable
class FoodListViewModel {
    var searchText: String = ""
    var selectedCategory: FoodCategory? = nil
    var sortOption: SortOption = .expiryDate

    func filteredItems(_ items: [FoodItem]) -> [FoodItem] {
        var result = items

        // Search filter
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        // Category filter
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }

        // Sort
        switch sortOption {
        case .expiryDate:
            result.sort {
                if $0.expiryLocalDate != $1.expiryLocalDate {
                    return $0.expiryLocalDate < $1.expiryLocalDate
                }
                let nameOrder = $0.name.localizedCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.uuid.uuidString < $1.uuid.uuidString
            }
        case .createdDate:
            result.sort { $0.createdAt > $1.createdAt }
        case .name:
            result.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }

        return result
    }
}
