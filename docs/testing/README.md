---
title: FridgeTracker 测试说明
tags: [testing, xctest, xcuitest, snapshot]
updated: 2026-06-20
---

# FridgeTracker 测试说明

回归测试套件，覆盖单元逻辑、端到端用户流程和视觉回归三层。全部为 Swift + Xcode 原生
XCTest / XCUITest，外加 Point-Free `swift-snapshot-testing`（仅快照层）。

| 层 | Target | 数量 | 框架 |
|---|---|---|---|
| 单元 | `FridgeTrackerTests` | 169 | XCTest |
| 视觉快照 | `FridgeTrackerTests` | 3 | swift-snapshot-testing |
| 端到端 (E2E) | `FridgeTrackerUITests` | 6 通过 + 1 跳过 | XCUITest |

> 合计 **179** 个用例，0 失败。单元+快照 ~0.3s；UI ~90s。

## 如何运行

共享 scheme：**FridgeTracker**（已包含两个测试 target 的 Test action）。

```bash
# 全部测试（单元 + 快照 + UI）
xcodebuild test -project FridgeTracker.xcodeproj -scheme FridgeTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# 只跑单元 + 快照（快）
xcodebuild test -project FridgeTracker.xcodeproj -scheme FridgeTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FridgeTrackerTests

# 只跑某个测试类 / 单个用例
... -only-testing:FridgeTrackerTests/FoodQuantityTests
... -only-testing:FridgeTrackerUITests/ConsumeDiscardUITests/testDiscardingItemRemovesIt
```

Xcode 内：⌘U 跑全部，或在 Test navigator 点单个。

> [!warning] UI 测试后命令挂起
> `xcodebuild test` 跑完 UI 测试后偶尔不退出（残留的 `FridgeTrackerUITests-Runner` 占着输出管道）。
> 命令末尾追加 `; pkill -9 -f FridgeTrackerUITests-Runner` 即可。

## 测试覆盖一览

### 单元（`FridgeTrackerTests/`）

| 文件 | 覆盖的模块 / 流程 |
|---|---|
| `FoodQuantityTests` | `FoodQuantity` 解析/递减/合并 + `FoodItem.reduceQuantityByOne/mergeQuantity`（消费删除契约） |
| `FoodItemExpiryTests` | `FoodItem` 过期/保质期计算（daysUntilExpiry、isExpired、isExpiringSoon、shelfLifeDaysEstimate、refresh） |
| `PackagingTextParserTests` | Vision OCR 文本→名称/过期日解析（注入 `Calendar`，确定性） |
| `FoodBackupTests` | 备份导出/导入往返、ISO-8601 日期、v1 兼容、中文枚举解码 |
| `FoodListViewModelTests` | 清单筛选/排序（搜索、分类、三种排序） |
| `FoodTemplateTests` | 历史建议去重/覆盖 |
| `ReplenishmentItemTests` | 自动补货规则（阈值=2、30 天窗口、addIfAbsent） |
| `ExpiringFoodSnapshotTests` | 过期状态文案/颜色 + 跨 app/widget 共享的 Codable 契约 |
| `NotificationManagerIdentifierTests` | 通知标识符 advance/expiry/isFoodReminderIdentifier |
| `HistorySuggestionStoreTests` | 建议覆盖映射/隐藏过滤（含 UserDefaults 隔离） |
| `FoodRowViewSnapshotTests` | 行视图视觉快照（fresh / soon / expired 三态） |
| `SmokeTests` | 流水线 sanity（@testable import + 内存容器） |

### 端到端（`FridgeTrackerUITests/`）

| 用例 | 覆盖的核心流程 |
|---|---|
| `SmokeUITests.testAppLaunchesToFoodList` | 启动到食材列表 |
| `AddFoodUITests.testAddItemAppearsInList` | 手动添加食材 → 出现在列表 |
| `AddFoodUITests.testExpiryStepperIncrementsDaysText` | 过期 stepper 驱动「还有 N 天」文案 |
| `AddFoodUITests.testTypingKnownNameDoesNotClobberUserSetExpiry` | （跳过，见下「已知限制」） |
| `ConsumeDiscardUITests.testConsumingMultiUnitItemDecrementsAndKeepsRow` | 多单位消费 → 递减、保留 |
| `ConsumeDiscardUITests.testConsumingUntrackedItemRemovesIt` | 无数量项消费 → 移除 |
| `ConsumeDiscardUITests.testDiscardingItemRemovesIt` | 丢弃 → 移除 |

## 关键基础设施

### 内存 SwiftData 容器（单元）
`FridgeTrackerTests/Support/InMemoryModelContainer.swift` — 单进程**共享**的内存 `ModelContainer`，
每次 `makeContext()` 关闭 autosave 并清空数据做隔离。
> Xcode 26 / iOS 26 模拟器上三个坑都会触发 SwiftData `EXC_BREAKPOINT`：隐式变参 `ModelContainer(for:)`、
> 悬空容器（context 还在用但容器被释放）、autosave 在拆除时异步触发。共享+保活+关 autosave 全部规避。

### XCUITest 隔离 + Page Object
- 启动参数 `-uitesting` 让 app 走内存 store（`FridgeTrackerApp.makeModelContainer`），UI 测试不碰真实数据；
  `WidgetDataStore` 同样按该参数短路，测试数据不会写进真实 App Group 小组件快照或同步状态键。
- Page Object：`FoodListScreen` / `AddFoodScreen` 封装元素查询与操作。
- 元素用 accessibilityIdentifier（如 `addFood.nameField`、`foodRow.consumeAction`）而非中文文案，稳定可维护。
- 懒加载 `Form` 中屏幕外控件未进入无障碍树，helper 先滑动露出再操作。

### 快照（视觉回归）
- 库：`swift-snapshot-testing`（SPM，仅链接到 `FridgeTrackerTests`）。
- 参考图存于 `FridgeTrackerTests/__Snapshots__/`，**需提交进 git**。
- 参考图与设备/系统相关，本套基线生成于 **iPhone 17 / iOS 26**。换设备或故意改 UI 后需重生成。
- CI 友好：`precision`/`perceptualPrecision` 设为 0.95 容忍微小抗锯齿差异。

## 如何新增测试

1. **写文件**到对应目录：
   - 单元/快照 → `FridgeTrackerTests/`（纯逻辑无需容器；用到 `@Model` 时 `@MainActor` + `TestModelContainer.makeContext()`）。
   - E2E → `FridgeTrackerUITests/`（继承 `FridgeUITestCase` 获得 `-uitesting` 隔离启动；新页面加一个 Page Object）。
2. **同步进 target**（脚本幂等，会把磁盘上的新 `.swift` 加入对应 target）：
   ```bash
   LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ruby scripts/setup_test_targets.rb
   ```
   依赖 `xcodeproj` gem：`gem install --user-install xcodeproj`。
3. **跑**：⌘U 或上面的 `xcodebuild` 命令。
4. 给新 UI 控件加 accessibilityIdentifier，避免依赖本地化文案。

### 重新生成快照基线
故意改了行视图样式后：删除 `FridgeTrackerTests/__Snapshots__/FoodRowViewSnapshotTests/` 下对应 png（或临时
在测试里设 `isRecording = true`），跑一次（会"失败"并写入新图），再跑一次校验通过，提交新图。

## 已知限制

- `testTypingKnownNameDoesNotClobberUserSetExpiry` 被 `XCTSkip`：该场景要在操作 Stepper 之后立刻重新聚焦
  名称输入框，模拟器无法稳定让键盘附着（`typeText` 抛 "no keyboard focus"）。对应的修复（改名不覆盖用户已设
  过期日）已落地并经代码评审——它与已被单元测试覆盖的 quantity/notes 空值保护逻辑同构。
- 测试在 iOS 26.x 模拟器验证；其他 runtime 上 SwiftData/快照行为可能不同。

## 顺带修复的真实 Bug（测试发现）

| 严重度 | 位置 | 问题 → 修复 |
|---|---|---|
| 高 | `FoodBackup.swift` | 导出用 ISO-8601 编码日期，导入用默认解码器（期望 `Double`）→ 任何导出的备份都无法重新导入。修：解码器统一 `.iso8601`。`FoodBackupTests` 锁定。 |
| 低 | `AddFoodView.swift:339` | 改名触发的历史自动填充会覆盖用户已手动设置的过期日。修：新增 `hasUserAdjustedExpiry` 守卫，与 quantity/notes 的保护一致。 |
