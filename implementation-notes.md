# Implementation Notes

## Design Decisions

- The Widget category selector is implemented with `AppIntentConfiguration` instead of a custom in-app settings screen, because iOS exposes Widget per-instance settings through App Intents and this gives users the expected long-press/edit Widget menu.
- The baking/bread use case is represented as a single `烘焙` category rather than adding a narrower bread-only category. This keeps category filtering useful without adding another menu level.
- Widget providers now pass the full sorted filtered item list to the view; each family still caps visible rows locally, which lets the Widget show an overflow line such as `还有 N 项`.
- Widgets show a compact category badge in the header so category-specific Widget instances remain visually distinguishable after configuration.
- The Widget snapshot cache now keeps a bounded larger list before filtering by category. Filtering after the old six-item cache could make a category-specific Widget appear empty even when matching items existed later in the inventory.
- The bottom navigation is restored to a plain native SwiftUI `TabView(selection:)` with `.tabItem`/`.tag`, without custom tab bar drawing or iOS 26 tab bar minimization behavior.
- Historical suggestion overrides are stored as a small Codable dictionary in UserDefaults instead of adding a new SwiftData model. This avoids migration and project-reference risk while keeping real `FoodItem` history unchanged.
- The historical suggestion manager only edits per-name reuse defaults and hidden state. It does not change `FoodCategory` into a dynamic tag system and does not mutate existing `FoodItem` records.
- Hidden historical suggestions are treated as disabled reuse entries: they are removed from the Recent and History suggestion lists and are not auto-applied when typing the same name. This keeps the hidden behavior consistent across all suggestion surfaces.
- Runtime UI verification showed that mutating the published overrides dictionary in place did not reliably refresh the management list after saving. `HistorySuggestionStore` now assigns a copied dictionary on save/remove so SwiftUI observes the state change.
- For the OCR + replenishment phase, the user approved adding a dedicated `补货` Tab even though the earlier constraint preferred preserving the three-tab structure. The reason is that pending replenishment is a separate lifecycle list, not current inventory and not read-only history.
- The OCR + replenishment implementation will keep `FoodItem` unchanged and add separate SwiftData models for disposition records and replenishment items. This preserves the meaning of `FoodItem` as current inventory only.
- The Widget uses an App Group JSON snapshot instead of reading SwiftData directly. This keeps the extension independent from the app's SwiftData container and makes the first Widget version easier to build and debug.
- Widget rows use category emoji as the primary visual cue; storage zone stays available in the snapshot but is only rendered as secondary text in Large widgets.
- `FoodItem.customIcon` is an optional per-item override. App rows, detail headers, and Widget snapshots render `customIcon ?? category.icon` while category filters still use category-level icons.
- Common food templates start from historical food entries when available, falling back to a small static list. This avoids template CRUD while making suggestions adapt to the user's actual purchases.
- Notification scheduling now treats the settings value `-1` as category defaults and skips scheduling when the trigger date has already passed, which keeps expired-item cleanup from becoming repeated notification noise.
- Barcode scanning was removed in favor of same-name history reuse: typing an existing food name auto-fills reusable fields from the latest matching record while keeping the new expiry date editable.
- The History page is treated as a generated library from existing `FoodItem` records rather than a separate template model, so reuse stays consistent with actual purchases and avoids model migration.
- History and Settings were added inside existing Swift source files instead of creating new files, because the project uses explicit Xcode project references and this keeps the change focused.
- After moving Add Food into a bottom tab, successful saves and cancels now recreate the Add form and select the Food tab because `dismiss()` only works for sheet/navigation presentations and would leave the root Add tab filled with stale state.
- Widget expiry status is now derived from `expiryDate` at render/timeline time instead of trusting the serialized `daysUntilExpiry` cache. The cache could go stale after midnight even when the Widget timeline refreshed.

- Widget row taps use item UUID deep links (`fridgetracker://food/<uuid>`) because `ExpiringFoodSnapshot.id` already mirrors `FoodItem.uuid`.
- The widget background/header uses `fridgetracker://food` as a safe fallback to open the Food tab without selecting an item.
- The app now uses an explicit app `Info.plist` rather than generated Info.plist settings, because `CFBundleURLTypes` did not register reliably through the generated build setting path.

## Deviations

- For free Personal Team device deployment, bundle IDs and App Group identifiers were changed from `com.example.*` to `com.congee.*`, and the Widget bundle ID now uses the app bundle ID as its required prefix.

## Tradeoffs

- Camera presentation was changed from a sheet to a full-screen cover while keeping the existing `UIImagePickerController` bridge. The album path keeps SwiftUI `PhotosPicker` so it opens the system photo picker and preserves the existing OCR pipeline with minimal code churn.
- The AppIcon source was generated as a single 1024px universal iOS icon in a new asset catalog because the project did not previously include an `Assets.xcassets` reference despite declaring `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.

- OCR parser code was added as a separate utility file, while the camera/photo picker and confirmation UI live in `AddFoodView.swift`. This keeps parser validation isolated without adding more Xcode project references than necessary.
- The Widget shows the earliest-expiring items from a cached snapshot. It may briefly lag behind SwiftData if a write fails, but app save/delete paths explicitly refresh the snapshot and Widget timelines.

## Open Questions

- iCloud sync or backup is still a next phase rather than part of this iteration. The minimum viable path is to decide between SwiftData CloudKit sync for automatic multi-device use and a manual JSON export/import for simple personal backup.

---

# Optimization Pass — 2026-06-01 (H/M/L batches)

Agent-driven code review (two read-only Explore agents) surfaced 16 findings; user approved applying all three batches. Edits applied by four file-disjoint subagents over a fresh git baseline. This section records only material decisions/deviations/tradeoffs, not the per-change diff.

## Design Decisions

- **Shelf-life estimate is frozen at creation, not recomputed daily.** `FoodItem` gains an optional `originalShelfLifeDays` set in `init`. `shelfLifeDaysEstimate` now returns the purchase→expiry span when a purchase date exists, else the frozen `originalShelfLifeDays`, else (legacy rows with neither) the old `max(daysUntilExpiry, 1)` fallback. This stops history templates / replenishment defaults from shrinking by one day each day. Adding an optional SwiftData property is a lightweight automatic migration (no version bump).
- **Notifications fire at 09:00 local.** The trigger date is built from the year/month/day of `expiryDate − daysBefore` with `hour = 9, minute = 0`, then guarded as future. Previously the trigger inherited `expiryDate`'s 00:00 components and fired at midnight.
- **Settings changes now reschedule.** `NotificationManager.rescheduleAll(for:)` removes all pending requests and re-schedules from the current item set; `SettingsView` calls it when `notificationsEnabled` / `reminderDaysBefore` change (and requests authorization when enabling).
- **Deep-link resolution waits for the SwiftData query to load.** `FoodListView` only clears `pendingDetailID` once `allItems` is non-empty, and also re-attempts on `allItems.count` change, fixing the cold-launch-from-widget race where the detail screen silently failed to open.
- **Expiry text + color are deduplicated through two free functions** (`expiryStatusText(daysUntilExpiry:)`, `expiryStatusColor(daysUntilExpiry:)`) placed in the App/Widget-shared `ExpiringFoodSnapshot.swift`. App rows, detail header, snapshot, and both widget call sites now route through them. App's previous `isExpired`/`isExpiringSoon` color thresholds are identical to `<0 / <=3`, so behavior is unchanged.
- **Replenishment insert logic is centralized on `ReplenishmentItem`** (`autoReplenishThreshold`, `addIfAbsent(for:in:)`, `autoAddIfNeeded(for:in:)`). `FoodListView`, `FoodDetailView`, and `ContentView.generateFromHistory` all consume these instead of three local copies. The existing threshold semantics (consumed record is inserted before the count check, so the 2nd consume triggers auto-replenish) are preserved intentionally — only the duplication is removed.

## Deviations

- **L1 (split AddFoodView) was scoped to in-file extraction only.** The 677-line file's `body` is broken into private `…Section` computed views inside the same file; `FoodTemplate` / `HistorySuggestionStore` / OCR helper views were NOT moved to new files. Creating new `.swift` files requires hand-editing `project.pbxproj`, which the project history repeatedly flags as risky and which has no behavioral payoff. Type relocation remains available as a separate, opt-in refactor.

## Tradeoffs

- **WidgetDataStore file I/O stays synchronous on `@MainActor`.** Making it `async`/detached was considered (agent finding) but rejected: the payload is ≤50 small structs (sub-millisecond write), callers don't await, and re-ordering the write vs. `reloadAllTimelines()` introduces real concurrency risk for marginal benefit. Only the redundant second sort was removed, and items expired more than 14 days are dropped before the 50-item cap to reduce stale clutter in category widgets.
- **M3 (template caching) caches the `FoodTemplate.fromHistory(existingItems)` scan in `@State`, recomputed on appear / `existingItems.count` change / overrides change** rather than on every `body` evaluation/keystroke. Edits that change an existing item's fields without changing the count are picked up on the next sheet appearance, not instantly — an acceptable staleness tradeoff for removing the per-keystroke O(n) scan.
- **L4: the Settings "显示" section** was made honestly informational rather than wiring a new persisted sort setting — list sorting is already user-controlled via the food list's sort menu, so a static "按到期日" row was misleading. No new `@AppStorage` cross-cutting into the view model was introduced.

## Open Questions (this pass)

- Whether to make home sort a real persisted setting (currently per-list, ephemeral) and surface it in Settings — deferred, would touch `FoodListViewModel`.
- Whether `originalShelfLifeDays` should also update when a user edits `expiryDate` without a purchase date (currently frozen at creation).

---

# Feature — 2026-06-01: "xx 天后过期" entry in AddFoodView

## Design Decisions

- The 日期 section gains a `Stepper` that sets expiry by day count, alongside the existing date picker. It is wired through a computed `Binding<Int>` (`expiryDaysBinding`) over the single source of truth `expiryDate` — no extra `@State`, so the two controls stay in two-way sync without onChange feedback loops.
- The day count's reference point is adaptive: it counts from the purchase date when 记录购买日期 is on and set, otherwise from today. The label reflects this — "保质期 N 天" (from purchase) vs "还有 N 天过期" (from today) — so the number's meaning is always explicit. Toggling the purchase date recomputes the displayed count against the new base while keeping `expiryDate` fixed.
- Range capped at 0...3650 days (10 years), enough for any food shelf life; the binding clamps negatives to 0.

---

# Structure Refactor — 2026-06-07 (H/M priority from README audit)

Executed the high/medium-priority items from the README folder-structure audit. This **completes the file-level type relocation explicitly deferred in the 2026-06-01 pass** — see "L1 … scoped to in-file extraction only" above, which judged that relocating `FoodTemplate` / `HistorySuggestionStore` / OCR helper views to new files was risky pbxproj surgery with no behavioral payoff and should be a separate opt-in refactor. This is that refactor, now done with per-step build verification. Records only material decisions/deviations/tradeoffs, not the per-change diff.

## Design Decisions

- **Disk cleanup and version control are separate problems.** ~4.8 GB of build artifacts (18 stray `DerivedData*` dirs + `build/` + 4 `.xcresult` + 10 logs + 2 `.DS_Store`) were already gitignored — never a repo problem, only disk/navigation noise. Removed via `git clean -fdX` (4.8 GB → 2.5 MB). All builds (baseline + per-step) use Xcode's **default** DerivedData path (`~/Library/...`), never a workspace-local path, so cleanup never invalidates build caches.
- **pbxproj edits are scripted, not hand-typed.** A Python helper inserts each new file into all four required sections (PBXBuildFile, PBXFileReference, group children, app Sources phase) with auto-generated, length-asserted `FACE…` 24-hex IDs, eliminating the hand-counting error that makes manual pbxproj editing fragile. File slicing is content-anchored (locate by `struct X` line prefix), not absolute line numbers, and aborts if an anchor is missing.
- **Per-step build verification** (per user choice): #4 AddFoodView, #5 ContentView, #6+#7 SettingsView/snapshot each ran `xcodebuild … BUILD SUCCEEDED` before the next step; final build confirmed app + widget.

## Deviations

- **`HistorySuggestionStore` + `HistorySuggestionOverride` → existing `Utilities/` group, not a new `Stores/` group.** README offered "Stores/ or Utilities/"; Utilities avoids creating a new PBXGroup (extra surgery) and already houses store-like `WidgetDataStore`.
- **`RecentTemplateChip` stayed in `AddFoodView.swift`.** A 21-line chip used only by the add form; README only required moving the heterogeneous types (model / store / UIKit bridges). AddFoodView still dropped 776 → 501 lines.
- **`ExpiringFoodSnapshot.swift` was annotated, not moved to a `Shared/` directory.** With only one cross-target file, a header comment documenting dual-target membership achieves "name it as shared" at zero pbxproj-path risk. (README presented both; annotation was the lower-risk option.)
- **`implementation-notes.md` stays at repo root** (not moved into `docs/`), per the project's global SOP; the rest of the docs were consolidated into a single `docs/` tree (`design/`, `plans/`, `release-notes/`) with a `docs/README.md` map.
- **`FridgeTrackerUITests/`** (empty, no target, untracked) was `rmdir`-removed rather than backfilled with a test target, since the project has no tests and none were requested.

## Tradeoffs

- **No new test target.** Backfilling a UI Testing bundle is out of scope for a structure cleanup and would add pbxproj surgery for code the user didn't ask for; the empty dir was simply deleted.
- **README's directory tree / assessment were rewritten to the post-optimization state**, with the original problems kept as a resolved record (✅ markers) so the document doesn't silently erase the audit it came from.

## Result

7 new source files (FoodTemplate, HistorySuggestionStore, ImagePickers, PackagingOCRConfirmationView, ReplenishmentListView, HistoryView, FoodBackup); 3 large views slimmed (776→501 / 329→86 / 349→283); docs consolidated; stray pbxproj backup untracked; empty UITests dir removed; workspace 4.8 GB → 2.5 MB. Final `xcodebuild`: **BUILD SUCCEEDED** (app + widget).

---

# Bugfix Batch — 2026-06-10 (full-source review findings)

Full-source review surfaced 5 high / 6 medium / ~13 low findings; user approved clearing all in one PR (branch `fix/code-review-batch`). Pre-existing uncommitted `consumeVerb` work was committed separately first to keep attribution clean. Records only material decisions/deviations/tradeoffs.

## Design Decisions

- **Notification permission is requested at first save, not at app launch.** `AddFoodView.save()` routes scheduling through an async helper: ensure permission → cancel → schedule. Launch only *checks* authorization (`isAuthorized()`) and reschedules if already granted — prompting before the user has done anything is hostile and harms grant rates. Order matters: `UNUserNotificationCenter.add` fails while `.notDetermined`, so permission must resolve before scheduling.
- **Two-stage reminders with an identifier scheme.** Each item now gets `uuid.advance` (expiry − N days, 9:00) and `uuid.expiry` (expiry day, 9:00). `cancelNotification` also removes the legacy bare-`uuid` identifier for migration. `rescheduleAll` no longer calls `removeAllPendingNotificationRequests()`; it removes only identifiers whose prefix parses as a UUID — this still sweeps orphans of deleted items but won't clobber future non-reminder notifications.
- **Missed-window fallback is opt-in per call site (`allowsImmediateFallback`).** Only the *new item* and *merge* paths fire an immediate (+60 s) reminder when both 9:00 slots are already past and the item isn't expired. Edit, settings-toggle, launch and import reschedules deliberately do NOT, so editing an expiring-today item three times can't produce three pings. This supersedes the 2026-06-01 decision "skip scheduling when the trigger date has passed" — the noise concern that motivated it is handled by the opt-in flag instead of by dropping the reminder entirely.
- **History templates aggregate inventory ∪ disposition records, newest wins.** `FoodTemplate.fromHistory(_:records:)` sorts candidates by date desc and dedupes by normalized name internally, so results no longer depend on the caller's `@Query` sort order (this was silently inconsistent between AddFoodView newest-first and Settings oldest-first). Fully-consumed foods now persist in the History tab and same-name auto-fill, matching the empty-state copy's promise.
- **`originalShelfLifeDays` recomputes from `createdAt`, not "today", on edit** (`refreshOriginalShelfLife()`). Resolves the 2026-06-01 open question ("should it update when expiryDate is edited?") with *yes*: using createdAt as the acquisition proxy keeps a months-later typo edit from shrinking the estimate, while expiry edits update it correctly. Same helper restores sane values for v1 backup imports (computed against the item's original createdAt instead of import day).
- **Backup format v2.** Adds `version`, per-item `uuid` + `originalShelfLifeDays`, and full `dispositionRecords` / `replenishmentItems` arrays — justified (not gold-plating) because History now *depends* on disposition records surviving device migration. All new fields optional ⇒ v1 files decode unchanged. Import dedupes by uuid (v1 fallback: name+createdAt natural key) and reschedules notifications afterward — imported items previously had none until manually edited.
- **`FoodDetailView` guards against destroyed models** (`item.modelContext != nil && !item.isDeleted` → else `Color.clear`): body re-evaluation during the post-delete dismiss animation was a live SwiftData crash path.
- **Widget snapshot window is now −14…+30 days.** The widget's stated purpose is "快过期提醒"; a fridge of long-life items now correctly shows the empty state instead of listing items expiring months out.

## Deviations

- **`.badge` authorization dropped instead of implemented.** No code ever set a badge count; per-notification static badge values go stale across multiple items. Removing the unused permission request is the honest fix; real badge support would need delivery-time recomputation (out of scope).
- **Swipe-to-consume stays confirmation-free** (vs. detail view's confirm dialog). The asymmetry is intentional: swipe is the speed path and `allowsFullSwipe: false` already requires a deliberate second tap. Not changed despite being listed as an inconsistency in the review.
- **Decimal/Chinese-numeral quantities ("0.5kg", "一盒") remain unparsed** and are still treated as a single unit on consume (whole item removed). Supporting them means redesigning `FoodQuantity` (Int current/total) and its merge/reduce semantics — deferred as feature work, not a bug fix.
- **No test target added.** Parser/regex changes were verified by a throwaway `swiftc` assertion harness (14 cases, all pass) under `/tmp`, not committed. A real unit-test target requires pbxproj surgery this project's history flags as risky; if wanted, it should be its own pass.

## Tradeoffs

- **Auto-replenish now uses a 30-day window** (was: all-time count), aligning `autoAddIfNeeded` with 「从历史生成」. Threshold semantics otherwise preserved (2nd consume within window triggers).
- **History-name auto-fill no longer overwrites quantity/notes/purchase-date the user already typed**; category/zone/icon/expiry still apply unconditionally — that *is* the feature, and the user watches it happen. Partial-overwrite is a judgment call, documented here.
- **Notification deep link reuses the URL route** (`UIApplication.shared.open(fridgetracker://food/<uuid>)` from the delegate) instead of a parallel in-process routing path — one tested navigation path, slightly indirect.
- **`HistorySuggestionStore.template(for:in:)` left as-is** (pre-existing dead code, zero call sites). Compatible with the new `fromHistory` signature; flagged rather than deleted per surgical-change policy.

## Verification

- Parser assertion harness: 14/14 pass (colon/punctuation tolerance, rollover rejection incl. Feb-30, compact `20251201`, barcode non-match, invalid-then-valid scanning, name candidates).
- `xcodebuild` app + embedded widget: **BUILD SUCCEEDED**, zero warnings.
- Simulator smoke test: launch renders food list; `fridgetracker://food` deep link handled; app process alive throughout; launch-time `.task` (widget refresh + auth check) crash-free.
- NOT runtime-verified (needs interactive use): permission dialog on first save, replenishment sheet close, swipe delete, OCR orientation gains, actual notification delivery timing.

## Open Questions

- Should the immediate fallback reminder (+60 s) instead schedule for the evening (e.g. 20:00) when added during the day? Current choice favors immediacy for soon-expiring purchases.
- Replenishment quantity copies the last record's in-fridge count (e.g. `1/3个`) — arguably should reset to the package total when re-buying.

---

# Ultracode 审查修复批次 — 2026-07-02（P0 全部 + P1 全部）

依据 `ultracode-review-2026-07-02.md` 的推荐行动清单执行：立即（P0）3 项 + 通知竞态轻修，本轮（P1）3 项，后续（P2）仅记录。只记 material 决策/偏离/取舍。

## Design Decisions

- **Widget 写后投影统一为「显式刷新 + didSave 兜底」双层，而不是替换现有调用。** ContentView 监听 `ModelContext.didSave`（iOS 18+ 起 autosave 也会发），300ms debounce 后刷新快照——任何现在或将来的写入路径都被兜住；现有 9 处显式 `WidgetDataStore.refresh` 保留为即时路径。防自激：`refresh` 只在 `modelContext.hasChanges` 时才 save，刷新自身不再触发 didSave。scenePhase 变 active 时也刷新（顺带覆盖 P2-10 报告里"进前台强制刷新"的建议，处理跨天陈旧）。
- **App Group 同步状态记录在 UserDefaults.standard（非 App Group）**，键 `widgetLastSyncTimestamp` / `widgetLastSyncError`——只有 app 进程的设置页读它，widget 不需要。失败信息优先于成功时间展示；「小组件」section 提供手动「立即刷新小组件」按钮（报告 P0-3 建议的两点都落了）。
- **OCR 异常日期采用「警告 + 默认不应用」而非拦截。** `PackagingDateSanity.warning`（纯函数，可单测）判定过去日期 / 超过 2 年的未来日期；确认页异常时显示橙色警告并出现「仍然应用这个保质期」开关（onAppear 时默认关）。`onApply` 改带 Bool：无警告（含用户已把日期改到正常范围）视为确认应用。应用 OCR 日期时先置 `hasUserAdjustedExpiry` 再填名称，防止名称 onChange 触发的历史模板覆盖刚确认的日期。
- **NotificationManager 整类 @MainActor + rescheduleAll 代次守卫。** 所有调度入口与 SwiftData 写操作天然串行；`rescheduleGeneration` 让还挂在 `pendingNotificationRequests()` await 上的旧一轮重排作废（放弃发生在任何删除之前，最新一轮会完整执行删+排，不留半完成状态）。报告 P0-2 的完整事务边界（actor 队列）被判定为过度设计。
- **历史清理默认「永久保留」，删除只由用户显式触发。** `HistoryMaintenance.prune` 删 cutoff 前的处置记录 + cutoff 前完成的补货项；待补货与库存永不删。设置页 picker（永久/90/180/365 天）只设策略；真正删除发生在带确认弹窗的「立即清理」或选定期限后的启动自动清理。边界为严格小于（恰好在 cutoff 的记录保留）。
- **数量双模式显式化而非重建模型。** 沿袭 2026-06-10 的偏离决定（不支持小数/中文数量解析），本轮把隐式行为说明白：AddFoodView 数量输入下实时提示当前模式（按份数计数 vs 自由文本整项移除）；详情页确认弹窗对自由文本数量明说「移除整项并计入历史」，不再沿用「减 1 份」误导。`FoodItem.hasCountableQuantity` 承载判定。
- **深链路由改同步直查，彻底去掉时序依赖。** `FoodItem.find(uuid:in:)` 用 FetchDescriptor 直接查库（fetchLimit 1），`resolvePendingDetail` 不再等 `@Query` 加载、不再靠 `allItems.count` 变化重试；查不到即视为已删并清除 pending。

## Deviations

- **深链未按报告建议"提升到 ContentView/AppDelegate 层"。** fetch 直查后时序问题不存在了，把 NavigationStack 迁到更高层是无收益的大手术。报告目标（健壮化）达成，手段不同。
- **OCR 确认页未做成"字段级勾选"。** 报告说"默认不勾选"，实现为仅异常日期时出现单个开关；正常日期不增加交互负担。
- **报告 P0-2（通知竞态）未做完整 actor 事务边界**，用 @MainActor + 代次守卫的轻量组合覆盖实际风险场景（快速连续编辑、设置连点、导入+改设置交错）。

## Tradeoffs

- **didSave 兜底刷新有 300ms 合并窗口**：批量导入几百条只触发一次整写快照，代价是极端情况下 widget 快照晚 300ms——不可感知。
- **prune 用 fetch-全量-逐删而非 `ModelContext.delete(model:where:)` 批删**：批删谓词对可选 `completedAt` 的支持不稳（Xcode 26 SwiftData #Predicate 限制），fetch 后内存过滤在 3000 条量级实测秒内（有性能测试锁定上界 5s）。
- **清理策略会同步缩小「历史」页建议和自动补货统计的样本窗口**（它们由处置记录驱动）——这是用户选择保留期的自然含义，caption 里写明。
- **@AppStorage 与 `HistoryMaintenance.retentionDays` 双读路径**（视图绑定 vs 启动清理）共享同一键、同一默认值 -1，未抽公共访问器——两处常量相邻可见，抽象不划算。

## Adversarial Review（五路镜头 + 逐条反驳验证，18 agents）

13 条发现 → 确认 10（去重后 8 个独立问题，全部 P2）→ **全部当场修复**；驳回 3。确认项及处置：

1. **rescheduleAll 的 await 窗口内被删除的 @Model 会被访问**（崩溃/孤儿通知）→ 循环加存活过滤 `modelContext != nil && !isDeleted`（沿用 FoodDetailView 的既有范式）。
2. **-uitesting 隔离不完整**：didSave→refresh 管道让 UI 测试把内存假数据写进真实 App Group 快照 + WidgetCenter reload + UserDefaults 同步状态 → WidgetDataStore.refresh/scheduleRefresh 统一短路 `-uitesting`（单一咽喉点，覆盖启动/didSave/scenePhase/手动全部入口，也顺带修掉上一批遗留的启动空快照污染）。
3. **refresh 的 fetch 失败分支不记状态**，设置页停留在「同步正常」假象 → 改 do/catch 调 recordSyncFailure（注：另一路 verifier 认为该场景现实不可达而驳回同一发现；采纳修复因为它是三条失败路径中唯一不对称的一条，一行成本换状态语义完整）。
4. **单测把 historyRetentionDays 写进宿主 app 真实 UserDefaults.standard**（TEST_HOST 注入 + 无 -uitesting + 启动 pruneIfEnabled = 崩溃残留会静默清真实历史；tearDown 还会反向重置开发者自选的保留期）→ HistoryMaintenance 改 defaults 可注入，测试用隔离 suite + removePersistentDomain。
5. **OCR 未识别到日期时误立 hasUserAdjustedExpiry 守卫**（两路独立发现同一回归：扫到名称没扫到日期 → 历史模板保质期不再自动填充，静默停在通用 +7 天）→ applyOCRResult 只在「真识别到日期或用户在确认页改过日期」时写入并立守卫（ocrExpiryDate 以 expiryDate 播种，相等即未改动）；确认页对未识别情形显示「以上日期为表单当前值」而非误导性的「识别到的日期已是过去」警告。
6. **OCR「是否应用」决策真值表零覆盖且困在视图闭包里** → 提炼 `PackagingDateSanity.shouldApplyDate(recognized:warning:userConfirmed:)` 纯函数 + 真值表测试；verifier 同时纠正了「赋值顺序 load-bearing」的错误注释（SwiftUI onChange 在事务后触发，守卫只需与 name 赋值同事务）。
7. **同步状态记录（修复 2 的交付物）无测试** → recordSyncSuccess/Failure 改 defaults/now 可注入、状态文案提炼 syncStatusText 纯函数，新增 WidgetSyncStatusTests（7 用例，隔离 suite——宿主 app 的刷新路径也写同名键，用 standard 会互相污染）。

驳回 3 条（详见 workflow 输出）：「>2 年默认不应用误伤长保质期商品」——这正是本批规格本身，三层可见信号非静默；「fetch 失败场景不可达」——与确认项 3 冲突，按上述理由仍修；「5 秒性能断言会抖动」——实测 0.5s 有 10 倍余量、仓库无 CI。

## UI 测试失败排查 → 发现真实 P0：授权弹窗待决时主线程同步 XPC 冻死

`testConsumingMultiUnitItemDecrementsAndKeepsRow` 在擦净的模拟器上确定性失败（快照超时 ×3）。用 `sample` 抓挂起窗口内的主线程栈，3454/3454 采样全部卡在：
`reduceQuantityOrRemove → cancelNotification → UNUserNotificationCenter.removePendingNotificationRequests → _dispatch_lane_barrier_sync`。

**根因**：usernotificationsd 在授权弹窗待决（.notDetermined + 弹窗未答）期间不响应，`add`/`removePendingNotificationRequests` 内部的同步 XPC 屏障会把调用线程永久阻塞。首次保存食材会弹授权框（2026-06-10 批次的设计），此时滑动消费任何食材 → 主线程冻死。**真实用户 bug，非测试基建问题**——开发机上权限早已确定，所以基线测试从未踩中；本批之前的代码同样会冻死，只是没被发现。

**修复**：NotificationManager 所有通知中心变更（add/removePending）统一挪到私有串行 DispatchQueue（FIFO 保证 rescheduleAll「先删后加」的顺序不变）；主线程只读取 @Model 字段并打包 Sendable 原始值（标识符字符串、DateComponents、秒数），UN 对象在队列内构造（新增文件级 `ReminderTrigger` 枚举承载触发器描述）。授权待决时阻塞的是后台 utility 线程，队列内操作在授权解决后按序执行。

## Verification

- 最终全量：**TEST SUCCEEDED** —— 单元 + 快照 207 用例 0 失败（本批新增 35：HistoryMaintenance 边界+性能、PackagingDateSanity 边界+真值表、FoodItem.find、DetailAction 文案分流、hasCountableQuantity、WidgetSyncStatus），UI 7 用例 6 过 + 1 既有 skip、0 失败。
- UI 测试首轮 2 失败排查结论——`testAddItemAppearsInList` 由 -uitesting 隔离泄漏（didSave 管道触发 WidgetCenter reload churn）导致，审查修复后通过；`testConsumingMultiUnitItemDecrementsAndKeepsRow` 由上述主线程冻死导致（sample 抓栈实证），修复后在擦净模拟器（授权未决的最严苛条件）从 179s 挂死 → 22.6s 通过。
- 未实机验证：App Group 写失败的真实触发（需要故障注入）、通知实际送达时序。

## P2 待办（本轮明确不做，记录备查）

- 动态 Widget 时间线（按最近到期物品计算下次刷新点，替代固定次日）。
- 「开封日期 / 开封后 N 天」语义支持（需要新字段 + UI）。
- 历史归档聚合（90 天后只留统计）+ 备份瘦身。
- 导入大备份后的通知增量调度（只排"即将过期"子集，避开 iOS 64 条 pending 上限）。
- 名称模糊匹配 / 同义词机制（"牛奶" vs "全脂牛奶"）。
