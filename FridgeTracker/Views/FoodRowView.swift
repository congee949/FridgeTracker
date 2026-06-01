import SwiftUI

struct FoodRowView: View {
    let item: FoodItem

    private var expiryColor: Color {
        if item.isExpired { return .red }
        if item.isExpiringSoon { return .orange }
        return .green
    }

    private var expiryText: String {
        let days = item.daysUntilExpiry
        if days < 0 { return "已过期 \(-days) 天" }
        if days == 0 { return "今天过期" }
        return "\(days) 天后过期"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Category icon
            Text(item.displayIcon)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text("\(item.category.rawValue)\(item.quantityDisplayText.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Expiry
            VStack(alignment: .trailing, spacing: 2) {
                Text(expiryText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(expiryColor)
            }
        }
        .padding(.vertical, 4)
    }
}
