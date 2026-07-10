import AppIntents
import SwiftUI
import WidgetKit

struct FridgeTrackerWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "显示设置"
    static var description = IntentDescription("选择这个小组件要显示的食材分类。")

    @Parameter(title: "食材分类", default: .all)
    var category: WidgetFoodCategory
}

enum WidgetFoodCategory: String, AppEnum {
    case all
    case vegetable
    case fruit
    case meat
    case seafood
    case dairy
    case egg
    case beverage
    case condiment
    case snack
    case baking
    case frozen
    case other

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "食材分类")
    static var caseDisplayRepresentations: [WidgetFoodCategory: DisplayRepresentation] = [
        .all: "全部",
        .vegetable: "🥬 蔬菜",
        .fruit: "🍎 水果",
        .meat: "🥩 肉类",
        .seafood: "🦐 海鲜",
        .dairy: "🥛 乳制品",
        .egg: "🥚 蛋类",
        .beverage: "🧃 饮料",
        .condiment: "🧂 调味品",
        .snack: "🍪 零食",
        .baking: "🍞 烘焙",
        .frozen: "🧊 速冻食品",
        .other: "📦 其他"
    ]

    var categoryName: String? {
        switch self {
        case .all: return nil
        case .vegetable: return "蔬菜"
        case .fruit: return "水果"
        case .meat: return "肉类"
        case .seafood: return "海鲜"
        case .dairy: return "乳制品"
        case .egg: return "蛋类"
        case .beverage: return "饮料"
        case .condiment: return "调味品"
        case .snack: return "零食"
        case .baking: return "烘焙"
        case .frozen: return "速冻食品"
        case .other: return "其他"
        }
    }

    var title: String {
        switch self {
        case .all: return "冰箱提醒"
        case .vegetable: return "蔬菜提醒"
        case .fruit: return "水果提醒"
        case .meat: return "肉类提醒"
        case .seafood: return "海鲜提醒"
        case .dairy: return "乳制品提醒"
        case .egg: return "蛋类提醒"
        case .beverage: return "饮料提醒"
        case .condiment: return "调味品提醒"
        case .snack: return "零食提醒"
        case .baking: return "烘焙提醒"
        case .frozen: return "速冻提醒"
        case .other: return "其他提醒"
        }
    }

    var badgeTitle: String {
        switch self {
        case .all: return "全部"
        case .vegetable: return "蔬菜"
        case .fruit: return "水果"
        case .meat: return "肉类"
        case .seafood: return "海鲜"
        case .dairy: return "乳制品"
        case .egg: return "蛋类"
        case .beverage: return "饮料"
        case .condiment: return "调味品"
        case .snack: return "零食"
        case .baking: return "烘焙"
        case .frozen: return "速冻"
        case .other: return "其他"
        }
    }
}

struct FridgeTrackerWidgetEntry: TimelineEntry {
    let date: Date
    let configuration: FridgeTrackerWidgetConfigurationIntent
    let items: [ExpiringFoodSnapshot]
}

struct FridgeTrackerWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FridgeTrackerWidgetEntry {
        FridgeTrackerWidgetEntry(
            date: Date(),
            configuration: FridgeTrackerWidgetConfigurationIntent(),
            items: [
                ExpiringFoodSnapshot(
                    id: UUID(),
                    name: "牛奶",
                    category: "乳制品",
                    categoryIcon: "🥛",
                    displayIcon: "🥛",
                    storageZone: "冷藏",
                    storageIcon: "❄️",
                    expiryDate: Date(),
                    daysUntilExpiry: 1
                )
            ]
        )
    }

    func snapshot(for configuration: FridgeTrackerWidgetConfigurationIntent, in context: Context) async -> FridgeTrackerWidgetEntry {
        FridgeTrackerWidgetEntry(date: Date(), configuration: configuration, items: loadItems(for: configuration))
    }

    func timeline(for configuration: FridgeTrackerWidgetConfigurationIntent, in context: Context) async -> Timeline<FridgeTrackerWidgetEntry> {
        let entry = FridgeTrackerWidgetEntry(date: Date(), configuration: configuration, items: loadItems(for: configuration))
        let nextUpdate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func loadItems(for configuration: FridgeTrackerWidgetConfigurationIntent) -> [ExpiringFoodSnapshot] {
        guard let url = FileManager.default.expiringFoodsSnapshotURL,
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder.expiringFoods.decode([ExpiringFoodSnapshot].self, from: data) else {
            return []
        }

        let filteredItems = items.filter { item in
            guard let categoryName = configuration.category.categoryName else { return true }
            return item.category == categoryName
        }

        return filteredItems.sorted { $0.expiryDate < $1.expiryDate }
    }
}

struct FridgeTrackerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: FridgeTrackerWidgetEntry

    private var title: String {
        entry.configuration.category.title
    }

    private var categoryBadgeTitle: String {
        entry.configuration.category.badgeTitle
    }

    private var visibleItems: [ExpiringFoodSnapshot] {
        Array(entry.items.prefix(visibleItemLimit))
    }

    private var visibleItemLimit: Int {
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return 3
        // 辅助功能特大字号下每行更高，8 行会挤出大号容器被截断，减到 4 行，其余归入「还有 N 项」
        default: return dynamicTypeSize.isAccessibilitySize ? 4 : 8
        }
    }

    private var remainingItemCount: Int {
        max(entry.items.count - visibleItems.count, 0)
    }

    private static let foodHomeURL = URL(string: "fridgetracker://food")!

    private var foodHomeURL: URL { Self.foodHomeURL }

    private func foodDetailURL(for item: ExpiringFoodSnapshot) -> URL {
        URL(string: "fridgetracker://food/\(item.id.uuidString)") ?? Self.foodHomeURL
    }

    private var listSpacing: CGFloat {
        family == .systemLarge ? 5 * scaleFactor : 8
    }

    private var scaleFactor: CGFloat {
        // 辅助功能特大字号下不再放大：语义字体本身已很大，再乘会挤出容器
        guard family == .systemLarge, !dynamicTypeSize.isAccessibilitySize else { return 1.0 }
        let count = visibleItems.count
        guard count > 0 else { return 1.0 }
        let defaultRowHeight: CGFloat = 16
        let spacing: CGFloat = 5
        let defaultContentHeight = CGFloat(count) * defaultRowHeight + CGFloat(count - 1) * spacing
        let availableHeight: CGFloat = 136
        return max(1.0, min(availableHeight / defaultContentHeight, 1.5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: listSpacing) {
            HStack {
                Text(title)
                    .font(family == .systemLarge ? .title3.weight(.semibold) : .headline)
                Spacer()
                Text(categoryBadgeTitle)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, family == .systemLarge ? 7 : 8)
                    .padding(.vertical, family == .systemLarge ? 3 : 4)
                    .background(Color.accentColor.opacity(0.16))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
            .padding(.top, family == .systemLarge ? 4 : 0)

            if visibleItems.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    if family == .systemLarge {
                        Image(systemName: "checkmark.circle")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                    Text("暂无快过期食材")
                        .font(family == .systemLarge ? .headline : .subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if family == .systemSmall, let item = visibleItems.first {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.displayIcon)
                        .font(.largeTitle)
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(item.expiryText)
                        .font(.subheadline)
                        .foregroundStyle(statusColor(for: item))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.name)，\(item.expiryText)，\(item.storageZone)")
                Spacer(minLength: 0)
            } else {
                ForEach(visibleItems) { item in
                    Link(destination: foodDetailURL(for: item)) {
                        ExpiringFoodWidgetRow(item: item, family: family, scaleFactor: scaleFactor)
                    }
                }
                if remainingItemCount > 0 {
                    Text("还有 \(remainingItemCount) 项")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(widgetURLTarget)
    }

    /// 小号只显示一项，整卡点按直接深链到该食材详情；中/大号有逐行 Link，整卡兜底回首页。
    private var widgetURLTarget: URL {
        if family == .systemSmall, let item = visibleItems.first {
            return foodDetailURL(for: item)
        }
        return foodHomeURL
    }

    private func statusColor(for item: ExpiringFoodSnapshot) -> Color {
        expiryStatusColor(daysUntilExpiry: item.currentDaysUntilExpiry)
    }
}

struct ExpiringFoodWidgetRow: View {
    let item: ExpiringFoodSnapshot
    let family: WidgetFamily
    let scaleFactor: CGFloat

    init(item: ExpiringFoodSnapshot, family: WidgetFamily, scaleFactor: CGFloat = 1.0) {
        self.item = item
        self.family = family
        self.scaleFactor = scaleFactor
    }

    private var isLarge: Bool {
        family == .systemLarge
    }

    private var statusColor: Color {
        expiryStatusColor(daysUntilExpiry: item.currentDaysUntilExpiry)
    }

    private var iconFont: Font {
        guard isLarge else { return .body }
        return scaleFactor >= 1.35 ? .title3 : .body
    }

    private var nameFont: Font {
        guard isLarge else { return .subheadline }
        return scaleFactor >= 1.35 ? .subheadline.weight(.semibold) : .caption.weight(.semibold)
    }

    private var detailFont: Font {
        guard isLarge else { return .caption2 }
        return scaleFactor >= 1.35 ? .caption : .caption2
    }

    private var rowDetailSpacing: CGFloat {
        isLarge ? scaleFactor : 1
    }

    var body: some View {
        HStack(alignment: .center, spacing: isLarge ? 8 * scaleFactor : 8) {
            Text(item.displayIcon)
                .font(iconFont)
                .frame(width: isLarge ? 24 * scaleFactor : nil)
            VStack(alignment: .leading, spacing: rowDetailSpacing) {
                Text(item.name)
                    .font(nameFont)
                    .lineLimit(1)
                Text(isLarge ? item.category : item.expiryText)
                    .font(detailFont)
                    .foregroundStyle(isLarge ? Color.secondary : statusColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if isLarge {
                VStack(alignment: .trailing, spacing: rowDetailSpacing) {
                    Text(item.expiryText)
                        .font(detailFont.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    Text(item.storageZone)
                        .font(detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(item.category)，\(item.expiryText)，\(item.storageZone)")
    }
}

struct FridgeTrackerWidget: Widget {
    let kind = "FridgeTrackerWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: FridgeTrackerWidgetConfigurationIntent.self, provider: FridgeTrackerWidgetProvider()) { entry in
            FridgeTrackerWidgetView(entry: entry)
        }
        .configurationDisplayName("食材到期提醒")
        .description("查看最近即将到期的食材，可按分类单独显示。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemMedium) {
    FridgeTrackerWidget()
} timeline: {
    FridgeTrackerWidgetEntry(
        date: Date(),
        configuration: FridgeTrackerWidgetConfigurationIntent(),
        items: [
            ExpiringFoodSnapshot(id: UUID(), name: "牛奶", category: "乳制品", categoryIcon: "🥛", displayIcon: "🥛", storageZone: "冷藏", storageIcon: "❄️", expiryDate: Date(), daysUntilExpiry: 1),
            ExpiringFoodSnapshot(id: UUID(), name: "鸡胸肉", category: "肉类", categoryIcon: "🥩", displayIcon: "🥩", storageZone: "冷冻", storageIcon: "🧊", expiryDate: Date(), daysUntilExpiry: 3),
            ExpiringFoodSnapshot(id: UUID(), name: "吐司", category: "烘焙", categoryIcon: "🍞", displayIcon: "🍞", storageZone: "常温", storageIcon: "🏠", expiryDate: Date(), daysUntilExpiry: 4)
        ]
    )
}
