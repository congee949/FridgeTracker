# FridgeTracker

FridgeTracker 是一个 iOS SwiftUI app，用来追踪冰箱里的食材保质期。录入食材、按分类和存放区（冷藏/冷冻/常温）管理，临近过期时推送本地通知，桌面 Widget 实时显示临期清单。内置一条辅助闭环：拍照识别包装上的日期文字，一键把识别结果转成补货项，消耗或丢弃食材时记一笔处置记录，再从这些历史记录里生成下一轮的补货建议。

完全本地运行，无后端、无账号、无网络请求，数据只存在设备上。

## 功能

- **食材管理**：按分类（肉/海鲜/蔬果/乳蛋/冷冻…）和存放区（冷藏/冷冻/常温）录入与管理，列表支持搜索、分类、按到期排序。
- **过期提醒**：临期与到期当天推送本地通知；分类默认提前天数可调（肉/海鲜 2 天、冷冻 7 天等）。系统通知被拒时设置页给出恢复入口。
- **桌面 Widget**：小/中/大三种尺寸实时显示临期清单，点击深链到对应食材；支持 Dynamic Type 与 VoiceOver。
- **拍照识别日期**：Vision 端上 OCR 识别包装上的生产/保质日期，一键转成补货项。
- **消耗闭环**：消耗或丢弃时按品类用「吃/喝/用」记处置，历史记录再生成下一轮补货建议。

## 技术栈

iOS 26+ / SwiftUI，持久化用 SwiftData，桌面组件用 WidgetKit，本地提醒用 UserNotifications，端上 OCR 用 Vision。主 app 与 Widget 通过 App Group 共享数据。

## 安装

### 方式一：直接安装（无需 Xcode，自行侧载）

[Releases](https://github.com/congee949/FridgeTracker/releases) 里提供**未签名 IPA**（`FridgeTracker-x.y.z-unsigned.ipa`），不绑定任何设备/账号，需用**你自己的 Apple ID** 侧载：

- **AltStore / SideStore**：电脑装 AltServer → 手机 AltStore 里选此 IPA 安装（免费 ID 每 7 天自动后台重签）
- **Sideloadly**：连电脑，拖入 IPA，填自己的 Apple ID
- **TrollStore**：仅限受支持的 iOS 版本，免签永久安装

> **限制（苹果侧，非包本身问题）**
> 1. 免费 Apple ID：应用 **7 天过期**、同时最多 3 个 app、每周 10 个 App ID（本 app + 小组件占 2 个）。
> 2. app 含**小组件 + App Group**，依赖签名工具正确重写 group——AltStore / SideStore / Sideloadly 可正常处理；过于简化的工具可能导致小组件不刷新。
> 3. 付费开发者账号（$99/年）可签 1 年，免除上述限制。

### 方式二：从源码构建

1. 用 Xcode（26+）打开 `FridgeTracker.xcodeproj`，选择 `FridgeTracker` scheme。
2. 真机部署前，把 Signing 改成你自己的 Team，Bundle 前缀（当前是 `com.congee.*`）也要换成你自己的，避免和原作者的签名冲突。
3. 确认主 app 和 Widget 两个 target 的 entitlements 都指向同一个 App Group（当前是 `group.com.congee.FridgeTracker`），否则 Widget 读不到数据。
4. `⌘R` 运行，长按桌面添加 FridgeTracker Widget。

## 项目结构

```text
FridgeTracker.xcodeproj/        Xcode 工程（project.pbxproj / 共享 scheme / SPM 依赖锁定）

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
FridgeTrackerUITests/           端到端流程测试（XCUITest，含 Page Object 封装）

docs/                           设计文档、实现计划、面向用户的更新说明
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

## 测试

```bash
xcodebuild test -project FridgeTracker.xcodeproj -scheme FridgeTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

单元测试和快照测试跑在 `FridgeTrackerTests`，端到端流程测试跑在 `FridgeTrackerUITests`。两者都挂在 `FridgeTracker` scheme 的 Test action 下，上面一条命令会一并执行。分层说明见 [`docs/testing/README.md`](docs/testing/README.md)。

## 文档

- [`docs/README.md`](docs/README.md) — 文档地图，索引全部设计文档和实现计划。
- [`CHANGELOG.md`](CHANGELOG.md) — 版本变更记录。
