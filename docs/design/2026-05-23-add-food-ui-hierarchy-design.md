# Add Food UI Hierarchy Design

## Goal

Make the Add Food page easier to understand by separating quick reuse actions from actual editable food fields.

The current layout places template chips, the food name text field, and category chips in one `基本信息` section. This makes users read them as one ambiguous hierarchy:

1. first row: recent/common food chips
2. second row: food name input
3. third row: category chips

The new layout should make these concepts visually and semantically distinct.

## Chosen Direction

Use separate sections:

1. `最近添加`
2. `食材信息`
3. `显示图标`
4. Existing storage/date/other sections

This preserves the fast repeated-entry path while making the form hierarchy clearer.

## Section Behavior

### 最近添加

Purpose: quick reuse of a known food.

Contents:

- Existing history/common food chips.
- A short explanatory footer or caption:
  - `点选后自动填入名称、分类、图标和存储区域，只需确认新的保质期。`

Behavior:

- Tapping a chip still calls the existing template application logic.
- It fills food name, category, storage zone, custom icon, and expiry estimate.
- This row is not an editable field group. It is an action shortcut.

Template ordering remains:

- Recent historical foods first, deduplicated by trimmed name.
- Common foods appended when not already present.
- Keep the existing maximum count of 8.

### 食材信息

Purpose: actual editable identity fields.

Contents:

- `TextField("食材名称", text: $name)`
- Category chips from `FoodCategory.allCases`.

Behavior:

- Name input keeps the same same-name auto-fill behavior.
- Category chips update `category`.
- When the user manually changes category, clear `customIcon` so the displayed icon falls back to the selected category icon.

This section should no longer contain recent/common food template chips.

### 显示图标

Rename the existing `图标` section to `显示图标`.

Purpose: optional override for the icon shown in lists/widgets.

Contents:

- `TextField("自定义 Emoji（可选）", text: $customIcon)`
- Caption:
  - `留空时使用当前分类图标：\(category.icon)`

Behavior:

- If `customIcon` is empty, the app displays `category.icon`.
- If `customIcon` has a value, that value remains the display icon.
- This supports fine-grained items such as `草莓 🍓` and `厚椰乳 🥥`.

### Existing Sections

Keep these sections functionally unchanged:

- `存储区域`
- `日期`
- `其他`

## Out of Scope

- No model changes.
- No Widget changes.
- No save logic changes.
- No barcode logic reintroduction.
- No new template CRUD.
- No advanced icon picker.

## Validation

After implementation:

1. Build the FridgeTracker scheme with Xcode tooling.
2. Confirm `AddFoodView` has separate `最近添加` and `食材信息` sections.
3. Confirm recent/common template chips are not inside `食材信息`.
4. Confirm category changes still clear `customIcon`.
5. Confirm same-name auto-fill remains connected to name input.
6. Confirm save logic and `WidgetDataStore.refresh(using:)` remain unchanged.

## Acceptance Criteria

- The Add Food page no longer has template chips, name input, and category chips under one ambiguous `基本信息` section.
- Quick reuse is labeled as `最近添加`.
- Actual editable name/category fields are labeled as `食材信息`.
- Icon override is labeled as `显示图标` with clearer fallback wording.
- The project builds successfully.
