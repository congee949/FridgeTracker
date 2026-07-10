# FridgeTracker

FridgeTracker 是一个 iOS SwiftUI app，用来追踪冰箱里的食材保质期。录入食材、按分类和存放区（冷藏/冷冻/常温）管理，临近过期时推送本地通知，桌面 Widget 实时显示临期清单。内置一条辅助闭环：拍照识别包装上的日期文字，一键把识别结果转成补货项，消耗或丢弃食材时记一笔处置记录，再从这些历史记录里生成下一轮的补货建议。

## 技术栈

iOS 26+ / SwiftUI，持久化用 SwiftData，桌面组件用 WidgetKit，本地提醒用 UserNotifications。主 app 与 Widget 通过 App Group 共享数据。

## 项目结构

```text
FridgeTracker.xcodeproj/        Xcode 工程

FridgeTracker/                  主 app target
├── App/                        入口 FridgeTrackerApp.swift
├── Models/                     FoodItem、FoodTemplate、FoodBackup 等 @Model 与领域类型
├── ViewModels/                 FoodListViewModel（列表搜索/分类/排序）
├── Views/                      各屏幕：列表、详情、添加、补货、历史、设置
├── Utilities/                  通知调度、OCR 文本解析、历史建议 store、
│                                跨 target 共享的 ExpiringFoodSnapshot
└── Assets.xcassets/

FridgeTrackerWidget/            Widget extension target，只读 App Group 里的 JSON 快照

FridgeTrackerTests/             单元测试 + 快照测试（XCTest + swift-snapshot-testing）
FridgeTrackerUITests/           端到端流程测试（XCUITest）

docs/                           设计文档、实现计划、面向用户的更新说明
implementation-notes.md         实现决策 / 偏差 / 取舍的滚动日志
CHANGELOG.md                    版本变更记录
```

## 主 app 与 Widget 如何共享数据

主 app 持有完整的 SwiftData 模型，Widget 不 import SwiftData，只读一份轻量 JSON 快照，两者单向解耦：

```text
FridgeTracker (主 app)                                    FridgeTrackerWidget
  SwiftData @Model FoodItem            App Group 容器
       │ WidgetDataStore.write           group.com.congee.FridgeTracker
       └──────────────写─────────▶ expiring-foods.json ──读──▶ 解码渲染
```

`FridgeTracker/Utilities/ExpiringFoodSnapshot.swift` 是这套契约的唯一定义处，它以双 target membership 同时编译进主 app 和 Widget——投影和解码用同一个 struct，字段不一致会在编译期报错，不会在运行期悄悄错位。

## 构建与运行

1. 用 Xcode 打开 `FridgeTracker.xcodeproj`，选择 `FridgeTracker` scheme。
2. 真机部署前，把 Signing 改成你自己的 Team，Bundle 前缀（当前是 `com.congee.*`）也要换成你自己的，避免和原作者的签名冲突。
3. 确认主 app 和 Widget 两个 target 的 entitlements 都指向同一个 App Group（当前是 `group.com.congee.FridgeTracker`），否则 Widget 读不到数据。
4. `⌘R` 运行，长按桌面添加 FridgeTracker Widget。

## 测试

```bash
xcodebuild test -project FridgeTracker.xcodeproj -scheme FridgeTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

单元测试和快照测试跑在 `FridgeTrackerTests`，端到端流程测试跑在 `FridgeTrackerUITests`。细节和分层说明见 [`docs/testing/README.md`](docs/testing/README.md)。

## 文档

- [`docs/README.md`](docs/README.md) — 文档地图，索引全部设计文档和实现计划。
- [`implementation-notes.md`](implementation-notes.md) — 非平凡改动的设计决策、偏差和取舍记录。
- [`CHANGELOG.md`](CHANGELOG.md) — 版本变更记录。
