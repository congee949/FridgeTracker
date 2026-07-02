import XCTest
@testable import FridgeTracker

/// 小组件同步状态记录与展示的契约：成功写时间戳并清错误；失败写错误但保留上次成功时间；
/// 状态文案错误优先，从未同步显示「尚未同步」。
/// 用隔离 suite 而非 UserDefaults.standard——单测宿主 app 自己的刷新路径也在写同名键，会互相污染。
@MainActor
final class WidgetSyncStatusTests: XCTestCase {

    private static let defaultsSuiteName = "WidgetSyncStatusTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.defaultsSuiteName)!
        defaults.removePersistentDomain(forName: Self.defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.defaultsSuiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - 状态记录

    func testRecordSuccessWritesTimestampAndClearsError() {
        defaults.set("旧错误", forKey: WidgetDataStore.lastSyncErrorKey)
        let now = Date()

        WidgetDataStore.recordSyncSuccess(defaults: defaults, now: now)

        XCTAssertEqual(defaults.double(forKey: WidgetDataStore.lastSyncTimestampKey), now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(defaults.object(forKey: WidgetDataStore.lastSyncErrorKey))
    }

    func testRecordFailureKeepsLastSuccessTimestamp() {
        WidgetDataStore.recordSyncSuccess(defaults: defaults, now: Date(timeIntervalSince1970: 1000))

        WidgetDataStore.recordSyncFailure("写入失败", defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: WidgetDataStore.lastSyncErrorKey), "写入失败")
        XCTAssertEqual(defaults.double(forKey: WidgetDataStore.lastSyncTimestampKey), 1000, accuracy: 0.001)
    }

    func testSuccessAfterFailureClearsError() {
        WidgetDataStore.recordSyncFailure("一次失败", defaults: defaults)

        WidgetDataStore.recordSyncSuccess(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: WidgetDataStore.lastSyncErrorKey))
    }

    // MARK: - 状态文案

    func testStatusTextPrefersErrorOverTimestamp() {
        XCTAssertEqual(WidgetDataStore.syncStatusText(error: "出错了", timestamp: 1000), "出错了")
    }

    func testStatusTextShowsNeverSyncedWhenNoTimestamp() {
        XCTAssertEqual(WidgetDataStore.syncStatusText(error: "", timestamp: 0), "尚未同步")
    }

    func testStatusTextFormatsTimestampWhenHealthy() {
        let text = WidgetDataStore.syncStatusText(error: "", timestamp: Date().timeIntervalSince1970)
        XCTAssertNotEqual(text, "尚未同步")
        XCTAssertFalse(text.isEmpty)
    }
}
