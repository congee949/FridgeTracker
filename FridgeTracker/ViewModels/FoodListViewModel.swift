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
            result.sort { $0.expiryDate < $1.expiryDate }
        case .createdDate:
            result.sort { $0.createdAt > $1.createdAt }
        case .name:
            result.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }

        return result
    }
}
