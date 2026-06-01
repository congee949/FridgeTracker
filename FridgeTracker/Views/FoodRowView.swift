import SwiftUI

struct FoodRowView: View {
    let item: FoodItem

    private var expiryColor: Color { expiryStatusColor(daysUntilExpiry: item.daysUntilExpiry) }
    private var expiryText: String { expiryStatusText(daysUntilExpiry: item.daysUntilExpiry) }

    var body: some View {
        HStack(spacing: 12) {
            // Category icon
            Text(item.displayIcon)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(item.category.rawValue)，\(expiryText)")
    }
}
