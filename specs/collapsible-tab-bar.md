# Spec: 可收缩底部菜单栏

## 目标

在 FridgeTracker 现有 UI 不变的前提下，利用 iOS 26 原生 API 实现底部 Tab Bar 的智能收缩。

## 实现方式

使用 iOS 26 原生 `TabBarMinimizeBehavior`，无需自定义滚动检测或自定义 Tab Bar 组件。

```swift
TabView(selection: $selectedTab) {
    // ... 现有 tab 内容不变
}
.tabBarMinimizeBehavior(.onScrollDown)
```

## 交互行为

### 收缩

- 用户在任意 Tab 内容区域**上滑**（查看下方内容）
- 底部 Tab Bar 收缩为左下角浮动胶囊（原生样式，含当前 Tab 图标）

### 恢复

- **滑回顶部**：Tab Bar 自动恢复
- **点击浮动胶囊**：Tab Bar 恢复

## 代码变更

| 文件 | 变更 | 状态 |
|------|------|------|
| `ContentView.swift` | TabView 添加 `.tabBarMinimizeBehavior(.onScrollDown)` | ✅ 已完成 |
| `project.pbxproj` | `IPHONEOS_DEPLOYMENT_TARGET` 从 `17.0` → `26.0` | ✅ 已完成 |

## 验证

- **Build**：iPhone 17 模拟器 build 成功（`BUILD SUCCEEDED`）
- **功能验证**：手动测试通过，Tab Bar 滚动收缩/恢复行为正常
- **触发条件**：需要足够的滚动距离（内容超出可视区域），内容少时不会触发收缩

## 不变部分

- 所有现有页面内容（FoodListView、ReplenishmentListView、HistoryView、SettingsView）
- Tab 切换逻辑
- 各页面内部的滚动行为
- 无需自定义滚动检测、PreferenceKey、自定义 Tab Bar 组件
