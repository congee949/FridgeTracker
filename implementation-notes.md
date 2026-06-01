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
