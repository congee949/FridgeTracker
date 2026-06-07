# Duplicate Food Re-add Design

## Goal

Improve the add-food flow after removing barcode scanning. When the user adds the same food again, they should only need to enter the new expiry date in the common case, while still being able to edit all fields.

## Scope

### In scope

- Remove barcode scanning UI and lookup logic from the add/edit flow.
- Remove barcode scanner and lookup source files from the app target if they are no longer referenced.
- Recompile the app after removal.
- Add same-name reuse behavior for new food creation.
- Preserve the existing history-first template chips.
- Save repeated foods as new `FoodItem` records rather than overwriting existing records.

### Out of scope

- Barcode storage or product database behavior.
- Open Food Facts lookup.
- Product image lookup or storage.
- Fuzzy matching between similar food names.
- iCloud sync or backup.
- Template CRUD.

## User Experience

In `AddFoodView`, when the user is creating a new item and types a food name that exactly matches a previous food item's trimmed name:

1. The form immediately reuses the most recent matching record's reusable fields.
2. The expiry date remains under the user's control and is the primary field to update.
3. All auto-filled fields remain editable.
4. Saving creates a new `FoodItem` record.

Editing an existing food item must not trigger this reuse behavior.

## Matching Rule

A previous item matches when:

```swift
existing.name.trimmingCharacters(in: .whitespacesAndNewlines) == inputName.trimmingCharacters(in: .whitespacesAndNewlines)
```

Use the most recently created matching item. The current query already sorts `existingItems` by `createdAt` descending, so the first matching item is the preferred source.

No fuzzy matching is used. This avoids false positives such as treating `牛奶` and `牛奶饮品` as the same item.

## Fields to Reuse

When a same-name match is found during new item creation, reuse:

- `category`
- `storageZone`
- `customIcon`
- `quantity`
- `notes`
- purchase-date state if useful only when the previous record had a purchase date

Do not force-copy the old expiry date as the final value. The user should still choose the new expiry date.

A practical default is to set the expiry date based on the previous item's estimated shelf life:

```swift
expiryDate = Calendar.current.date(
    byAdding: .day,
    value: matchedItem.shelfLifeDaysEstimate,
    to: Date()
) ?? expiryDate
```

This keeps the common case close to “only confirm the date,” while avoiding reusing an already-expired historical date.

## Trigger Behavior

The reuse check runs while typing the name field, only when all conditions are true:

- The view is creating a new item, not editing an existing item.
- The trimmed input name is not empty.
- A same-name historical item exists.

When triggered, the form immediately fills reusable fields from the historical item.

To avoid repeatedly overriding user edits after an automatic fill, the implementation should track the last name that was auto-applied. If the user changes category, zone, icon, quantity, or notes after auto-fill, those edits should not be overwritten again for the same unchanged name.

## Existing Template Chips

Keep the existing history-first template chips. They remain useful for one-tap entry. The new same-name auto-fill complements them:

- Template chips: user explicitly taps a previous/common food.
- Same-name auto-fill: user types a known name and gets the same reuse behavior automatically.

## Barcode Removal

Remove the barcode-specific Add screen states and UI:

- `showScanner`
- `isLooking`
- `扫码添加` button
- loading text `正在查询商品信息...`
- scanner sheet
- `handleBarcode(_:)`
- category inference from Open Food Facts strings

Remove source files if no longer used:

- `FridgeTracker/Views/BarcodeScannerView.swift`
- `FridgeTracker/Utilities/BarcodeLookupService.swift`

Update the Xcode project so deleted source files are not referenced by the app target.

## Validation

Build the app target with Xcode tooling after implementation.

Manual behavior to confirm in code or simulator if practical:

1. New food with a brand-new name still works.
2. New food with an existing name auto-fills reusable fields while leaving fields editable.
3. Saving the repeated food creates a new record rather than modifying the old one.
4. Editing an existing item does not auto-apply another record's fields.
5. Widget snapshot refresh still runs after saving.
6. No barcode UI remains in `AddFoodView`.

## Acceptance Criteria

- Barcode scanning and lookup code is removed from the add/edit experience.
- Same-name re-add flow uses the latest historical item as a reusable template.
- The user can type an existing food name and mostly only adjust the expiry date.
- All reused fields remain editable.
- Save creates a new `FoodItem` for repeated foods.
- The project compiles successfully.
