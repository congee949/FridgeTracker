# SystemLarge Widget Adaptive Row Height

## Problem

The `systemLarge` widget supports up to 8 food items. When fewer than 8 items are displayed (e.g., 2-6 items), the bottom portion of the widget is wasted empty space. The items remain at their compact default size regardless of available room.

## Goal

When fewer than 8 items are shown in the `systemLarge` widget, expand each row's height and scale up its content (icon, text) to fill the available space. This makes the widget feel intentional rather than half-empty.

## Scope

- Only `systemLarge` widget family
- `systemSmall` and `systemMedium` are unchanged
- No changes to data model, provider, or configuration intent

## Design

### Scale Factor Calculation

```
visibleCount = min(items.count, 8)
defaultRowHeight = 16
defaultSpacing = 5
defaultContentHeight = visibleCount * defaultRowHeight + (visibleCount - 1) * defaultSpacing
availableHeight = 136  // ~170 widget height minus ~34 header
scaleFactor = min(availableHeight / defaultContentHeight, 1.5)
```

| Items | Default Height | Scale Factor |
|-------|---------------|-------------|
| 8 | 163 | 0.83 (stays compact) |
| 7 | 147 | 0.93 |
| 6 | 121 | 1.12 |
| 5 | 105 | 1.29 |
| 4 | 79 | 1.50 (capped) |
| 3 | 63 | 1.50 (capped) |
| 2 | 37 | 1.50 (capped) |
| 1 | 16 | 1.50 (capped) |

### Changes to `FridgeTrackerWidgetView`

Add a computed property `scaleFactor` that returns 1.0 for non-large families, and the calculated value for `.systemLarge`. Pass it to `ExpiringFoodWidgetRow`.

### Changes to `ExpiringFoodWidgetRow`

Accept a `scaleFactor: CGFloat` parameter (default 1.0). Adjust:

| Property | Default (1.0) | At 1.5 |
|----------|--------------|--------|
| Icon font | `.body` | `.title3` |
| Icon frame width | 24 | 36 |
| Name font | `.caption.weight(.semibold)` | `.subheadline.weight(.semibold)` |
| Sub-text font | `.caption2` | `.caption` |
| Row spacing | 1 | 2 |
| Right text font | `.caption2` | `.caption` |

### What Stays the Same

- `lineLimit(1)` on all text
- Status color logic (red/orange/green)
- Link destination URLs
- Widget configuration and provider
- `systemSmall` and `systemMedium` behavior

## Files Modified

- `FridgeTrackerWidget.swift` — `FridgeTrackerWidgetView` (scale calculation) and `ExpiringFoodWidgetRow` (content scaling)

## Verification

1. Build passes with `xcodebuild build`
2. Widget preview with 8 items: compact layout, no visual change
3. Widget preview with 4 items: rows are taller, icons and text are larger
4. Widget preview with 1-2 items: scaled up but capped at 1.5x, no overflow
