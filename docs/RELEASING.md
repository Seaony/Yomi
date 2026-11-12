# CodeEdge 快速发布说明

CodeEdge 使用 Sparkle 进行应用内更新，更新文件托管在 GitHub Releases。发布版本用 Developer ID 签名并经过 Apple 公证，用户下载后可以直接打开。

发布脚本会自动完成以下工作：

1. 检查当前是否位于 `master`，并确认工作区干净且与 `origin/master` 完全一致。
2. 检查版本标签和 GitHub Release 是否已经存在。
3. 根据上一个正式 Release 的 `appcast.xml` 自动递增 build number；首次发布从 `1` 开始。
4. 构建包含 `arm64` 和 `x86_64` 的 Release 应用。
5. 用 Developer ID 从里往外签名 Sparkle 的组件和应用，开启 Hardened Runtime 并带时间戳。
6. 用 `dmgbuild` 打包 DMG，打开后是带背景图、大图标、拖到 Applications 的安装窗口。DMG 签名后交给 Apple 公证，只交这一次：里面的应用会一起检查。通过后把票据装订到 DMG 和应用上。
7. 用装订好的应用打 ZIP，生成 Release Notes 和带 EdDSA 签名的 `appcast.xml`。
8. 创建并推送版本标签，随后创建 GitHub Release 并上传全部产物。

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

登录钥匙串里要有 Developer ID Application 证书。脚本默认用 `Developer ID Application: SHEN WANG (JJJKGPY7T7)`，换证书时设置 `SIGNING_IDENTITY`。确认证书在：

```bash
security find-identity -v -p codesigning
```

公证凭据只需要存一次。去 [appleid.apple.com](https://appleid.apple.com) 生成一个 App 专用密码，然后运行下面的命令，按提示填 Apple ID 和这个密码：

```bash
xcrun notarytool store-credentials notary --team-id JJJKGPY7T7
```

脚本默认读取名为 `notary` 的凭据，换名字时设置 `NOTARY_PROFILE`。凭据不能用时，脚本会在开始构建前停下。

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

发布前先把准备发布的内容 commit 并推送到 `origin/master`，确保工作区完全干净。然后只传入三段式版本号：

```bash
scripts/publish-release.sh 1.0.1
```

某一版需要额外提醒用户时（比如换签名后第一次启动会弹钥匙串确认），用 `RELEASE_NOTE` 追加一段说明，它会出现在 GitHub Release 和 Sparkle 更新窗口里：

```bash
RELEASE_NOTE="……" scripts/publish-release.sh 1.0.1
```

脚本会执行外部写操作，包括：

- 把 DMG 上传给 Apple 公证；
- 创建本地标签 `v1.0.1`；
- 将该标签推送到 `origin`；
- 创建 `Seaony/CodeEdge` 的 GitHub Release；
- 上传 ZIP、DMG 和 `appcast.xml`。

脚本不会自动 commit，也不会推送 `master`。如果工作区不干净、本地提交尚未推送、版本已存在或 GitHub CLI 未登录，脚本会在发布前停止。

本地产物保存在：

```text
build/releases/v1.0.1/
```

其中包括：

```text
CodeEdge-1.0.1.zip
CodeEdge-1.0.1.dmg
appcast.xml
```

## 单独验证产物

构建完成后可单独验证应用和 appcast：

```bash
scripts/validate-release.sh \
  build/releases/v1.0.1/CodeEdge.app \
  build/releases/v1.0.1/appcast.xml
```

发布脚本生成的目录默认不保留独立 `CodeEdge.app`，因此通常无需手动执行该命令；脚本已经在打包前自动验证构建产物，并在生成 appcast 后再次验证。

## 从未签名版本升级

1.6.3 之前的版本只有本地临时签名。CodeEdge 存在钥匙串里的密钥，访问权限绑定的是签名身份，所以从旧版升级到第一个签名版本后，第一次启动会为每个已存的密钥弹一次钥匙串确认，选「始终允许」即可。之后签名身份固定，升级不会再弹。
