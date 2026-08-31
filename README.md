<div align="center">
  <img src="Yomi/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="Yomi 图标">
  <h1>Yomi</h1>
  <p>把每个 AI Provider 的额度，留在视线边缘。</p>
  <p>
    <a href="https://github.com/Seaony/Yomi/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/Seaony/Yomi?display_name=tag&amp;style=flat-square"></a>
    <img alt="macOS 26.5+" src="https://img.shields.io/badge/macOS-26.5%2B-111111?style=flat-square&amp;logo=apple">
    <img alt="Swift 5" src="https://img.shields.io/badge/Swift-5-F05138?style=flat-square&amp;logo=swift&amp;logoColor=white">
    <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-0A84FF?style=flat-square&amp;logo=swift&amp;logoColor=white">
  </p>
</div>

Yomi 是一款使用 SwiftUI 与 AppKit 构建的 macOS Provider 用量监控工具。它把额度、Token、预估金额和重置时间收进贴合屏幕边缘的悬浮栏，让常用服务的剩余用量始终清晰可见。

## 功能亮点

- **屏幕边缘悬浮栏**：可自由拖到屏幕左侧或右侧，并记住停靠方向与垂直位置。
- **剩余额度圆环**：主界面直接显示 Provider 的剩余比例，状态变化无需反复打开网页。
- **紧凑详情卡片**：点击圆环即可查看账号等级、额度窗口、剩余比例和距离重置的时间。
- **Token 与金额统计**：汇总当天及近 30 天的本地 Token 用量，按照模型价格计算预估金额。
- **周额度预估**：结合当前用量和额度窗口，展示每周预估金额。
- **统一 Provider 管理**：内置 69 个 Provider 配置入口，可按需启用、搜索并配置认证信息。
- **贴合系统体验**：支持系统、深色、浅色三种外观，以及简体中文和英文。
- **应用内更新**：通过 Sparkle 检查并安装 GitHub Releases 中的新版本。

## Provider

Yomi 覆盖订阅额度、API 消费、余额、点数和请求次数等不同指标类型，包含但不限于：

| 类别 | 示例 |
| --- | --- |
| 编程与订阅服务 | Codex、Claude、Gemini、Copilot、Cursor、Windsurf、Kiro |
| 模型与 API 平台 | OpenAI、Azure OpenAI、AWS Bedrock、OpenRouter、DeepSeek、Mistral |
| 额度与聚合服务 | ClinePass、OpenCode、Qwen Cloud、Kimi Code、LiteLLM、ZenMux |

不同 Provider 的认证方式并不相同。Yomi 会根据对应服务读取本机账号状态、环境变量、API Token、Cookie 或自定义端点；设置页面会显示每项服务需要的配置。

## 安装

从 [最新版本](https://github.com/Seaony/Yomi/releases/latest) 下载 DMG，将 `Yomi.app` 拖入 Applications 后启动。

当前发布流程生成的安装包未使用 Apple Developer ID 签名，也未经过 Apple 公证。首次打开时，如果 macOS 阻止运行，请前往 **系统设置 → 隐私与安全性**，确认打开 Yomi。

发布包同时支持 Apple silicon 与 Intel Mac，最低系统版本为 macOS 26.5。

## 使用方式

1. 打开 Yomi 设置，在 **Providers** 中启用需要监控的服务。
2. 根据 Provider 提示配置账号、Token、Cookie、环境变量或服务端点。
3. 点击刷新，额度可用后会出现在屏幕边缘的悬浮栏中。
4. 拖动悬浮栏可调整左右停靠位置和高度；Yomi 会在下次启动时恢复位置。
5. 点击 Provider 圆环查看详情；将鼠标移到悬浮栏底部可打开设置。

设置页面还可以切换语言、外观、刷新间隔、登录时启动和 Provider 名称显示。

## 数据与隐私

- Provider 的密钥和认证信息保存在 macOS 钥匙串中。
- 用量缓存、界面偏好和悬浮栏位置保存在本机。
- 本地会话日志只用于可验证的 Token 与金额统计，不会把聊天内容或代码文本解析成额度。
- 额度查询只访问对应 Provider 的数据源；自动更新只访问 Yomi 的 GitHub Release feed。

## 从源码构建

准备 Xcode 26.6，然后运行：

```bash
git clone https://github.com/Seaony/Yomi.git
cd Yomi
xcodebuild \
  -project Yomi.xcodeproj \
  -scheme Yomi \
  -configuration Debug \
  -derivedDataPath "$PWD/DerivedData" \
  build
open DerivedData/Build/Products/Debug/Yomi.app
```

项目的主要代码位置：

```text
Yomi/AppDelegate.swift             窗口、悬浮面板与位置持久化
Yomi/UsageRailView.swift           屏幕边缘悬浮栏
Yomi/ProviderDetailCard.swift      Provider 详情卡片
Yomi/UsageStore.swift              状态、刷新与缓存回退
Yomi/UsageCollector.swift          用量采集与本地统计整合
Yomi/ProviderRecipes.swift         Provider 请求和解析规则
Yomi/LocalDailyUsageScanner.swift  Token 与金额统计
Yomi/SettingsView.swift            设置、主题与本地化
Yomi/UpdateController.swift        Sparkle 自动更新
scripts/                           发布与产物验证脚本
docs/                              发布说明
```

## 发布

从干净且已推送的 `master` 快速发布未签名版本：

```bash
scripts/publish-unsigned-release.sh 1.0.1
```

脚本会构建通用应用，生成 ZIP、DMG 和 Sparkle appcast，创建版本标签并发布 GitHub Release。完整前置条件和行为说明请阅读 [发布说明](docs/RELEASING.md)。

## 技术栈

- Swift 5、SwiftUI、AppKit
- Combine、URLSession、Security、ServiceManagement
- Sparkle 2 应用内更新
- GitHub Releases 版本分发

---

<div align="center">
  <sub>少开一个网页，多留一点注意力给真正重要的工作。</sub>
</div>
