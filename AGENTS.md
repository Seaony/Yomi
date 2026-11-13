# AGENTS.md

## 项目概况

CodeEdge 是使用 SwiftUI 与 AppKit 构建的原生 macOS 应用，用悬浮侧边栏展示多个 Provider 的额度、Token 用量和预估金额。

- 工程：`CodeEdge.xcodeproj`
- Scheme：`CodeEdge`
- 主要 Target：`CodeEdge`
- 测试 Target：`CodeEdgeTests`
- Swift：5.0
- macOS Deployment Target：15.0
- Swift Package 依赖：Sparkle、SweetCookieKit
- 应用入口：`CodeEdge/CodeEdgeApp.swift`
- 窗口与悬浮面板：`CodeEdge/AppDelegate.swift`
- 参考仓库：
  - 本机 `/Users/seaony/code/CodexBar`，上游为 [steipete/CodexBar](https://github.com/steipete/CodexBar)。Provider 数据逻辑以它为准；最近一次同步对应 CodexBar 0.84.0 之后的 main（7447bc77c，2026-11-07），只有 Vercel 个人 AI Gateway 预算未同步。
  - [vinzdg/codenotch](https://github.com/vinzdg/codenotch)（MIT，本机未克隆）：同样把 Claude Code、Cursor、Codex、Antigravity 的额度固定在屏幕边缘，可参考其界面与交互。

## 代码位置

- `CodeEdge/UsageStore.swift`：Provider 状态、刷新调度与缓存回退。
- `CodeEdge/UsageCollector.swift`：用量数据采集和本地统计补充。
- `CodeEdge/ProviderRecipes.swift`：部分 Provider 的 HTTP 接口地址、请求方法与认证方式。
- `CodeEdge/*Usage.swift`：Provider 专用采集与解析，例如 `CursorUsage.swift`、`KimiUsage.swift`。
- `CodeEdge/LocalDailyUsageScanner.swift`：本地 Token 用量与金额统计。
- `CodeEdge/AppPreferences.swift`：外观、颜色、语言偏好与中英文文案。
- `CodeEdge/LegacyMigration.swift`：启动入口在任何偏好或单例初始化前迁移旧设置、钥匙串和 Application Support；只补新域缺失项，保留旧凭据。持久化 ID `yomi-overview` 和模型缓存键前缀 `yomi-fallback:` 沿用旧标识。
- `CodeEdge/ProviderPreferences.swift`：Provider 启用状态与密钥的钥匙串存储。
- `CodeEdge/UsageParser.swift`：接口返回解析与缓存恢复。
- `scripts/release-config.sh`、`docs/RELEASING.md`：发版配置与说明。发版用全局技能 `mac-release` 的共用脚本，会公证、推送标签并创建 GitHub Release。

## 实现约束

- 只修改当前需求涉及的代码，不顺带重构或格式化无关文件。
- Provider 额度、账号等级和重置时间应与参考仓库 CodexBar 的实现逻辑对齐，查阅其中 `Sources/CodexBarCore/Providers/` 下对应 Provider 的代码；可以使用其依赖的开源库，但禁止把 CodexBar 本身作为依赖。
- 不得从聊天内容、代码文本或任意包含百分号的日志中推断额度；额度必须来自对应 Provider 的可靠数据源。
- 本地日志只用于可验证的 Token 用量与金额统计，不得伪造成 Provider 额度。
- 所有新增界面文案必须同时适配简体中文和英文。
- 所有界面改动必须同时适配深色、浅色和系统外观模式，并复用现有颜色与组件。
- 交互控件需要保持现有 hover、指针和按压反馈。
- 图标与相邻数量使用明确的紧凑间距，不依赖 Label 的默认间距。
- 自动更新使用 Sparkle 和 CodeEdge 自己的 GitHub Release `appcast.xml`，不引入 CodexBar 或 Moni 作为依赖。

## 验证

修改代码后至少执行下面的检查；涉及解析、缓存或统计逻辑时，把最后的 `build` 换成 `test` 再跑一次单元测试：

```bash
git diff --check
xcodebuild \
  -project CodeEdge.xcodeproj \
  -scheme CodeEdge \
  -configuration Debug \
  -derivedDataPath /tmp/CodeEdgeDerivedData \
  build
```

构建产物位于：

```text
/tmp/CodeEdgeDerivedData/Build/Products/Debug/CodeEdge.app
```

- 每次完成代码修改后，重新启动上述最新 Debug 构建供用户检查。
- 可以用 UI 自动化做测试和视觉验收，但只能用不占用真实鼠标和键盘焦点的后台方式（如 cua-driver 按元素操作、发给指定进程的事件、虚拟机里的独立连接），不能移动用户的光标或抢前台焦点。
- commit、push 和发布新版本不用逐次征求用户确认：改动验证通过后直接提交并推送，值得发版时按全局技能 `mac-release` 运行共用发版脚本，事后汇报。
