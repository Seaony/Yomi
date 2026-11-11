# dmgbuild 配置：固定窗口大小、隐藏工具栏和侧边栏、大图标左右摆放，并使用同目录的背景图。
# 用法（在仓库根目录执行）：
#   dmgbuild -s scripts/dmg/dmg-settings.py -D app=<Yomi.app 路径> Yomi <输出.dmg>
# 窗口尺寸和图标位置必须和 render-background.swift 保持一致。

import os

# defines 由 dmgbuild 注入；它执行配置时没有 __file__，背景图按仓库根目录找。
app_path = defines["app"]  # noqa: F821
app_name = os.path.basename(app_path)
settings_dir = defines.get("dmg_dir", "scripts/dmg")  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app_path]
symlinks = {"Applications": "/Applications"}

# 挂载后的卷图标沿用应用图标。
volume_icon = os.path.join(app_path, "Contents/Resources/AppIcon.icns")
if os.path.exists(volume_icon):
    icon = volume_icon

background = os.path.join(settings_dir, "background.png")
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 14
label_pos = "bottom"
icon_locations = {
    app_name: (165, 185),
    "Applications": (495, 185),
}
