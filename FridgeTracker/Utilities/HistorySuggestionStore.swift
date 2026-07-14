import Foundation
import Combine

struct HistorySuggestionOverride: Codable, Equatable {
    var name: String
    var category: FoodCategory
    var storageZone: StorageZone
    var customIcon: String?
    var defaultShelfLifeDays: Int
    var isHidden: Bool

    init(
        name: String,
        category: FoodCategory,
        storageZone: StorageZone,
        customIcon: String?,
        defaultShelfLifeDays: Int,
        isHidden: Bool
    ) {
        self.name = name
        self.category = category
        self.storageZone = storageZone
        self.customIcon = customIcon
        self.defaultShelfLifeDays = defaultShelfLifeDays
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case name, category, categoryID, storageZone, customIcon, defaultShelfLifeDays, isHidden
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let stableID = try container.decodeIfPresent(FoodCategoryID.self, forKey: .categoryID) {
            category = FoodCategory(stableID: stableID)
        } else {
            category = try container.decode(FoodCategory.self, forKey: .category)
        }
        storageZone = try container.decode(StorageZone.self, forKey: .storageZone)
        customIcon = try container.decodeIfPresent(String.self, forKey: .customIcon)
        defaultShelfLifeDays = try container.decode(Int.self, forKey: .defaultShelfLifeDays)
        isHidden = try container.decode(Bool.self, forKey: .isHidden)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        // 中文字段保留一个兼容周期；新版本身份读取优先使用稳定 ID。
        try container.encode(category, forKey: .category)
        try container.encode(category.stableID, forKey: .categoryID)
        try container.encode(storageZone, forKey: .storageZone)
        try container.encodeIfPresent(customIcon, forKey: .customIcon)
        try container.encode(defaultShelfLifeDays, forKey: .defaultShelfLifeDays)
        try container.encode(isHidden, forKey: .isHidden)
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class HistorySuggestionStore: ObservableObject {
    static let shared = HistorySuggestionStore()
    nonisolated static let storageKey = "historySuggestionOverrides"

    @Published private(set) var overrides: [String: HistorySuggestionOverride] = [:]

    private init() {
        load()
    }

    func reloadFromDefaults() {
        load()
    }

    func override(for name: String) -> HistorySuggestionOverride? {
        overrides[normalized(name)]
    }

    func isHidden(_ name: String) -> Bool {
        override(for: name)?.isHidden == true
    }

    func save(_ override: HistorySuggestionOverride) throws {
        try FoodTextConstraints.validateFoodInput(
            name: override.name,
            quantity: nil,
            notes: nil,
            customIcon: override.customIcon
        )
        let key = normalized(override.name)
        var updated = override
        updated.name = override.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var nextOverrides = overrides
        nextOverrides[key] = updated
        overrides = nextOverrides
        persist()
    }

    func removeOverride(for name: String) {
        var nextOverrides = overrides
        nextOverrides.removeValue(forKey: normalized(name))
        overrides = nextOverrides
        persist()
    }

    func applyOverrides(to templates: [FoodTemplate]) -> [FoodTemplate] {
        templates.compactMap { template in
            guard let override = override(for: template.normalizedName) else { return template }
            guard !override.isHidden else { return nil }
            return template.applying(override)
        }
    }

    func template(for name: String, in items: [FoodItem]) -> FoodTemplate? {
        let key = normalized(name)
        guard !key.isEmpty, !isHidden(key) else { return nil }
        return FoodTemplate.fromHistory(items).first { $0.normalizedName == key }?.applying(override(for: key))
    }

    func template(for name: String, from templates: [FoodTemplate]) -> FoodTemplate? {
        let key = normalized(name)
        guard !key.isEmpty, !isHidden(key) else { return nil }
        return templates.first { $0.normalizedName == key }?.applying(override(for: key))
    }

    private func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else {
            // A replace-style backup restore may intentionally remove this key.  The
            // in-memory singleton must mirror that absence instead of retaining stale
            // overrides from the pre-restore process lifetime.
            overrides = [:]
            return
        }
        overrides = (try? JSONDecoder().decode([String: HistorySuggestionOverride].self, from: data)) ?? [:]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
