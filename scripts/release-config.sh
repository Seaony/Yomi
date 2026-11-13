# 发版配置，由共用脚本 ~/.agents/skills/mac-release/scripts/mac-release 读取，变量说明见同目录的 SKILL.md。
APP_NAME=CodeEdge
DMG_SETTINGS=scripts/dmg/dmg-settings.py
release_validate() { scripts/validate-release.sh "$1" "${2:-}"; }
