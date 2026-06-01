# History and Settings Pages Design

## Goal

Add a complete historical food reuse page and a lightweight settings page so FridgeTracker can support longer-term personal use without turning every repeated purchase into manual re-entry.

The current Add Food page already has a short `最近添加` row, but that row is intentionally limited and becomes hard to use when the user has many previously purchased foods. The new `历史` page should be the complete searchable library of previously added food names. The `设置` page should move from a gear sheet to a first-class tab with reminder, display, data, and about sections.

## Chosen Direction

Use bottom tabs for primary areas:

1. `冷藏`
2. `冷冻`
3. `常温`
4. `历史`
5. `设置`

This keeps the existing zone-based home flow and adds the two requested destinations without introducing deeper navigation or a separate template-management concept.

## History Page

Purpose: a complete historical food library generated from previously added records.

Contents:

- All `FoodItem` records grouped by trimmed `name`, using the latest record for each name as the reusable source.
- Search by food name.
- Optional category chips using existing `FoodCategory.allCases`.
- Each row shows:
  - `displayIcon`
  - food name
  - category and storage zone
  - an estimated shelf-life hint such as `约 7 天`

Behavior:

- Tapping a history row opens `AddFoodView` with that history item as a reusable template for a new record.
- The add form should prefill name, category, storage zone, custom icon, quantity, notes, and purchase-date state from the selected historical item.
- The expiry date should be recalculated from today using `shelfLifeDaysEstimate`.
- Saving from this flow creates a new `FoodItem`; it must not edit the historical source record.
- The existing short `最近添加` row in Add Food remains useful for the fastest repeated entries.

Out of scope:

- Manual template CRUD.
- Pinning or deleting history entries independently of food records.
- Separate persistent template model.

## Settings Page

Purpose: first version of settings for reminders, display, backup, and app info.

### 提醒

Contents:

- `开启过期提醒`
- `默认提前提醒：1 天`
- `肉类 / 海鲜提前提醒：2 天`
- `冷冻食品提前提醒：7 天`

Behavior:

- `开启过期提醒` uses the existing `notificationsEnabled` setting.
- Reminder defaults should preserve the existing simple settings model where possible.
- Category defaults should be shown clearly in Settings and respected by notification scheduling:
  - meat and seafood: 2 days
  - frozen foods: 7 days
  - all other categories: 1 day

### 显示

Contents:

- `首页排序：按到期日`
- `Widget 标题：冰箱提醒`

Behavior:

- Homepage sorting remains expiry-date first by default.
- Widget title remains `冰箱提醒`.
- This section is informational in this iteration unless a setting already exists.

### 数据

Contents:

- `导出数据`
- `导入数据`

Behavior:

- Export should produce a JSON file containing all food records in a stable app-owned backup format.
- Import should read that JSON format and insert records into SwiftData.
- After import, refresh widget data.
- Keep this local and manual; no iCloud sync in this iteration.

### 关于

Contents:

- App name: `FridgeTracker`
- App version from bundle metadata when available.

## Implementation Notes

- To keep the change surgical, new views may be placed in existing Swift files if that avoids Xcode project reference churn.
- If new Swift files are created, update `project.pbxproj` explicitly because this project does not auto-discover source files.
- No model migration should be required.

## Validation

After implementation:

1. Build the FridgeTracker scheme with Xcode tooling.
2. Confirm bottom tabs include `历史` and `设置`.
3. Confirm `历史` deduplicates previous foods by trimmed name.
4. Confirm selecting a history row opens add flow for a new item, not editing the existing record.
5. Confirm settings show the requested reminder/display/data/about content.
6. Confirm notification category defaults use 2 days for meat/seafood, 7 days for frozen, and 1 day for others.
7. Confirm export/import code compiles and import refreshes Widget data.

## Acceptance Criteria

- `历史` is a bottom-tab page for searching and reusing all previously purchased food names.
- `设置` is a bottom-tab page with the requested reminder, display, data, and about sections.
- Reminder defaults match the requested values.
- Data export/import are present as local manual actions.
- Existing add, edit, widget refresh, and same-name reuse behavior remain intact.
- The project builds successfully.
