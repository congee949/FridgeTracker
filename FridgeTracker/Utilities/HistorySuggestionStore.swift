import Foundation
import Combine

struct HistorySuggestionOverride: Codable, Equatable {
    var name: String
    var category: FoodCategory
    var storageZone: StorageZone
    var customIcon: String?
    var defaultShelfLifeDays: Int
    var isHidden: Bool

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class HistorySuggestionStore: ObservableObject {
    static let shared = HistorySuggestionStore()

    @Published private(set) var overrides: [String: HistorySuggestionOverride] = [:]

    private let storageKey = "historySuggestionOverrides"

    private init() {
        load()
    }

    func override(for name: String) -> HistorySuggestionOverride? {
        overrides[normalized(name)]
    }

    func isHidden(_ name: String) -> Bool {
        override(for: name)?.isHidden == true
    }

    func save(_ override: HistorySuggestionOverride) {
        let key = normalized(override.name)
        guard !key.isEmpty else { return }
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
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        overrides = (try? JSONDecoder().decode([String: HistorySuggestionOverride].self, from: data)) ?? [:]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
