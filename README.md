# FridgeTracker

FridgeTracker 是一个 iOS SwiftUI 冰箱保质期追踪 app：录入冰箱里的食材、追踪每样东西还有几天过期、临期推送提醒，并把临期清单同步到一个桌面 Widget。它还内置了一条轻量的「OCR 识别包装日期 → 一键补货 → 处置/消耗记录 → 从历史生成补货建议」的闭环。

- **技术栈**：iOS / SwiftUI + SwiftData（持久化）+ WidgetKit（桌面小组件）+ UserNotifications（临期提醒）+ App Group（主 app 与 Widget 共享数据）
- **结构**：1 个主 app target（`FridgeTracker`）+ 1 个 Widget extension target（`FridgeTrackerWidget`）
- **Bundle 前缀**：`com.congee.*`；真机部署需用 Personal Team 签名，并在两个 target 上都启用同一个 App Group `group.com.congee.FridgeTracker`

> ✅ **2026-06-07 已执行**本文档的高 / 中优先级优化：清理约 4.8 GB 构建产物（工作目录 **4.8 GB → 约 2.5 MB**）、把 3 个超大视图拆成 7 个新文件、归并文档为单一 `docs/` 树、移除误提交的 pbxproj 备份、删除空的 UITests 目录。下文的目录树、现状评估与优化建议均已更新为**优化后**状态并标注 ✅；完整执行记录见根目录 [`implementation-notes.md`](implementation-notes.md)。

## 目录结构

下面这棵树**明确区分**两类内容：纳入版本控制的源代码与文档，以及散落在工作目录、已被 `.gitignore` 忽略、可删除可重新生成的构建产物 / 本地临时文件。

### 应纳入版本控制：源代码与文档

```text
FridgeTracker/
├── FridgeTracker.xcodeproj/
│   └── project.pbxproj                         # Xcode 工程定义（手动管理 target membership；备份文件已从 git 移除）
│
├── FridgeTracker/                              # 主 app target 源码（20 个 .swift，MVVM 分层）
│   ├── App/
│   │   └── FridgeTrackerApp.swift              # App 入口：@main、TabBar 外观配置
│   ├── Models/                                 # 领域模型 + 数据序列化层
│   │   ├── FoodItem.swift                      # @Model FoodItem、FoodDispositionRecord、ReplenishmentItem、
│   │   │                                       #   FoodQuantity、StorageZone、FoodCategory（业务逻辑下沉于此）
│   │   ├── FoodTemplate.swift                  # 食材模板（← 从 AddFoodView 拆出）
│   │   └── FoodBackup.swift                    # 导入/导出数据层 FoodBackupDocument/Backup/Item（← 从 SettingsView 拆出）
│   ├── ViewModels/
│   │   └── FoodListViewModel.swift             # 食材列表的搜索/分类/排序
│   ├── Views/
│   │   ├── ContentView.swift                   # 根容器（329→86 行）：仅 TabView + 路由（FridgeTab/AppRoute）
│   │   ├── AddFoodView.swift                   # 添加食材表单（776→501 行，已瘦身为纯表单）
│   │   ├── ReplenishmentListView.swift         # 补货屏（← 从 ContentView 拆出）
│   │   ├── HistoryView.swift                   # 历史屏（← 从 ContentView 拆出）
│   │   ├── ImagePickers.swift                  # 相册/相机 UIKit 桥接（← 从 AddFoodView 拆出）
│   │   ├── PackagingOCRConfirmationView.swift  # OCR 确认屏（← 从 AddFoodView 拆出）
│   │   ├── FoodListView.swift                  # 食材列表（含 CategoryChip）
│   │   ├── FoodDetailView.swift                # 食材详情
│   │   ├── FoodRowView.swift                   # 列表行
│   │   └── SettingsView.swift                  # 设置（349→283 行）+ 历史建议管理视图
│   ├── Utilities/
│   │   ├── ExpiringFoodSnapshot.swift          # ★ 跨 target 共享契约（app↔widget，双 target 编译；已加说明注释）
│   │   ├── HistorySuggestionStore.swift        # 历史建议持久化 store + Override（← 从 AddFoodView 拆出）
│   │   ├── WidgetDataStore.swift               # app→widget 写盘：FoodItem 投影成 JSON 快照
│   │   ├── NotificationManager.swift           # 临期本地通知调度
│   │   └── PackagingTextParser.swift           # 包装文本/OCR 日期解析
│   ├── Assets.xcassets/                        # AppIcon 等资源
│   ├── FridgeTracker.entitlements              # 声明 App Group group.com.congee.FridgeTracker
│   └── Info.plist
│
├── FridgeTrackerWidget/                        # Widget extension target 源码
│   ├── FridgeTrackerWidget.swift               # Widget 视图与 Timeline（只读 JSON 快照，不碰 SwiftData）
│   ├── FridgeTrackerWidgetBundle.swift         # WidgetBundle 入口
│   ├── FridgeTrackerWidget.entitlements        # 声明同一个 App Group
│   └── Info.plist
│
├── docs/                                       # 文档单一树（按语义分类）
│   ├── README.md                               # 📑 文档地图：列出各文档及主题
│   ├── design/                                 # 6 篇设计/spec（原 docs/spark 5 篇 + 原 specs/ 的 collapsible-tab-bar）
│   ├── plans/                                  # 实现计划（原 docs/superpowers/plans）
│   └── release-notes/                          # 面向用户的更新说明 HTML（2026-06-01-optimization-notes.html）
│
├── implementation-notes.md                     # 实现决策/偏差/取舍滚动日志（仓库根，按全局 SOP 固定于此）
├── .gitignore                                  # 已正确覆盖全部构建产物
└── README.md                                   # 本文件
```

> 注：原 `FridgeTrackerUITests/` 孤儿空目录（无 target、无文件、未进 git）已删除。

### 已清理 / 被忽略 / 可重新生成：构建产物与本地临时文件

> ✅ **本轮已清理**：工作目录曾有约 **4.8 GB** 构建产物（18 个 `DerivedData*` 目录 + `build/` + 4 个 `.xcresult` + 10 个 `.log` + 2 个 `.DS_Store`），全部被 `.gitignore` 正确忽略、从未进版本库。已用 `git clean -fdX` 一次性删除，工作目录 **4.8 GB → 约 2.5 MB**。

这些产物今后仍会被 Xcode 在 build / test 时自动重新生成。**约定：所有构建一律使用 Xcode 默认 DerivedData 路径**（`~/Library/Developer/Xcode/DerivedData`，不落在工作区），不再用 `-derivedDataPath <自定义名>` 在仓库内造新目录——那正是当初堆出 18 个目录的根因。`.gitignore` 已覆盖下列模式，无需任何 git 操作：

```text
DerivedData*/   .derivedData*/   build/      # Xcode 派生缓存
*.xcresult/                                  # 测试结果包
*.log                                        # 构建 / 验证日志
.DS_Store   xcuserdata/   .superpowers/      # 系统 / 工具本地状态
```

## 模块与架构

项目遵循标准 **MVVM 五分层**，方向正确且名副其实：

- **Models（`FoodItem.swift`）**：所有 `@Model` 与领域值类型集中于此，业务逻辑正确下沉到 model 方法（如 `FoodQuantity.parse/adding`、`FoodItem.shelfLifeDaysEstimate/mergeQuantity`、`ReplenishmentItem.autoAddIfNeeded`），而非散落在 View。
- **Views**：列表 / 详情 / 添加 / 设置等屏。配合 SwiftData 的 `@Query` + `@Environment(modelContext)` 直连模式——这是 Apple 官方惯用法，View 中对 `modelContext` 的轻量编排（如消耗、处置）不算「View 混业务逻辑」，在此规模下不需要为每个屏硬造 ViewModel。
- **ViewModels（`FoodListViewModel.swift`）**：仅一个真 VM，服务食材列表的搜索/分类/排序。
- **App（`FridgeTrackerApp.swift`）**：`@main` 入口与 TabBar 外观。
- **Utilities**：通知调度、包装文本解析、跨 target 数据快照等。

### 主 app 与 Widget 如何通过 App Group 共享数据

主 app 持有「重」的 SwiftData 模型，Widget 只消费「轻」的扁平 JSON 快照，二者**松耦合、方向单一**：

```text
┌──────────────────────────┐         App Group 容器                ┌────────────────────────┐
│  FridgeTracker (主 app)   │   group.com.congee.FridgeTracker      │ FridgeTrackerWidget     │
│                          │   ┌────────────────────────────┐      │ (extension)             │
│  SwiftData @Model        │   │                            │      │                         │
│  FoodItem ...            │── │  expiring-foods.json       │ ───▶ │  解码 ExpiringFoodSnapshot │
│       │ 投影              │写 │  (ExpiringFoodSnapshot[])  │ 读   │  渲染临期清单            │
│  WidgetDataStore.write   │   │                            │      │  （不 import SwiftData） │
└──────────────────────────┘   └────────────────────────────┘      └────────────────────────┘
```

关键机制有两层：

1. **物理共享 1 个源文件**：`FridgeTracker/Utilities/ExpiringFoodSnapshot.swift` 通过**双 target membership** 同时编译进 app 与 widget，定义了二者共用的全部契约——`struct ExpiringFoodSnapshot`、App Group 常量、`FileManager.expiringFoodsSnapshotURL`、`JSONEncoder/Decoder.expiringFoods`、以及 `expiryStatusText/expiryStatusColor` UI 辅助函数。因为投影与解码用的是同一个 struct，编译器会强制 app 写盘与 widget 读盘的字段保持一致。
2. **运行时通过 App Group 容器传 JSON**：app 经 `WidgetDataStore.write` 把 `FoodItem`（uuid / displayIcon / daysUntilExpiry / category / storageZone）投影成快照写入 `expiring-foods.json`，widget 只读这个文件。两个 target 的 `.entitlements` 都声明了同一个 App Group。

Widget 完全不依赖 SwiftData、不碰 `FoodItem`，边界干净。这是项目里做得最好的解耦点，规模太小（真正跨 target 的只有这 1 个约 60 行的文件）**不值得抽 framework / SwiftPM 包**。

### 构建与运行

```text
1. Xcode 打开 FridgeTracker.xcodeproj
2. 选择 FridgeTracker scheme
3. 真机部署：
   - Signing 选 Personal Team（Bundle 前缀 com.congee.*，需改成你自己的唯一前缀以避免冲突）
   - 确认主 app 与 Widget 两个 target 都启用了同一个 App Group：group.com.congee.FridgeTracker
4. Run（⌘R）即可在设备/模拟器安装 app；长按桌面添加 FridgeTracker Widget
```

更多设计与实现背景见 `docs/`（设计文档）与 `implementation-notes.md`（实现决策/偏差日志）。

## 结构现状评估

> 📌 以下为**优化前**的结构评估快照——其中 🔴 高 / 🟡 中优先级问题已于 2026-06-07 全部处理（见顶部说明与 [`implementation-notes.md`](implementation-notes.md)）。

一句话总结：**源码本体干净、规模小、架构合理；几乎所有问题都集中在构建产物堆积，外加少量 git/命名/文档卫生债务。**

- **源码本体（值得肯定）**：原 13 个 Swift 文件、约 2673 行；拆分后为 20 个文件（总行数基本不变，只是把大文件里的异质类型移到独立文件）。MVVM 分层名副其实，业务逻辑正确下沉到 model，app↔widget 解耦干净。这个规模**不需要重型重构**，更不该过度工程化（不要为统一而硬抽 ViewModel、不要为 1 个共享文件抽 framework）。
- **磁盘卫生（最大问题）**：工作目录 4.8 GB 中约 4.80 GB（99.9%）是 Xcode 构建产物——18 个重复命名的 DerivedData 目录 + `build/`（约 4.73 GB / 67206 文件）、4 个 `.xcresult`（约 64 MB）、10 个 `.log`、2 个 `.DS_Store`。根因是反复用 `xcodebuild -derivedDataPath <每次一个新名>` 累积出 18 份各自独立的完整缓存，从未清理。
- **git 卫生（基本健康）**：`.gitignore` 完备，工作树干净，上述所有产物**均未进版本库**（`git ls-files` 共 34 个，0 个构建产物）。唯一被误提交的不当文件是一个 pbxproj 备份。**「占磁盘」与「进版本库」是两个独立问题**——前者严重但纯属本地清理，后者已基本解决。
- **代码组织债（局部）**：少量 View 文件职责过载、把 model/store/feature 类型藏在名不副实的文件里（最突出的是 776 行的 `AddFoodView.swift`）。
- **文档卫生（待整理）**：缺 README（本文件补上），设计/规格/计划文档分裂在 4 处，命名中英混杂。

## 优化建议

下面把 5 个维度的所有 findings 合并，按严重程度分组。

> **✅ 执行状态（2026-06-07）**：🔴 高优先级 1–3 **全部完成**；🟡 中优先级 4–10 **全部完成**（3 个大文件已拆为 7 个新文件、共享文件已加注释、空目录已删、文档已归并为单一 `docs/` 树、HTML 已重命名）；🟢 低优先级 14 已落地（新增 `docs/README.md` 文档地图），11/12 随清理一并删除，13「维持现状」本就无需改动，`artifacts/` 归档约定属可选增强、未引入。下列各条**保留为问题记录与落地方式**，便于回溯。

### 🔴 高优先级

**1. 清理约 4.8 GB Xcode 构建产物（18 个重复 DerivedData + build/ 等）**
- **问题**：工作目录 4.8 GB 中约 4.73 GB / 67206 个文件是 18 个重复命名的 DerivedData 类目录 + `build/`，与代码量（约 2.5 MB）完全不成比例。
- **证据**：`du -sk` 实测 18 个 DerivedData* / `.derivedData*` + `build/` 合计约 4.73 GB；目录名（`DerivedDataCodexDevice`、`DerivedDataVerifyNativeTabRestore`、`DerivedDataDeviceRestoreTab2`…）直接暴露来源——每次 `xcodebuild -derivedDataPath <自定义名>` 都生成一份**完整缓存而非增量**，时间戳跨 8 天逐次累积，从未回收。这是典型反模式：用「每次换新路径名」代替「复用同一路径」，导致缓存无法命中、磁盘线性膨胀。
- **建议**：全部 `rm -rf` 安全回收（见 [一键清理](#一键清理构建产物)）。今后**固定单一 DerivedData 路径**——要么省略 `-derivedDataPath` 用 Xcode 默认的 `~/Library/Developer/Xcode/DerivedData`（不污染工作区、IDE 自动管理），要么固定 `-derivedDataPath ./DerivedData`（已被 `.gitignore` 的 `DerivedData*/` 覆盖）。

**2. 从 git 移除误提交的 pbxproj 备份文件**
- **问题**：`FridgeTracker.xcodeproj/project.pbxproj.before-device-ui-verify` 是 34 个追踪文件中唯一不应进库的文件。
- **证据**：它是 `project.pbxproj` 的手动备份（23652 字节 vs 现行 23634 字节，仅差 8 行），在 baseline commit `6b56fe8` 入库，与现行工程仅差历史构建配置（`GENERATE_INFOPLIST_FILE`、`IPHONEOS_DEPLOYMENT_TARGET 17.0→26.0`）。它对当前结构毫无作用，与 Xcode 工程文件并列会误导他人当成另一份有效配置。
- **建议**：`git rm --cached` 移除并删本地副本（见 [一键清理](#一键清理构建产物)），单独成 commit（如 `chore: untrack stray pbxproj backup`）。可在 `.gitignore` 增补 `*.before-*` / `*.bak` / `*.orig` / `project.pbxproj.*` 挡住未来的备份变体。

**3. 补齐项目入口 README.md**
- **问题**：仓库根此前无 README，新克隆者看不到 app 是什么、技术栈、如何构建、target 结构、签名/App Group 注意事项——这些信息此前零散藏在 `implementation-notes.md` 和各设计文档里。
- **建议**：本文件即为补齐项；后续应作为 source of truth 入口，把散落文档串成体系。

### 🟡 中优先级

**4. 拆分 776 行的 `AddFoodView.swift`（职责过载）**
- **问题/证据**：该文件除 `AddFoodView` 外还塞了 8 个类型——领域模型 `FoodTemplate`、持久化 store `HistorySuggestionStore`（`ObservableObject` + UserDefaults）、`HistorySuggestionOverride`、两个 UIKit 桥接器 `PackagingPhotoPicker`/`CameraImagePicker`、`PackagingOCRConfirmationView`、`RecentTemplateChip`。一个名为「AddFoodView」的文件里混着领域模型 + 持久化单例 + UIKit 桥接，是全项目最大的组织债务。
- **建议**：按类型归位（纯移动不改逻辑）——`FoodTemplate` → `Models/`；`HistorySuggestionStore`+`HistorySuggestionOverride` → `Stores/` 或 `Utilities/`；两个 picker → `Views/ImagePickers.swift`。拆完后 `AddFoodView.swift` 应回落到约 400 行的纯表单视图。

**5. 把 `ContentView.swift` 里的补货屏 / 历史屏拆出去**
- **问题/证据**：`ContentView.swift`（329 行）除根容器 `ContentView`（仅 TabView）外，还完整定义了 `ReplenishmentListView`（含 30 行 `generateFromHistory()` 聚合逻辑）和 `HistoryView`。文件名暗示「根容器」，实际是三合一。
- **建议**：拆出 `Views/ReplenishmentListView.swift` 与 `Views/HistoryView.swift`（纯移动）。Tab 与路由定义留在根容器文件是合理的。

**6. 把 `SettingsView.swift` 内联的备份数据层移出**
- **问题/证据**：`SettingsView.swift`（349 行）尾部定义了 `FoodBackupDocument`（FileDocument）、`FoodBackup`、`FoodBackupItem`（含 FoodItem↔DTO 双向转换）——这是数据序列化层，却嵌在 Settings 视图里。
- **建议**：移到 `Models/FoodBackup.swift` 或 `Utilities/`（与 `WidgetDataStore`、`ExpiringFoodSnapshot` 归为数据序列化层）。可与上面的「历史建议模块归位」合并为一次改动。

**7. 给跨 target 共享契约 `ExpiringFoodSnapshot.swift` 正名**
- **问题/证据**：它被主 app 和 Widget 同时编译，承载 app↔widget 的数据与展示契约，却物理躺在 `FridgeTracker/Utilities/`（主 app 目录）下，从磁盘结构看不出它是共享代码——后续维护者容易误删 widget membership 或误以为只属于 app。
- **建议**：**不要抽 framework**（过度工程）。低成本二选一：(a) 新建顶层 `Shared/` 目录把它移进去（仍保持双 membership），让「这是共享代码」自解释；(b) 仅在文件顶部加注释说明「此文件 membership 同时属于 app 与 widget，勿改 target 归属」。只有 1 个文件时 (b) 成本最低、(a) 可读性更好。

**8. 处理孤儿空目录 `FridgeTrackerUITests/`**
- **问题/证据**：该目录 0 个文件、无任何测试 target（pbxproj 中无 `XCTest`/`TEST_HOST`/`.xctest`）、未进 git。「空目录 + 无 target」是最差状态（占位但零价值）。
- **建议**：二选一——`rmdir FridgeTrackerUITests`（仅在确实为空时成功，安全）消除噪音；或若近期要补测试，则顺手建最小 UI Testing Bundle target + 一个 `testLaunch()` 冷启动断言。

**9. 归并分裂在 4 处的文档**
- **问题/证据**：设计/规格/计划散在 `docs/spark/`（5 个设计）、`docs/superpowers/plans/`（1 个计划）、顶层 `specs/`（1 个手写 spec）、仓库根（`implementation-notes.md`）。其中 `2026-05-28-widget-adaptive-row-height` 的「设计」与「计划」被人为拆到两个子树；`docs/superpowers/` 还易与已 gitignore 的 `.superpowers/`（skill 暂存）混淆。
- **建议**：合并为单一 `docs/` 树并**按语义而非生成它的 skill 命名**——如 `docs/design/`（设计）、`docs/plans/`（计划），把 `specs/collapsible-tab-bar.md` 移入 `docs/design/` 后 `rmdir specs`，把 `docs/superpowers/plans` 重命名为 `docs/plans`。`implementation-notes.md` 建议 `git mv` 进 `docs/`（注意全局 SOP 默认在根目录维护，移动后需在约定中说明新位置，避免后续 agent 在根目录重建）。`.gitignore` 无需改动（当前正确）。

**10. 统一面向用户的 HTML 文档命名与定位**
- **问题/证据**：`docs/本次优化更新说明.html` 用中文文件名，与 `docs/spark/` 的英文 kebab-case 不一致；且 git 历史（`4ce66d1`）显示它由原「完整用户手册」`使用说明书.html` 替换而来——所以这个文件名虽叫「更新说明」，承载的其实是一次性的某版本变更日志，不是长期手册。
- **建议**：按版本/日期命名并放专门子目录，如 `docs/release-notes/2026-06-01-optimization-notes.html`。若需长期用户手册应另写 `docs/user-guide`（md 源 + html 阅读层），让 HTML 有对应的 markdown source of truth。

### 🟢 低优先级

**11. 统一构建日志命名与归档**
- **问题/证据**：根目录 10 个 `.log` 混用 `device-`/`simulator-`/`final-` 前缀、靠手动 `-2` 后缀表示重跑、无时间戳，重跑会越积越多（已被 `.gitignore` 的 `*.log` 忽略）。
- **建议**：脚本统一写入 `./artifacts/logs/<purpose>-$(date +%Y%m%d-%H%M%S).log`，弃用手动 `-2` 后缀；`.gitignore` 现有 `*.log` 已在任意层级匹配，可选收紧为 `artifacts/`。

**12. `.xcresult` 与 `.DS_Store` 仅需删磁盘副本**
- **问题/证据**：4 个 `.xcresult` 被 `*.xcresult/` 命中、2 个 `.DS_Store` 被裸 `.DS_Store` 模式在任意层级命中，git 层面**无污染**、无需任何 git 操作。
- **建议**：随构建产物清理一并删磁盘副本即可（见 [一键清理](#一键清理构建产物)）。`.xcresult` 若改由集中目录（如 `artifacts/results/`）管理可读性更好，非必需。

**13. 维持现状的几处（不要过度工程化）**
- **MVVM 分层**：不要为 `FoodDetailView`/`FoodListView`/`ReplenishmentListView` 引入 ViewModel——SwiftData `@Query` + `@Environment(modelContext)` 直连是 Apple 官方惯用法，这个规模下加 VM 反而是过度抽象。
- **`FoodListViewModel`**：三个列表的过滤维度不同（食材列表有 `sortOption`，历史/补货没有），不要为统一而强行复用，保持现状（避免 YAGNI）。
- **app↔widget 数据契约**：解耦良好、无文件挂错 target，无需改动。

**14. 给设计文档补统一索引/frontmatter（可选）**
- **问题/证据**：5 个 `docs/spark/*.md` 全无 YAML frontmatter、标题中英混用，没有 index 把设计与其「已实现/废弃」状态关联，要知道某设计是否落地只能去翻 `implementation-notes.md` 交叉比对。
- **建议**：加一个轻量 `docs/README.md`（或在本 README 的文档小节）列出所有设计文档及其状态/对应特性，作为文档地图；若走 Obsidian 工作流可给设计文档补 frontmatter（title/date/status/tags）。

## 一键清理（构建产物）

> ✅ **本轮已执行**：已用 `git clean -fdX` 清理全部构建产物、`git rm --cached` 移除 pbxproj 备份文件（工作目录 4.8 GB → 约 2.5 MB）。以下命令保留供日后参考。

下面这些目录/文件**全部已被 `.gitignore` 忽略、从未进版本库，且可由 Xcode 在下次 build/test 时自动重新生成，删除完全安全**（首次重新构建会因重建 ModuleCache 稍慢，属正常代价）。

```bash
# —— 以下全部是 Xcode 派生缓存/验证残留，已被 .gitignore 忽略，删除安全（下次构建会自动重新生成）——
cd /Users/Apple/FridgeTracker

# 1) 18 个重复命名的 DerivedData 目录 + build/（约 4.73 GB / 67206 文件，单点收益最大）
rm -rf DerivedData*
rm -rf .derivedData .derivedData-nosign
rm -rf build

# 2) 4 个一次性 UI 验证测试包（约 64 MB）
rm -rf *.xcresult

# 3) 10 个根目录构建/验证日志（约 0.6 MB）
rm -f *.log

# 4) 2 个 macOS .DS_Store 残留
rm -f .DS_Store FridgeTracker/.DS_Store
```

或者用 git 自带的忽略清理一键完成上面所有内容（`-X` 只删被 `.gitignore` 忽略的文件，保留未跟踪的新源码）：

```bash
cd /Users/Apple/FridgeTracker
git clean -ndX   # 先预览将删除哪些被忽略的文件（dry-run，不实际删除）
git clean -fdX   # 确认无误后执行：删除所有被 .gitignore 忽略的产物
```

单独处理被 git 追踪的备份文件（这一个不在上面的忽略清理范围内，需手动从版本库移除）：

```bash
cd /Users/Apple/FridgeTracker
git rm --cached FridgeTracker.xcodeproj/project.pbxproj.before-device-ui-verify
rm -f FridgeTracker.xcodeproj/project.pbxproj.before-device-ui-verify   # 确认无需保留后再删本地副本
# 建议单独成 commit，例如：git commit -m "chore: untrack stray pbxproj backup"
```

## 推荐的整洁结构

清理与归并后，理想的顶层布局如下——单一 DerivedData 路径、用 `artifacts/` 收纳本地产物、补齐 README、文档按语义归并：

```text
FridgeTracker/
├── README.md                       # ← 项目入口（本文件）
├── .gitignore                      # 增补 *.before-* / *.bak / project.pbxproj.* 等备份模式
│
├── FridgeTracker.xcodeproj/        # 仅保留裸 project.pbxproj（移除 .before-* 备份）
│
├── FridgeTracker/                  # 主 app target 源码（拆分后更名副其实）
│   ├── App/
│   ├── Models/                     # + FoodTemplate.swift、FoodBackup.swift（从 View 文件归位）
│   ├── ViewModels/
│   ├── Views/                      # AddFoodView 瘦身；新增 ReplenishmentListView / HistoryView /
│   │                               #   HistorySuggestionManagementView / ImagePickers
│   ├── Stores/                     # （可选）HistorySuggestionStore 等持久化 store 归位
│   ├── Utilities/
│   ├── Assets.xcassets/
│   ├── FridgeTracker.entitlements
│   └── Info.plist
│
├── FridgeTrackerWidget/            # Widget extension target
│
├── Shared/                         # ← 跨 target 共享契约正名（双 target membership）
│   └── ExpiringFoodSnapshot.swift  #   从 FridgeTracker/Utilities/ 移入，自解释「这是共享代码」
│
├── docs/                           # 文档单一树，按语义（而非 skill）命名
│   ├── README.md                   # 文档地图：列出各设计文档 + 状态/对应特性
│   ├── design/                     # 合并 docs/spark/ + specs/collapsible-tab-bar.md
│   ├── plans/                      # 原 docs/superpowers/plans/（与 .superpowers/ 脱钩）
│   ├── release-notes/              # 按版本/日期命名的更新说明（含原「本次优化更新说明」）
│   └── implementation-notes.md     # 从仓库根 git mv 进来（在约定中注明新位置）
│
├── FridgeTrackerUITests/           # 要么删除（rmdir），要么补最小 smoke + 真实 UI Testing target
│
└── artifacts/                      # ← 本地产物统一收纳（全部 gitignore，不进版本库）
    ├── DerivedData/                # 唯一固定的 DerivedData 路径（替代 18 个即兴目录）
    ├── logs/                       # <purpose>-<时间戳>.log（替代根目录散落 *.log）
    └── results/                    # *.xcresult 集中存放
```

核心约束：今后所有构建/验证脚本一律复用**单一固定的 DerivedData 路径**（或 Xcode 默认路径），日志/测试包写入 `artifacts/` 并带时间戳，**不再即兴造顶层目录名**——这能从源头杜绝磁盘线性膨胀，让工作区视图与 IDE 文件树保持干净。
