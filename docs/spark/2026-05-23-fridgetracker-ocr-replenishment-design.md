# FridgeTracker OCR 与轻量补货闭环设计

## 背景

FridgeTracker 当前定位是“比备忘录更省心的中文冰箱临期提醒工具”。现有能力包括 SwiftData 食材库存、分类与存储区域、历史复添、通知调度、Widget 快照刷新、设置页导入导出。

本阶段只吸收 FridgeBuddy 中与降低录入成本、减少食物过期、形成轻量采购闭环直接相关的能力，不追求完整家庭库存系统。

## 目标

1. 在添加食材时提供“拍包装识别”入口，使用本地 OCR 从包装标签图片中提取食材名称和到期日期候选。
2. OCR 结果进入确认 / 编辑流程，只预填 AddFoodView 表单，不自动保存。
3. 在食材详情页提供“吃掉 / 扔掉 / 加入补货 / 删除”动作。
4. 记录吃掉 / 扔掉处理结果，为未来统计保留数据，但本阶段不做统计仪表盘。
5. 提供补货清单，支持从补货项重新打开 AddFoodView 并预填字段，保存成功后完成该补货项。

## 非目标

- 不重做条形码扫描。
- 不接入商品数据库。
- 不使用云端 AI 或云端 OCR。
- 不做拍冰箱实物识别。
- 不做全自动入库。
- 不做家庭共享、多人协作、成员权限或 iCloud household sharing。
- 不做完整购物系统，不包含价格、商店、预算、优惠、采购路线、商超分类。
- 不做 Nutri-Score / Green-Score / 营养评分。
- 不做复杂浪费统计仪表盘。
- 不修改现有 FoodItem 模型。
- 不破坏 Widget 快照刷新、通知调度、历史复添和数据导入导出。

## 选定方案

采用“新增补货 Tab + 新增轻量 SwiftData 模型 + 本地 Vision OCR 确认流”。

用户确认选择新增补货 Tab。虽然默认约束倾向不破坏现有 `食材 / 历史 / 设置` 架构，但补货项是独立于当前库存和历史复添的生命周期列表：它既不是库存中的 FoodItem，也不是只读历史模板。新增“补货”Tab 可以让“待补货 → 重新添加 → 完成”的闭环清晰可见，避免把待办列表藏在历史页或塞进库存列表。

主 Tab 变为：

1. 食材
2. 补货
3. 历史
4. 设置

## 数据模型

### FoodItem

保持不变，仍只表示当前库存中的食材。

### FoodDispositionRecord

新增 SwiftData 模型，用于记录语义化处理结果。

字段：

- `uuid: UUID`
- `foodName: String`
- `category: FoodCategory`
- `storageZone: StorageZone`
- `customIcon: String?`
- `quantity: String?`
- `purchaseDate: Date?`
- `expiryDate: Date`
- `shelfLifeDaysEstimate: Int`
- `action: FoodDispositionAction`
- `createdAt: Date`

`FoodDispositionAction`：

- `consumed`：吃掉
- `discarded`：扔掉

处理记录复制原 FoodItem 的必要字段，而不是引用 FoodItem。原因是吃掉 / 扔掉后 FoodItem 会从库存删除，记录需要独立保留。

### ReplenishmentItem

新增 SwiftData 模型，用于表示待补货项。

字段：

- `uuid: UUID`
- `name: String`
- `category: FoodCategory`
- `storageZone: StorageZone`
- `customIcon: String?`
- `quantity: String?`
- `notes: String?`
- `defaultShelfLifeDays: Int`
- `createdAt: Date`
- `completedAt: Date?`

待补货列表只展示 `completedAt == nil` 的项目。重新添加保存成功后设置 `completedAt = Date()`，而不是删除补货项，以保留未来统计或复盘可能性。

## App 容器

`FridgeTrackerApp` 的 SwiftData 容器需要包含：

- `FoodItem.self`
- `FoodDispositionRecord.self`
- `ReplenishmentItem.self`

这是必要模型扩展，不改变 FoodItem 字段。

## OCR 设计

### 入口

在 `AddFoodView` 的表单顶部或“食材信息”Section 内新增清晰入口：`拍包装识别`。

入口触发图片来源选择：

- 拍照
- 从相册选择

相机 / 相册使用系统能力。OCR 使用 Apple Vision `VNRecognizeTextRequest`，识别语言优先包含简体中文和英文。本阶段不接云端 OCR、不上传图片、不接 AI 图片理解。

### OCR 服务边界

新增轻量工具：

- `PackagingOCRService`：输入图片，输出识别文本行。
- `PackagingTextParser`：输入文本行，输出名称候选和日期候选。
- `PackagingOCRResult`：承载候选结果和原始识别文本。

服务与解析逻辑保持可单独测试，UI 只负责取图、展示候选和填表。

### 日期解析规则

必须支持：

1. `保质期至 2026.05.30` → 2026-05-30
2. `有效期至 2026-05-30` → 2026-05-30
3. `生产日期 2026.05.01，保质期 30 天` → 2026-05-31

第一版日期规则：

- 直接到期关键词：`保质期至`、`有效期至`、`最佳食用日期`、`到期日`、`EXP`。
- 日期格式：`yyyy.MM.dd`、`yyyy-MM-dd`、`yyyy/MM/dd`、`yyyy年M月d日`。
- 生产日期 + 保质期：识别生产日期，再识别 `保质期 N 天` / `保质期 N 日` / `保质期 N 个月`。月份按 Calendar 增加月数，不按固定 30 天。
- 同时出现多个直接到期日期时，优先使用带到期关键词的日期；仍在确认页允许用户修改。

### 名称解析规则

第一版做规则候选，不做商品库或 AI 推断。

候选选择逻辑：

- 排除包含以下关键词的行：`营养成分表`、`配料`、`生产日期`、`保质期`、`有效期`、`净含量`、`执行标准`、`许可证编号`、`贮存条件`、`厂家`、`地址`、`电话`、`能量`、`蛋白质`。
- 排除纯数字、日期、条码、过短行。
- 优先较靠前、长度适中、中文字符占比较高的行。
- 最多展示少量名称候选；没有可靠候选时保持名称为空。

### 确认流程

OCR 完成后弹出确认 sheet：

- 显示可编辑食材名称候选。
- 显示可编辑到期日期候选。
- 显示原始识别文本的折叠预览或只读文本区域，帮助用户判断。
- 用户点击“填入表单”后，才写入 AddFoodView 的 `name` 和 `expiryDate` 状态。
- 用户点击取消或 OCR 失败时，回到原 AddFoodView 手动输入流程。
- 填表后仍必须由用户点击 AddFoodView 的“保存”创建 FoodItem。

### 错误状态

- 用户取消拍照 / 选图：不改变表单。
- OCR 失败：提示识别失败，表单保持可手动输入。
- 未识别出名称：名称字段不填，用户手动输入。
- 未识别出日期：日期保持当前默认值，用户手动修改。

## 补货闭环设计

### 食材详情页动作

`FoodDetailView` 的底部动作变为：

- 编辑
- 吃掉
- 扔掉
- 加入补货
- 删除

其中用户验收关注的是“吃掉 / 扔掉 / 加入补货 / 删除”语义必须清晰存在；编辑保留为常规维护动作。

### 吃掉

用户选择“吃掉”后：

1. 弹出确认。
2. 创建 `FoodDispositionRecord(action: .consumed)`，复制当前 FoodItem 的必要字段。
3. 取消该 FoodItem 的通知。
4. 从 SwiftData 删除该 FoodItem。
5. 调用 `WidgetDataStore.refresh(using:)`。
6. 返回上一页。

### 扔掉

用户选择“扔掉”后：

1. 弹出确认。
2. 创建 `FoodDispositionRecord(action: .discarded)`。
3. 取消通知。
4. 删除 FoodItem。
5. 刷新 Widget。
6. 返回上一页。

### 加入补货

用户选择“加入补货”后：

1. 创建 `ReplenishmentItem`，复制当前 FoodItem 的名称、分类、存储区域、显示图标、数量、备注和 `shelfLifeDaysEstimate`。
2. 不删除当前 FoodItem。
3. 不取消通知。
4. 不刷新 Widget，因为当前库存未变化。
5. 给出轻提示或状态反馈。

如果同名未完成补货项已存在，第一版可以避免重复插入，改为保留原待补货项并提示已在补货清单中。

### 删除

删除仍作为破坏性低频操作存在：

1. 弹出破坏性确认。
2. 取消通知。
3. 删除 FoodItem。
4. 刷新 Widget。
5. 不创建处理记录。

## 补货 Tab

新增 `ReplenishmentListView`。

列表展示 `completedAt == nil` 的补货项：

- 图标
- 名称
- 分类
- 存储区域
- 数量
- 估算保质期天数

点击补货项后打开 `AddFoodView(template:onSave:)`。

模板字段来自 ReplenishmentItem：

- name
- category
- storageZone
- customIcon
- quantity
- notes
- defaultShelfLifeDays

AddFoodView 仍按模板逻辑把到期日重算为“今天 + defaultShelfLifeDays”。用户确认保存成功后，`onSave` 将该 ReplenishmentItem 标记为完成。

补货项不会自动创建 FoodItem；保存语义仍完全由用户确认。

## 与现有流程的关系

### 历史复添

历史页仍从现有 FoodItem 记录生成 FoodTemplate。本阶段不把 ReplenishmentItem 合并进历史页，避免历史和待办语义混淆。

### 通知调度

只有 FoodItem 创建、编辑、删除、吃掉、扔掉会影响通知：

- 新增 / 编辑继续沿用 AddFoodView 的现有调度。
- 吃掉 / 扔掉 / 删除都取消原通知。
- 加入补货不影响通知。

### Widget 刷新

只有当前库存变化时刷新 Widget：

- AddFoodView 保存刷新。
- 吃掉 / 扔掉 / 删除刷新。
- 加入补货不刷新。
- 补货项完成本身不刷新；重新添加保存会通过 AddFoodView 现有逻辑刷新。

### 数据导入导出

现有设置页导入导出必须继续兼容 FoodItem 备份格式，不能因为新增模型而破坏已有 JSON 导入导出路径。第一版不把处理记录和补货项纳入现有备份文件，避免扩大备份格式范围；新增模型备份不进入本阶段验收。

## 验收标准

### OCR

- App 能通过 xcodebuild 构建。
- AddFoodView 中存在清晰的“拍包装识别”入口。
- OCR 使用 Apple 本地 Vision 能力，不依赖云端 OCR / AI。
- OCR 结果不会自动保存，只进入确认 / 编辑流程。
- 日期解析能覆盖：
  - `保质期至 2026.05.30`
  - `有效期至 2026-05-30`
  - `生产日期 2026.05.01，保质期 30 天`
- 能从包装 OCR 文本中提取合理名称候选，并允许用户修改。
- OCR 失败、未识别名称、未识别日期时不影响手动添加流程。
- 历史复添、分类选择、自定义图标、通知调度、Widget 刷新不被破坏。

### 补货闭环

- 食材详情页存在清晰的“吃掉 / 扔掉 / 加入补货 / 删除”动作。
- 吃掉会移除当前库存 FoodItem，并创建 consumed 处理记录。
- 扔掉会移除当前库存 FoodItem，并创建 discarded 处理记录。
- 加入补货会创建待补货项，不影响当前 FoodItem。
- 补货 Tab 能展示待补货项目。
- 用户能从补货项打开 AddFoodView，并复用名称、分类、存储区域、显示图标、数量、备注和保质期估算。
- 从补货项重新添加后仍由用户手动保存。
- 保存成功后补货项标记完成，不再出现在待补货列表。
- 删除保留为破坏性操作，且不替代吃掉 / 扔掉。

## 测试与验证计划

1. 为 `PackagingTextParser` 增加聚焦验证代码或测试，覆盖 3 条日期样本文本和名称候选排除规则。
2. 运行 xcodebuild 构建 FridgeTracker 主 App。
3. 人工检查 AddFoodView 是否有“拍包装识别”入口，且确认 sheet 不会自动保存。
4. 人工检查 FoodDetailView 动作是否包含吃掉 / 扔掉 / 加入补货 / 删除。
5. 人工走通补货闭环：加入补货 → 补货 Tab 展示 → 点击预填 AddFoodView → 保存 → 补货项完成。
6. 人工回归现有路径：普通添加、历史复添、编辑、删除、Widget 刷新、通知调度调用路径。

## 实施边界

优先修改或新增：

- `FridgeTracker/Views/AddFoodView.swift`
- `FridgeTracker/Views/FoodDetailView.swift`
- `FridgeTracker/Views/ContentView.swift`
- `FridgeTracker/App/FridgeTrackerApp.swift`
- OCR service/parser 文件
- 新增模型文件
- 新增补货清单 View
- 必要的 Xcode project 引用和权限配置

不修改 Widget，除非库存保存 / 移除路径变化导致 Widget 刷新必须同步修复。

## 已知取舍

- 新增补货 Tab 会改变主信息架构，但这是用户确认的选择。它让补货闭环成为独立高可见路径，代价是底部导航从 3 项变 4 项。
- 处理记录和补货项新增 SwiftData 模型，而不是复用 FoodItem。这样可以保持 FoodItem 只表示当前库存，代价是需要扩展模型容器。
- 第一版导入导出不覆盖新增模型，避免备份格式扩张。代价是补货项和处理记录暂不随现有 JSON 备份迁移。
- 名称识别使用规则候选，不追求全自动准确。这样符合确认式 OCR 和轻量定位。
