# CodeEdge 快速发布说明

CodeEdge 使用 Sparkle 进行应用内更新，更新文件托管在 GitHub Releases。发布版本用 Developer ID 签名并经过 Apple 公证，用户下载后可以直接打开。

发版用所有 App 共用的脚本 `~/.agents/skills/mac-release/scripts/mac-release`（全局技能 `mac-release`，用法和失败重跑说明见它的 `SKILL.md`）。CodeEdge 自己的差异写在 `scripts/release-config.sh`：用 `scripts/dmg/` 的配置打 DMG，用 `scripts/validate-release.sh` 检查产物。脚本依次：

1. 检查分支、工作区、远端同步、GitHub 登录、签名证书、公证凭据、Sparkle 密钥和版本是否已发布。
2. 按上一个正式 Release 的 `appcast.xml` 把 build number 加 1。
3. 构建 `arm64` + `x86_64` 通用应用，用 Developer ID 由内到外逐个签名，开启 Hardened Runtime 并带时间戳。
4. 用 `dmgbuild` 打 DMG 并签名，只把 DMG 交给 Apple 公证一次，通过后给 DMG 和应用装订票据。
5. 用装订好的应用打 ZIP，生成 Release Notes 和带 EdDSA 签名的 `appcast.xml`。
6. 推送版本标签，先建草稿 Release 上传 DMG、ZIP、`appcast.xml`，再正式发布，并核对线上更新源已指向新版本。

应用固定读取以下更新源：

```text
https://github.com/Seaony/CodeEdge/releases/latest/download/appcast.xml
```

## 首次准备

需要安装并登录 GitHub CLI：

```bash
gh auth login
gh auth status
```

本机还需要可用的 Xcode、Command Line Tools，以及以下命令：

```text
gh xcodebuild ditto hdiutil xmllint lipo codesign dmgbuild xcrun spctl
```

登录钥匙串里要有 Developer ID Application 证书。脚本默认用 `Developer ID Application: SHEN WANG (JJJKGPY7T7)`，换证书时在 `scripts/release-config.sh` 里设置 `SIGN_IDENTITY`。确认证书在：

```bash
security find-identity -v -p codesigning
```

公证凭据只需要存一次。去 [appleid.apple.com](https://appleid.apple.com) 生成一个 App 专用密码，然后运行下面的命令，按提示填 Apple ID 和这个密码：

```bash
xcrun notarytool store-credentials notary --team-id JJJKGPY7T7
```

脚本默认读取名为 `notary` 的凭据，换名字时在 `scripts/release-config.sh` 里设置 `NOTARY_PROFILE`。凭据不能用时，脚本会在开始构建前停下。

`dmgbuild` 用 uv 安装：

```bash
uv tool install dmgbuild
```

## DMG 安装窗口

DMG 的外观由 `scripts/dmg/` 决定：

- `dmg-settings.py`：窗口大小、隐藏工具栏和侧边栏、图标大小和位置、卷图标。
- `background.png` / `background@2x.png`：窗口背景，由 `render-background.swift` 生成，打包时自动合成 Retina 背景。
- `render-volume-icon.swift`：打包时自动运行，把仓库里 1024 的满版 App 图标裁成标准圆角，作为挂载后的卷图标。直接用 App 里的 `AppIcon.icns` 会显示成方块，而且它最大只有 256，会糊。

改了窗口尺寸或图标位置时，两个文件里的数值要一起改，然后重新生成背景：

```bash
swift scripts/dmg/render-background.swift scripts/dmg
```

不发版、只看效果时，可以拿任意一个构建好的 `CodeEdge.app` 打一个预览：

```bash
dmgbuild -s scripts/dmg/dmg-settings.py -D app=/tmp/CodeEdgeDerivedData/Build/Products/Debug/CodeEdge.app CodeEdge /tmp/CodeEdge-preview.dmg
open /tmp/CodeEdge-preview.dmg
```

Sparkle 的 EdDSA 私钥必须位于登录钥匙串。CodeEdge 当前沿用自动更新配置中已有的 `com.seaony.Moni` Sparkle 密钥账户，脚本默认读取该账户。可以这样确认它存在：

```bash
security find-generic-password \
  -a com.seaony.Moni \
  -s https://sparkle-project.org
```

Sparkle 的 EdDSA 签名是自动更新校验所必需的，和 Developer ID 签名、公证是两套独立的校验，缺一不可。

## 发布新版本

发布前先把准备发布的内容 commit 并推送到 `origin/master`，确保工作区完全干净。然后在仓库根目录后台运行，只传入三段式版本号：

```bash
~/.agents/skills/mac-release/scripts/mac-release 1.0.1
```

加 `--dry-run` 只试跑：完整构建、公证、生成产物并验证，不打标签、不发布。

某一版需要额外提醒用户时（比如换签名后第一次启动会弹钥匙串确认），用 `RELEASE_NOTE` 追加一段说明，它会出现在 GitHub Release 和 Sparkle 更新窗口里：

```bash
RELEASE_NOTE="……" ~/.agents/skills/mac-release/scripts/mac-release 1.0.1
```

脚本会把 DMG 上传给 Apple 公证、推送标签 `v1.0.1`、在 `Seaony/CodeEdge` 创建 Release 并上传 ZIP、DMG 和 `appcast.xml`。它不会 commit，也不会推送 `master`。

中途失败（断网、公证等太久被打断）时原样重跑同一条命令：同一提交的产物会接着用，已提交的公证按 `notary-id` 接着等，不会重新上传。

本地产物和日志保存在 `build/releases/v1.0.1/`：

```text
CodeEdge-1.0.1.zip
CodeEdge-1.0.1.dmg
appcast.xml
notes.md
release.log
stage/CodeEdge.app
```

需要单独复查时：

```bash
scripts/validate-release.sh \
  build/releases/v1.0.1/stage/CodeEdge.app \
  build/releases/v1.0.1/appcast.xml
```

## 从未签名版本升级

1.6.3 之前的版本只有本地临时签名。CodeEdge 存在钥匙串里的密钥，访问权限绑定的是签名身份，所以从旧版升级到第一个签名版本后，第一次启动会为每个已存的密钥弹一次钥匙串确认，选「始终允许」即可。之后签名身份固定，升级不会再弹。
