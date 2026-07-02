import XCTest
import SwiftData
@testable import FridgeTracker

/// `FoodItem.find(uuid:in:)` 的契约：深链路由靠它同步直查，
/// 不依赖 @Query 加载时机——查得到就开详情，查不到说明已删。
@MainActor
final class FoodItemLookupTests: XCTestCase {

    private func makeItem(name: String, in context: ModelContext) -> FoodItem {
        let item = FoodItem(name: name, category: .dairy, storageZone: .fridge, expiryDate: .now)
        context.insert(item)
        return item
    }

    func testFindReturnsMatchingItem() throws {
        let context = try TestModelContainer.makeContext()
        let milk = makeItem(name: "牛奶", in: context)
        _ = makeItem(name: "鸡蛋", in: context)
        try context.save()

        let found = FoodItem.find(uuid: milk.uuid, in: context)

        XCTAssertEqual(found?.uuid, milk.uuid)
        XCTAssertEqual(found?.name, "牛奶")
    }

    func testFindReturnsNilForUnknownUUID() throws {
        let context = try TestModelContainer.makeContext()
        _ = makeItem(name: "牛奶", in: context)
        try context.save()

        XCTAssertNil(FoodItem.find(uuid: UUID(), in: context))
    }

    func testFindReturnsNilAfterItemDeleted() throws {
        // 深链指向已删除食材（如小组件快照滞后）时必须返回 nil 而不是崩溃或旧值。
        let context = try TestModelContainer.makeContext()
        let milk = makeItem(name: "牛奶", in: context)
        try context.save()

        context.delete(milk)
        try context.save()

        XCTAssertNil(FoodItem.find(uuid: milk.uuid, in: context))
    }
}
