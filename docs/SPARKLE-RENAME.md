# CodeEdge 改名后的 Sparkle 更新兼容性

本次调查基于项目锁定的 Sparkle **2.9.6**，源码提交为 `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`，与本机 SPM checkout 一致。只读源码，没有制作或安装真实更新包，也没有修改应用或发布流程代码。

正常安装为 `Yomi.app`、Bundle ID 为 `com.seaony.Yomi` 的旧版，不能直接识别当前普通 ZIP / DMG 中的 `CodeEdge.app`（`com.seaony.CodeEdge`）。失败发生在寻找安装候选时，早于替换应用。

Sparkle 依次尝试下面的匹配方式：

1. 更新中的文件名与旧 app 的文件名相同。
2. 更新中的文件名与旧 app 的显示名加扩展名相同。
3. 更新中的 Bundle ID 与旧 app 相同。

当前新包的文件名、显示名和 Bundle ID 都变了，因此三种匹配都失败。`SUUpdateValidator` 取不到安装源便返回验证失败；后面的安装器也会把缺少候选视为错误。保留同一把 EdDSA 密钥不能解决候选匹配失败。

准确地说，不能把这个结果概括为“Bundle ID 不同就一律拒绝”：文件名先命中时，这一处不会再要求 Bundle ID 相同；签名验证还允许有效的旧 EdDSA 签名支持代码签名身份变化。候选能否找到、签名和版本等后续检查能否通过，是分别处理的条件。本次调查没有验证任何替代更新包的实际安装行为。

如果一个候选能被识别且通过其余校验，默认安装路径是旧宿主的 `bundlePath`。对于正常位于 `/Applications/Yomi.app` 的旧版，磁盘上的包名仍会是 **`Yomi.app`**，不会直接采用下载包中的 `CodeEdge.app` 名称。上游默认关闭安装名归一化；即使启用，归一化名称也是从旧宿主的 `SUBundleName` / `CFBundleName` 生成，而不是从新包取名。这里说的是磁盘包名，产品显示名由包内信息另行决定。

因此，当前普通 ZIP / DMG 流程没有完成旧版到新包的自动过渡；首次采用新包的安装安排需要单独处理。本轮仅记录这个结论。

源码出处均固定到上述提交：

- [SUInstaller.m:24–110](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Autoupdate/SUInstaller.m#L24-L110)：旧文件名、旧显示名、旧 Bundle ID 的候选匹配顺序。
- [SUHost.m:121–135](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Sparkle/SUHost.m#L121-L135)：旧显示名从 `SUBundleName`、`CFBundleDisplayName`、`CFBundleName` 取值。
- [SUUpdateValidator.m:128–139](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Sparkle/SUUpdateValidator.m#L128-L139)：找不到安装候选即拒绝更新。
- [SUInstaller.m:159–169](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Autoupdate/SUInstaller.m#L159-L169)：安装阶段同样要求存在候选。
- [SUUpdateValidator.m:298–376](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Sparkle/SUUpdateValidator.m#L298-L376)：EdDSA 与代码签名验证的关系。
- [SUInstaller.m:274–289](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Autoupdate/SUInstaller.m#L274-L289)：目标安装路径默认使用旧 `host.bundlePath`。
- [ConfigCommon.xcconfig:88–94](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Configurations/ConfigCommon.xcconfig#L88-L94) 和 [SUNormalization.m:14–25](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Sparkle/SUNormalization.m#L14-L25)：归一化默认关闭，启用时使用旧宿主名称。
- [SUPlainInstaller.m:235–298](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Autoupdate/SUPlainInstaller.m#L235-L298) 和 [389–393](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Autoupdate/SUPlainInstaller.m#L389-L393)：实际替换、移动都使用已选定的安装目标。
