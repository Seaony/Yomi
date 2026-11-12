# App 图标和 Logo

## 现在用的

- App 图标：`第五批/P2-seal.png`（果冻质感的海豹），已生成全部尺寸放进 `CodeEdge/Assets.xcassets/AppIcon.appiconset`。
- Logo：`正式资源/logo-512.png`，透明背景，只有海豹和圆环。用在竖栏总览和总览卡标题，对应 `CodeEdge/Assets.xcassets/AppLogo.imageset`。
- 旧图标：`旧图标-Yomi.png`。

## 抽卡记录

每批约 10 张，图和提示词（`prompts/`）都在对应目录里。

- 第一批：参考图约束太多，3D 太重。
- 第二批：严格按极简 IP 画法，太平。
- 第三批：整体质量最好，N1–N3 果冻风最受喜欢。
- 第四批：硬加「贴边探头」和「额度圆环」，反而变差。
- 第五批：P2 海豹中选。

以后想换图标，在这里新建「第六批」继续抽。对比图不进仓库，需要时重新生成：

```sh
swift ~/.claude/skills/icon-logo/scripts/contact-sheet.swift design/app-icon/第五批
```
