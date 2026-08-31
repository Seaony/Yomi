# Yomi 快速发布说明

Yomi 使用 Sparkle 进行应用内更新，更新文件托管在 GitHub Releases。当前采用本地未签名发布流程，不需要 Apple Developer ID，也不进行 Apple 公证。

发布脚本会自动完成以下工作：

1. 检查当前是否位于 `master`，并确认工作区干净且与 `origin/master` 完全一致。
2. 检查版本标签和 GitHub Release 是否已经存在。
3. 根据上一个正式 Release 的 `appcast.xml` 自动递增 build number；首次发布从 `1` 开始。
4. 构建包含 `arm64` 和 `x86_64` 的 Release 应用。
5. 对应用执行本地 ad-hoc 签名，以保证应用包和 Sparkle Framework 的完整性；这不是 Apple Developer ID 签名。
6. 生成 ZIP、DMG、Release Notes 和带 EdDSA 签名的 `appcast.xml`。
7. 创建并推送版本标签，随后创建 GitHub Release 并上传全部产物。

应用固定读取以下更新源：

```text
https://github.com/Seaony/Yomi/releases/latest/download/appcast.xml
```

## 首次准备

需要安装并登录 GitHub CLI：

```bash
gh auth login
gh auth status
```

本机还需要可用的 Xcode、Command Line Tools，以及以下命令：

```text
gh xcodebuild ditto hdiutil xmllint lipo codesign
```

Sparkle 的 EdDSA 私钥必须位于登录钥匙串。Yomi 当前沿用自动更新配置中已有的 `com.seaony.Moni` Sparkle 密钥账户，脚本默认读取该账户。可以这样确认它存在：

```bash
security find-generic-password \
  -a com.seaony.Moni \
  -s https://sparkle-project.org
```

Sparkle 的 EdDSA 签名是自动更新校验所必需的，与 Apple Developer ID 签名和公证无关。

## 发布新版本

发布前先把准备发布的内容 commit 并推送到 `origin/master`，确保工作区完全干净。然后只传入三段式版本号：

```bash
scripts/publish-unsigned-release.sh 1.0.1
```

脚本会执行外部写操作，包括：

- 创建本地标签 `v1.0.1`；
- 将该标签推送到 `origin`；
- 创建 `Seaony/Yomi` 的 GitHub Release；
- 上传 ZIP、DMG 和 `appcast.xml`。

脚本不会自动 commit，也不会推送 `master`。如果工作区不干净、本地提交尚未推送、版本已存在或 GitHub CLI 未登录，脚本会在发布前停止。

本地产物保存在：

```text
build/releases/v1.0.1/
```

其中包括：

```text
Yomi-1.0.1-unsigned.zip
Yomi-1.0.1-unsigned.dmg
appcast.xml
```

## 单独验证产物

构建完成后可单独验证应用和 appcast：

```bash
scripts/validate-release.sh \
  build/releases/v1.0.1/Yomi.app \
  build/releases/v1.0.1/appcast.xml
```

发布脚本生成的目录默认不保留独立 `Yomi.app`，因此通常无需手动执行该命令；脚本已经在打包前自动验证构建产物，并在生成 appcast 后再次验证。

## 用户首次打开

由于应用没有 Developer ID 签名和 Apple 公证，macOS 可能在首次打开时阻止运行。用户需要在“系统设置 → 隐私与安全性”中确认打开。后续版本仍通过 Sparkle appcast 的 EdDSA 签名验证更新完整性。
