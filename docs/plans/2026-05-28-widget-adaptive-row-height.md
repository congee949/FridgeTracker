# Widget Adaptive Row Height Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `systemLarge` widget expand row spacing and row content when it displays fewer than eight food items.

**Architecture:** Keep the change inside `FridgeTrackerWidget/FridgeTrackerWidget.swift`. `FridgeTrackerWidgetView` computes a clamped scale factor from the visible item count, and `ExpiringFoodWidgetRow` uses that factor for large-family fonts, icon width, and row spacing while preserving existing small and medium behavior.

**Tech Stack:** SwiftUI, WidgetKit, AppIntent widget configuration.

---

### Task 1: Large Widget Scale Calculation

**Files:**
- Modify: `FridgeTrackerWidget/FridgeTrackerWidget.swift`

- [x] **Step 1: Compute scale only for `systemLarge`**

Use visible item count, default row height `16`, default spacing `5`, available height `136`, and cap the result at `1.5`.

- [x] **Step 2: Preserve compact layout for full rows**

Clamp the scale lower bound to `1.0` so seven or eight rows do not shrink below the current compact layout.

- [x] **Step 3: Apply scale to large-family list spacing**

Use `5 * scaleFactor` for large widgets and keep `8` for other widget families.

### Task 2: Row Content Scaling

**Files:**
- Modify: `FridgeTrackerWidget/FridgeTrackerWidget.swift`

- [x] **Step 1: Pass scale into rows**

Call `ExpiringFoodWidgetRow(item:family:scaleFactor:)` from the large/medium row list.

- [x] **Step 2: Add a defaulted row scale parameter**

Add `let scaleFactor: CGFloat = 1.0` to `ExpiringFoodWidgetRow`.

- [x] **Step 3: Scale large-family fonts and spacing**

Map large rows from compact fonts at `1.0` to larger fonts near `1.5`: icon `.body` to `.title3`, name `.caption.weight(.semibold)` to `.subheadline.weight(.semibold)`, and detail text `.caption2` to `.caption`.

### Task 3: Verification

**Files:**
- Read: `FridgeTrackerWidget/FridgeTrackerWidget.swift`

- [x] **Step 1: Build the widget target**

Run:

```bash
xcodebuild -project FridgeTracker.xcodeproj -scheme FridgeTrackerWidget -destination 'generic/platform=iOS Simulator' build
```

Result: `** BUILD SUCCEEDED **`.

- [x] **Step 2: Review remaining risk**

Confirm the implementation only changes `systemLarge` adaptive layout behavior and leaves widget data, intents, status colors, links, and small/medium item limits unchanged.
