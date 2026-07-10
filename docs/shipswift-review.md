# ShipSwift 对照式 Code Review — FridgeTracker

> **日期**：2026-07-10
> **方式**：以 ShipSwift 远程 MCP 的 recipe 目录为参照系，逐个建立「我方模块 ↔ recipe」映射，只 review 能映射上的模块；每个映射 `getRecipe` + 通读我方源码 → 输出 P0/P1/P2，并对每条 P0/P1 做一轮对抗式复核（re-read 源码确认属实）后才收录。
> **产物**：本报告仅为 review，不含代码改动。
> **范围约束**：本 app 是 100% 本地/离线（SwiftUI + SwiftData + App Group + 本地 UserNotifications + 端侧 Vision OCR），**无后端、无账号、无内购**。因此凡是 recipe 里的 AWS/Amplify/Cognito/StoreKit/后端层一律**不予采纳**，只抽取可在现有本地架构内落地的客户端经验。

## 结论速览

- **P0：0** — 没有崩溃 / 数据丢失 / 安全类必修项。
- **P1：1 类（两个映射独立命中，均 CONFIRMED）** — 通知权限被系统拒绝后**全程静默**，`开启过期提醒` 开关仍显示 ON，而这是 app 的核心价值（临期提醒）。
- **P2：21** — 打磨 / best-practice / 可访问性类，按模块归档，多数为一行改动。
- 总体：**我方实现普遍比对应 recipe 更健壮**（类型安全、深链校验、OCR 线程与朝向处理、备份版本化与幂等去重、可访问性组合元素等），共记录 **55 条 strengths**。ShipSwift recipe 多为单一职责的演示组件，真正值得反向借鉴的只有少数几处（通知拒绝态兜底、数字滚动/触感、搜索清除按钮、无结果空态、状态色一致性）。

**建议优先级**：先修 P1（通知拒绝态），再顺手处理 `export-share` 那三条数据完整性 P2（都是「静默丢数据/失败被吞」类，虽触发条件少但落在**备份**这种最不该失败的路径上），其余 P2 随迭代打磨。

---

## 1. 功能映射表（已 review）

| # | ShipSwift recipe | tier | 我方模块 | 关键文件 | 结果 |
|---|---|---|---|---|---|
| 1 | `component-root-tab-view` | free | App / Tab 外壳 | `ContentView.swift` · `FridgeTrackerApp.swift` | 4×P2 |
| 2 | `setting` | free | 设置页 | `SettingsView.swift` | **1×P1** |
| 3 | `camera` | free | 相机 + 端侧 OCR 采集 | `AddFoodView.swift` · `ImagePickers.swift` · `PackagingTextParser.swift` | 1×P2 |
| 4 | `component-stepper` | free | 「还有 N 天过期」步进器 | `AddFoodView.swift` | 3×P2 |
| 5 | `component-tab-button` | free | 分类筛选 chip（CategoryChip） | `FoodListView.swift` | 1×P2 |
| 6 | `component-search-bar` | free | 食材搜索 | `FoodListView.swift` · `FoodListViewModel.swift` | 3×P2 |
| 7 | `export-share` | **pro（锁定）** | JSON 备份导入/导出 | `FoodBackup.swift` · `SettingsView.swift` | 3×P2 |
| 8 | `component-onboarding-view` | free | 权限申请时机（无 onboarding） | `NotificationManager.swift` · `AddFoodView.swift` | **1×P1** |
| 9 | `component-status-badge` | free | 临期状态胶囊 | `FoodRowView.swift` · `FoodDetailView.swift` · `ExpiringFoodSnapshot.swift` | 4×P2 |
| 10 | `component-add-sheet` + `component-alert` | free | 添加表单 / 确认交互 | `AddFoodView.swift` · `FoodDetailView.swift` | 2×P2 |

> `export-share` 为 Pro recipe，`getRecipe` 只返回了 overview（源码锁定），因此第 7 项是对照其「已知意图 + iOS best practice」评审，非逐行对照。

## 2. 跳过的 recipe（映射不上 → skip）

| Recipe(s) | 跳过原因 |
|---|---|
| `auth-cognito`、`auth-cognito-anonymous` | app 无账号/登录；且**规则 5**——不引入 Cognito/Amplify |
| `subscription-storekit`（pro） | app 无内购/订阅；且**规则 5**——不引入 StoreKit |
| `infra-cdk` | app 无后端，纯本地/离线 |
| `chat` | 无聊天 / AI 会话功能 |
| `subject-lifting`（pro） | 无抠图/背景移除功能 |
| `tiktok-tracking`（pro） | 无广告归因 / ATT |
| `component-kpi-card` | 无仪表盘 / 指标卡片界面 |
| `chart-*`（9 个：area/bar/donut/line/radar/ring/scatter/heatmap/network-graph） | app 无任何图表 |
| `animation-*`（~40 个 Metal/shader/Canvas 动画） | app 未使用着色器/程序化动画背景 |
| `component-wallet`、`video-player`、`order-view`、`rotating-quote`、`scrolling-faq`、`thinking-indicator`、`markdown-text`、`floating-labels`、`bullet-point-text`、`gradient-divider`、`image-thumbnail`、`label`、`loading`、`before-after-slider` 等 | 对应界面/组件在 app 中不存在 |

---

## 3. Findings

> 位置为 `仓库相对路径:行号`。P1 附对抗式复核结论（CONFIRMED = 复核后属实且严重度合理）。

### P0 — 无

### P1

#### P1-1 · 通知权限被拒后全程静默，核心「临期提醒」形同虚设
- **命中映射**：`setting`、`component-onboarding-view`（两路独立发现，均 **CONFIRMED**）
- **位置**：`FridgeTracker/Views/SettingsView.swift:24`（Toggle）、`:114-121`（onChange 请求权限后丢弃结果）；相关静默路径 `AddFoodView.swift:527`、`SettingsView.swift:234`
- **参照模式**：`component-onboarding-view` 的 "Downstream usage"——权限为 `.denied/.restricted` 时**绝不静默 no-op**，应显式呈现受阻状态并给出跳转 `UIApplication.openSettingsURLString` 的 CTA。
- **问题**：`开启过期提醒` 是 `@AppStorage("notificationsEnabled")` 默认 **true**（`SettingsView.swift:6`），与系统授权状态**相互独立**。当系统通知被拒：
  - onChange 里 `_ = await NotificationManager.shared.requestPermission()` **丢弃返回值**（`:117`），随后 `rescheduleAll` 把提醒排进一个被拒的 center；
  - `requestPermission()` 在 `.denied` 返回 false（`NotificationManager.swift:32-33`），`UNUserNotificationCenter.add` 静默失败（app 自己在 `AddFoodView.swift:524` 的注释已承认此行为）；
  - 首次保存路径 `guard await …requestPermission() else { return }` 同样静默返回（`AddFoodView.swift:527`）。
  - 结果：`提醒` 分区展示了完整的提醒配置 UI（提前天数、分类默认），却**一条通知都不会触发**，用户既无提示也无修复入口。**相机路径已正确处理拒绝态**（`AddFoodView.swift:131-140` 的「前往设置」弹窗），所以通知这里是明显的不一致缺口。
- **建议（本地可落地，无新依赖）**：在 `SettingsView` 的 `提醒` 分区读取真实授权状态（`NotificationManager` 已暴露 `isAuthorized()` @ `NotificationManager.swift:37-40`，可再暴露原始 status/denied 标志），当「开关 ON 但未授权」时展示一行说明 + 「前往设置」按钮（复用 `AddFoodView.swift:131-140` 那套 `openSettingsURLString`）；并可在 `.onAppear` 与切换后同步一次状态，避免开关显示 ON 却失效。
- **严重度说明**：非 P0（无崩溃/数据丢失），但高于 P2 打磨——app 首要功能可**静默失效且无自救路径**，故 P1。

---

### P2 — 按模块归档

#### App / Tab 外壳（`component-root-tab-view`）
| # | 标题 | 位置 | 要点 | 建议 |
|---|---|---|---|---|
| P2-1 | 无法解析的 URL 也会强切到食材 Tab | `ContentView.swift:51` | `.onOpenURL` 先无条件 `selectedTab = .food` 再判断是否有效路由；`fridgetracker://settings`、无 UUID 等会把用户甩到空的食材页 | 把 `selectedTab = .food` 移进 `if case let .foodDetail(id) = AppRoute(url:)` 块内，无效 URL 不动当前 Tab |
| P2-2 | 切 Tab 无触感反馈 | `ContentView.swift:104` | recipe 用 `.sensoryFeedback(.increase, trigger:)` | 加 `.sensoryFeedback(.selection, trigger: selectedTab)` |
| P2-3 | 仍用 legacy `.tabItem`+`.tag` 而非 iOS 18 `Tab(value:)` | `ContentView.swift:79` | 非 bug；iOS 26 目标下新 API 更前向兼容（`Tab(role:.search)`、`TabSection` 等） | 可选现代化迁移，行为不变，低优先 |
| P2-4 | History Tab 图标无 `.fill` 变体，选中态不一致 | `ContentView.swift:23` | `clock.arrow.circlepath` 无 fill；其余三个有，选中时只有它不填充 | 换成有 fill 的符号，或对该 Tab 显式切换图标；上机核对四个选中态一致 |

#### 相机 + OCR（`camera`）
| # | 标题 | 位置 | 要点 | 建议 |
|---|---|---|---|---|
| P2-5 | 一次性 OCR 仍用 legacy `VNRecognizeTextRequest`+手写 GCD | `AddFoodView.swift:408-438` | 线程处理**正确**，只是可用 iOS 18+ 的 async `RecognizeTextRequest`/`try await perform(on:orientation:)` 替掉两处手动 dispatch | 可选现代化，无行为变化，非缺陷 |

#### 「还有 N 天过期」步进器（`component-stepper`）
| # | 标题 | 位置 | 要点 | 建议 |
|---|---|---|---|---|
| P2-6 | 天数变化无 numericText 滚动动画 | `AddFoodView.swift:279` | 注意：native Stepper 变更不在动画事务内，`contentTransition` 需搭配 `.animation(value:)` 才生效 | 给 label Text 加 `.contentTransition(.numericText())` + `.animation(.default, value: 天数)` |
| P2-7 | 步进 +/- 无触感 | `AddFoodView.swift:278` | recipe `.sensoryFeedback(.increase, trigger:)` | 加同款；注意该 trigger 亦会在 DatePicker 跨天时触发，若要仅步进触感需用独立 trigger |
| P2-8 | 数字烘进 a11y label 而非 accessibilityValue | `AddFoodView.swift:281` | VoiceOver 每次调整重念整句；低优先 | 可加 `.accessibilityValue("\(天数) 天")` |

#### 分类筛选 chip（`component-tab-button`）
| # | 标题 | 位置 | 要点 | 建议 |
|---|---|---|---|---|
| P2-9 | 选中 chip 未暴露 `.isSelected` 可访问性 trait（原评 P1，复核 **ADJUSTED→P2**） | `FoodListView.swift:213` | 选中仅靠配色传达，VoiceOver 对所有 chip 念法一致，听不出当前筛选；但仍可从下方列表间接感知 | 加 `.accessibilityAddTraits(isSelected ? .isSelected : [])`，一行、无视觉变化 |

#### 食材搜索（`component-search-bar`）
| # | 标题 | 位置 | 要点 | 建议 |
|---|---|---|---|---|
| P2-10 | 搜索框无清除按钮 | `FoodListView.swift:69` | 自定义 TextField 无 `.searchable` 自带的一键清除，需逐字删 | HStack 内加条件显示的 `xmark.circle.fill` 清除按钮 |
| P2-11 | 无结果时空态误导「点 + 添加食材」 | `FoodListView.swift:152` | 搜索/筛选无命中时也复用「暂无食材」文案，指引错误 | 分支：搜索非空用 `ContentUnavailableView.search(text:)`，仅分类筛选时给「无匹配」，真空库才保留原文案 |
| P2-12 | 匹配仅 case-insensitive，未折叠变音/全半角 | `FoodListViewModel.swift:22` | CJK app 里全/半角、变音符常见，合法匹配会静默漏 | 改 `localizedStandardContains`（与系统搜索一致） |

#### JSON 备份导入/导出（`export-share`，pro 锁定）— 数据完整性，建议优先
| # | 标题 | 位置 | 要点 | 建议 |
|---|---|---|---|---|
| P2-13 | 保存失败时导入仍报「导入完成」 | `SettingsView.swift:231` | importBackup 自身不 `save()`，靠 `WidgetDataStore.refresh` 的 `try? modelContext.save()`（`WidgetDataStore.swift:24`）兜底；refresh 只在 **fetch** 抛错时记失败，**save** 抛错被吞。容器错误/磁盘满时用户以为恢复成功，下次启动数据没了 | 三个 insert 循环后、设成功文案前，在 do 块内显式 `try modelContext.save()`，失败改报「导入失败」 |
| P2-14 | 导出可能静默产出不完整备份却标「导出完成」 | `SettingsView.swift:82` | 处置记录/补货用 `(try? fetch) ?? []`，任一 fetch 抛错则该类**整块被丢**，`.fileExporter` 仍报 success | 用 do/catch 包裹 fetch，失败时报导出失败/部分并不再弹导出器 |
| P2-15 | 导入自建 decoder 而非复用 `FoodBackupDocument.decode` | `SettingsView.swift:184` | 现有两个独立 decode 站点 + 一个 encode 站点；若日后改 encode 日期策略，此手写 importer 会静默沿用旧策略 → 重蹈 typeMismatch | 改为 `try FoodBackupDocument.decode(from: data)`，encode/decode 单一真源 |

#### 临期状态胶囊（`component-status-badge`）
| # | 标题 | 位置 | 要点 | 建议 |
|---|---|---|---|---|
| P2-16 | 中号 Widget 丢掉语义紧急色（与其它所有面) | `FridgeTrackerWidget.swift:311` | 中号行 expiry 用 `.secondary` 灰，过期与新鲜同色；app 行/详情胶囊/小号/大号都用 red/orange/green。中号是最常用、最讲究一眼可读的尺寸 | `!isLarge` 时改用 `statusColor`（对齐 `:236`），至少让过期红保留 |
| P2-17 | VoiceOver label 漏掉数量 | `FoodRowView.swift:41` | `:24` 视觉展示了「分类·数量」，但 `:40` combine 后 `:41` 覆盖 label 只念「名称·分类·临期」，数量丢失 | 有数量时拼进 accessibilityLabel |
| P2-18 | 详情胶囊无描边，暗色下 0.15 填充近乎消失 | `FoodDetailView.swift:47` | recipe 用 tint×0.35 的 0.5pt 描边保证明暗都可辨 | 加 `.overlay(Capsule().stroke(expiryColor.opacity(0.35), lineWidth: 0.5))` |
| P2-19 | 原生 system orange/green 作正文可能低于 WCAG 对比 | `ExpiringFoodSnapshot.swift:18` | 已被「状态永远配文字」大幅缓解，色盲/低视力仍能读全 | 低优先；如收紧，换更深 asset 色或配 SF Symbol |

#### 添加表单 / 确认交互（`component-add-sheet` + `component-alert`）
| # | 标题 | 位置 | 要点 | 建议 |
|---|---|---|---|---|
| P2-20 | 添加/编辑 sheet 无误滑关闭保护，输入会静默丢失 | `AddFoodView.swift:56` | 数据录入 sheet 未加 `.interactiveDismissDisabled`，填到一半下滑即丢 | 加脏标志 `hasUnsavedChanges` + `.interactiveDismissDisabled(...)` 或下滑时弹丢弃确认；保留工具栏 Cancel 作显式出口 |
| P2-21 | 内联成功提示可能滚出可视区 | `FoodDetailView.swift:132` | 成功文案在滚动 VStack 底部，滚动后点「加入补货」可能看不到，2.5s 计时器已过 | 可选：改用 `.overlay(alignment:.top)` toast，复用现有 token-guarded 计时器（不必引入全局单例） |

---

## 4. 值得保留的既有优势（对照中确认「我们做得更好」）

对照普遍显示 recipe 是**更简的单一职责演示**，而我方实现更成熟。摘录跨模块最有价值的几条（完整 55 条见各 agent 结果）：

- **类型安全 & 深链**：`FridgeTab: CaseIterable` 枚举驱动 Tab（`ContentView.swift:4-27`）优于 recipe 的裸 `String` tab 值；带 scheme/host/UUID 校验的 `AppRoute(url:)` + 冷启动自愈的 `resolvePendingDetail()`（`FoodListView.swift:166-172`）是 recipe 完全没有的深链层。
- **OCR 工程**：先申请权限再呈现相机、`isSourceTypeAvailable` 兜底模拟器、Vision 在后台队列、完整 8 态朝向映射、`PackagingDateSanity` 拒绝 `2025-13-45` 这类误读（`AddFoodView.swift` / `PackagingTextParser.swift`）——比 recipe 的实时人脸检测更贴合「单拍→端侧文字识别」。
- **步进器**：以 `expiryDate` 为单一真源派生 `Binding<Int>`，结构上消除了与 DatePicker 的漂移/死循环；`Stepper(in: 0...3650)` 双向边界免费，且原生 Stepper 的可访问性优于 recipe 的裸 chevron 按钮。
- **备份**：encode/decode 对称锁 `.iso8601`（附注释记录了曾踩过的 typeMismatch）、`.prettyPrinted+.sortedKeys`、版本化 v1/v2 兼容、uuid 优先 + `name+createdAt` 兜底的幂等去重、security-scoped resource 正确 defer——`export-share` overview 强调的「一致日期编码 + 失败要暴露」我们大体已达成（那三条 P2 是把「失败要暴露」贯彻到 save/fetch 的最后一公里）。
- **状态色**：`expiryStatusColor/Text` 单一真源、双 target 编译，app 与 widget 不会漂移；状态**从不只靠颜色**（永远配全文字），widget 用 `currentDaysUntilExpiry` 实时重算不陈旧；阈值有单测钉死。
- **确认交互**：destructive `ButtonRole` 语义正确、文案区分「按份递减 vs 整项移除」、`isItemAlive` 守卫避免 dismiss 动画期读取已删 `@Model` 崩溃——recipe 均未涉及。

## 5. 规则合规声明

- **规则 4（只出报告）**：本文件为唯一产物，未改动任何源码。所有 recommendation 均为建议文本。
- **规则 5（不强推 Amplify/StoreKit）**：`auth-*`、`subscription-storekit`、`infra-cdk`、`tiktok-tracking` 等后端/鉴权/内购 recipe 一律 skip；被 review 的映射中，凡涉及 recipe 的后端/ShareLink/StoreKit 层均**显式不予采纳**，所有 P1/P2 建议都在现有本地架构（SwiftData / UserNotifications / Vision / App Group / 系统 fileExporter）内可落地，无一引入新依赖或云服务。

---

### 附：方法与可复现性

- 参照集：ShipSwift MCP `listRecipes`（全量目录，2026-07-10）。
- 每个映射：子 agent `getRecipe(id)` + 通读我方源码 → 结构化 P0/P1/P2 + strengths。
- 对抗式复核：对每条 P0/P1 由独立 agent 重新打开被引用源码逐行核对，**证据不足默认 REFUTED**；本轮 2 条 P1 均 CONFIRMED，1 条原 P1（分类 chip a11y）被诚实下调为 P2。
