# Ultracode 对抗式审查报告 — FridgeTracker

**项目**: FridgeTracker (/Users/Apple/FridgeTracker)  
**审查日期**: 2026-07-02  
**方法**: 从第一性原理出发 + 对抗式审查（多维度并发思考：数据、时间、通知、Widget、输入、历史闭环、恢复、长期演进）  
**审查者角色**: 恶意用户 + 生产环境故障制造者 + 长期维护者 + 极端边缘用例

## 第一性原理分析

### 本质问题
用户在冰箱里放了易腐物品，却**无法可靠地记住“它什么时候会变坏”**，导致：
- 浪费（过期扔掉）
- 健康风险（吃掉变质物）
- 补货失误（忘记买回常用物）

**根本需求**：以最小摩擦维持对“库存保质期状态”的准确感知，并提供低阻力行动路径（吃掉/扔掉/补货）。

### 核心原语应该是什么？
- **时间到失效（time-to-spoil）** 是中心信号，而不是“添加日期 + 保质期天数”。
- 当前设计把 `expiryDate` 作为一等公民 + `FoodItem` 代表“当前库存”，分离 `FoodDispositionRecord`（历史）和 `ReplenishmentItem`（待买），这个分离是正确的第一性决定。
- 提醒（Notification + Widget）必须是**只读投影**，不能成为权威状态来源。
- 输入必须支持“懒人路径”（OCR + 历史复用）+ “精确路径”（手动）。

### 当前架构是否从本质出发？
**强项**（符合第一性）：
- Widget 只读 JSON 快照 + App Group 松耦合（极好）。
- 业务逻辑下沉到 `FoodItem` / `FoodQuantity` / `ReplenishmentItem`（正确）。
- 历史驱动模板 + 消耗触发补货闭环（直接服务“别忘买”本质）。
- 日期解析有严格合法性校验（拒绝非法日期）。
- 通知使用双时点 + 标识符隔离 + 只清理自家提醒。

**挑战点**（可被第一性攻击）：
- `expiryDate` 是绝对日期，但很多食物保质期实际是“开封后 N 天”或“购买后 N 天”——当前没有“开封日期”概念。
- 数量用自由文本解析（`FoodQuantity`），本质上是“可消耗份数”，但真实世界单位极度多样。
- 历史记录无界增长（长期后会变成性能/隐私负担）。
- 提醒和 Widget 刷新严重依赖“显式 save + 主动调用 refresh”，任何路径遗漏就会产生陈旧信号。

## 对抗式审查发现（按严重度）

### P0 — 立即可能导致数据丢失 / 误提醒 / 崩溃

1. **Widget 快照刷新路径不完备**
   - **场景**：用户在其他 Tab（补货/历史/设置）大量消耗/添加/编辑，或通过深链直接修改后未触发 `WidgetDataStore.refresh`；或 App Group 容器写入失败（权限/空间）。
   - **根因**（第一性）：Widget 数据是只读投影，权威在 SwiftData，但刷新调用点散落在 `ContentView.task` + 各个 save 路径，没有统一的“写后投影”机制。
   - **证据**：`WidgetDataStore.refresh` 只在 `ContentView.task` 和部分保存路径调用；`write` 里有 `try?` 吞错 + logger。
   - **影响**：Widget 显示过期列表、过期天数完全陈旧，用户看到错误提醒或空列表。
   - **建议**：在 `modelContext` 提交后统一 hook（或 SwiftData 的 `didSave` 观察）触发 refresh；把 write 错误提升为可见日志或用户提示。

2. **通知调度与 SwiftData 写操作的竞态**
   - **场景**：快速连续添加/编辑同一食材，或从 Widget 深链打开同时在后台重排；或 `rescheduleAll` 与单个 `scheduleNotification` 并发。
   - **根因**：`scheduleNotification` 直接 `UNUserNotificationCenter.add`，`rescheduleAll` 先 `remove` 再批量 add。没有事务边界。
   - **影响**：重复通知、丢失提醒、或立即 fallback 触发多次。
   - **建议**：所有调度路径串行化（@MainActor 队列或 actor），或在 reschedule 时用原子性 identifier 集合。

3. **App Group 容器首次不可用或跨设备恢复后的静默失效**
   - **场景**：新安装、iCloud 还原、或用户关闭了 App Group 相关权限。
   - **根因**：`FileManager.default.expiringFoodsSnapshotURL` 可能返回 nil，当前代码 `guard let url ... else { return }` 静默失败。
   - **影响**：Widget 永远空，通知深链仍工作但 Widget 不可用。
   - **建议**：首次写入失败时记录并在设置里暴露“Widget 数据同步状态”；考虑提供手动“刷新 Widget”按钮。

### P1 — 高风险 / 常见用户痛点

4. **数量解析与消耗语义的边界攻击**
   - **场景**：
     - 输入 “0.5kg”、“半盒”、“1.5个” → `FoodQuantity.parse` 返回 nil → 按整单位处理。
     - 不同单位合并（1kg + 500g）。
     - `reduceQuantityByOne` 只减 1，剩余 1 时直接移除（但可能用户想只吃一半）。
   - **根因**：`FoodQuantity` 设计为简单 current/total + 单位字符串，本质上假设“可离散计数单位”。
   - **影响**：液体/散装食物记录失真；消耗体验不匹配真实行为。
   - **建议**：明确支持“自由文本数量”（仅显示，不参与计数逻辑）+ “结构化数量”两种模式；或把 reduce 改为更通用的 consume(amount:)。

5. **历史记录与补货记录无界增长 + 无清理策略**
   - **场景**：长期使用（1-2 年）后，`FoodDispositionRecord` 和 `ReplenishmentItem`（包括已完成的）积累成千上万条。
   - **根因**：没有归档/删除策略；`@Query` 全量拉取历史视图；auto-replenish 只查 30 天窗口但记录本身永存。
   - **影响**：SwiftData 查询变慢、备份文件膨胀、隐私（长期记录所有吃过什么）。
   - **建议**：
     - 历史记录按年龄分级（最近 90 天全量，之后只保留聚合统计）。
     - 增加“清理历史”设置（保留 N 天或 N 条）。
     - Replenishment 完成项可软删除或定期归档。

6. **OCR + 日期解析的恶意/畸形输入**
   - **场景**：OCR 读到“2025-13-45”被 `firstValidDate` 拒绝（好）；但读到“生产日期 2026-02-30”、极远未来日期、名称中混入“保质期”等。
   - **根因**：`PackagingTextParser` 有良好拒绝，但 `PackagingOCRConfirmationView` 接受后直接写 `expiryDate`，缺少“明显异常日期”二次确认。
   - **影响**：用户不小心接受了 10 年后过期的日期，或错把批号当日期。
   - **建议**：在确认页对 `expiryDate` 做“距离今天 > 2 年”或“过去日期”的高亮警告 + 默认不勾选。

7. **深链 + pendingDetailID 的冷启动 / 多 Tab 竞态**
   - **场景**：从 Widget 点击打开 app → 深链设置 pending → 但 `allItems` 还空（SwiftData 加载中）或 Tab 不在 Food → 导致 `FoodListView` 守卫失败，详情打不开。
   - **证据**：`FoodListView` 里有 `allItems.count` 变化时重试的逻辑，已有修复痕迹，但仍依赖时机。
   - **建议**：把 pending 路由提升到更高层（ContentView 或 AppDelegate），用更健壮的 SwiftData 加载完成信号。

### P2 — 中低风险 / 体验/维护债务

8. **类别与名称匹配的精确性问题**
   - Auto-replenish 和历史模板严格按 `name ==`。
   - “牛奶” vs “全脂牛奶” vs “纯牛奶” 会视为不同。
   - `nameCandidates` 和建议使用 `normalizedName`（需确认实现）。
   - **建议**：增加模糊匹配或用户可编辑的“同义词”机制（低优先）。

9. **设置变更后提醒重排的副作用**
   - 改 `reminderDaysBefore` 或开关会 `rescheduleAll`，这会移除+重建所有通知。
   - 若此时有 fallback 即时通知逻辑，可能产生意料外 ping。
   - **建议**：重排时跳过 `allowsImmediateFallback`。

10. **Widget 时间线刷新策略过于保守**
    - `Timeline` policy `.after(next day)`，snapshot 固定。
    - 实际 expiry 是动态的（`currentDaysUntilExpiry` 计算），但列表本身一天只更新一次。
    - **建议**：考虑智能 timeline（根据最近到期物品的 expiryDate 动态算下次刷新），或至少在 app 进入前台时强制刷新。

11. **备份/恢复的边界**
    - v2 备份包含 disposition + replenishment，好。
    - 但导入后立即 reschedule 通知，如果大量历史记录导入，可能会一次性调度几百条通知。
    - **建议**：导入后对“即将过期”的子集做增量调度。

## 其他第一性攻击点与建议

- **没有“开封日期”**：很多食物“生产日期 + 保质期” vs “开封后 N 天”完全不同。目前全部靠用户手动调 expiryDate。未来可考虑加“开封标记”字段，动态调整 expiry。
- **单用户假设**：App Group + 本地 SwiftData 没考虑家庭共享或多设备冲突（iCloud sync 仍是 open question）。
- **测试覆盖**：已有大量单元 + snapshot + UI 测试，值得肯定。但 Widget 逻辑主要靠手动验证；OCR parser 有独立 harness 但未进仓库。
- **长期可维护**：代码拆分已做得很好（MVVM + 模型下沉）。最大维护风险是“历史记录膨胀”和“通知/Widget 刷新路径的分散”。

## 推荐行动优先级（本次审查）

**立即（P0）**：
- 统一 Widget 刷新钩子（写后必刷新）。
- 加强 App Group 写入失败处理 + 状态暴露。
- 强化 OCR 确认页的异常日期警告。

**本轮（P1）**：
- 历史/补货记录清理策略 + 性能测试。
- 数量模型增强（或明确“自由文本 vs 计数”两种模式）。
- 深链路由健壮化。

**后续（P2 + 演进）**：
- 动态 Widget 时间线。
- 开封日期 / 使用规则支持。
- 历史归档 + 备份瘦身。

## 验证方法（对抗式）

1. **边界输入**：
   - 添加未来 10 年、过去日期、非法 OCR 日期。
   - 连续 10 次快速消耗同一物品 + 改设置。
   - Widget 分类过滤 + 空列表 + 溢出计数。

2. **故障注入**：
   - 模拟 App Group 写失败（临时改 URL）。
   - 杀掉 app 后立即从 Widget 点击。
   - 切换系统日期到明天/上个月，观察通知和 Widget。

3. **长期模拟**：
   - 导入 500+ 条历史记录，观察查询速度和通知调度。
   - 连续 30 天模拟消耗，验证 auto-replenish 阈值。

4. **恢复路径**：
   - 备份 → 删除 app → 恢复 → 检查 Widget、通知、历史建议。

## 总结

项目**本质契合第一性原理**，解耦、业务逻辑下沉、提醒/Widget 只读投影这些核心决策都站得住脚。过去几次迭代（notification 标识符、shelf life 冻结、深链修复、结构拆分）已经堵了很多明显漏洞。

剩余风险主要集中在**“写后投影一致性”**（Widget/通知）和**“长期数据增长”**上，以及真实世界数量/日期语义的复杂性。

只要把刷新路径收敛、增加历史治理、加强异常日期守卫，这个 app 在生产环境里的可靠性会再上一个台阶。

---
**报告生成**：基于代码、文档、implementation-notes、测试结构综合对抗分析。
**下次审查建议**：在引入 iCloud sync 或重大 schema 变更前再跑一轮。