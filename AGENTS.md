# AGENTS.md

## 项目概况

Yomi 是使用 SwiftUI 与 AppKit 构建的原生 macOS 应用，用悬浮侧边栏展示多个 Provider 的额度、Token 用量和预估金额。

- 工程：`Yomi.xcodeproj`
- Scheme：`Yomi`
- 主要 Target：`Yomi`
- Swift：5.0
- macOS Deployment Target：26.5
- 应用入口：`Yomi/YomiApp.swift`
- 窗口与悬浮面板：`Yomi/AppDelegate.swift`
- 参考仓库：本机 `/Users/seaony/code/CodexBar`，上游为 [steipete/CodexBar](https://github.com/steipete/CodexBar)。

## 代码位置

- `Yomi/UsageStore.swift`：Provider 状态、刷新调度与缓存回退。
- `Yomi/UsageCollector.swift`：用量数据采集和本地统计补充。
- `Yomi/ProviderRecipes.swift`：部分 Provider 的 HTTP 接口地址、请求方法与认证方式。
- `Yomi/*Usage.swift`：Provider 专用采集与解析，例如 `CursorUsage.swift`、`KimiUsage.swift`。
- `Yomi/LocalDailyUsageScanner.swift`：本地 Token 用量与金额统计。
- `Yomi/UsageRailView.swift`：主界面悬浮侧边栏。
- `Yomi/ProviderDetailCard.swift`：Provider 详情卡片。
- `Yomi/SettingsView.swift`：设置页面和 Provider 配置入口。
- `Yomi/AppPreferences.swift`：外观、颜色、语言偏好与中英文文案。
- `Yomi/UpdateController.swift`：Sparkle 自动更新。

## 实现约束

- 修改前先搜索并阅读同类实现，保持现有组件、命名和布局方式。
- 只修改当前需求涉及的代码，不顺带重构或格式化无关文件。
- Provider 额度、账号等级和重置时间应与参考仓库 CodexBar 的实现逻辑对齐，查阅其中 `Sources/CodexBarCore/Providers/` 下对应 Provider 的代码；可以使用其依赖的开源库，但禁止把 CodexBar 本身作为依赖。
- 不得从聊天内容、代码文本或任意包含百分号的日志中推断额度；额度必须来自对应 Provider 的可靠数据源。
- 本地日志只用于可验证的 Token 用量与金额统计，不得伪造成 Provider 额度。
- 所有新增界面文案必须同时适配简体中文和英文。
- 所有界面改动必须同时适配深色、浅色和系统外观模式，并复用现有颜色与组件。
- 交互控件需要保持现有 hover、指针和按压反馈。
- 图标与相邻数量使用明确的紧凑间距，不依赖 Label 的默认间距。
- 自动更新使用 Sparkle 和 Yomi 自己的 GitHub Release `appcast.xml`，不引入 CodexBar 或 Moni 作为依赖。

## 验证

修改代码后至少执行：

```bash
git diff --check
xcodebuild \
  -project Yomi.xcodeproj \
  -scheme Yomi \
  -configuration Debug \
  -derivedDataPath /tmp/YomiDerivedData \
  build
```

构建产物位于：

```text
/tmp/YomiDerivedData/Build/Products/Debug/Yomi.app
```

- 每次完成代码修改后，重新启动上述最新 Debug 构建供用户检查。
- 未经用户明确允许，不使用 UI 自动化工具进行视觉验收。
- 未经用户在当前任务中明确要求，不执行 commit、push、建分支或创建 worktree。
