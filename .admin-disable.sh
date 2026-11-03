#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  以 root 身份执行：关闭合盖不休眠 + 卸载「守护进程」
#  由「2-关闭防合盖休眠.command」通过 osascript 以管理员权限调用。
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail

BIN=/usr/local/sbin/yz-keepawake.sh
PLIST=/Library/LaunchDaemons/com.yyz.keepawake.plist

# ── 1. 先卸载守护进程（否则它会把开关又改回 1）──────────────────────
/bin/launchctl bootout system/com.yyz.keepawake 2>/dev/null
/bin/sleep 0.3
/bin/rm -f "$PLIST" "$BIN"

# ── 2. 恢复 macOS 默认：合盖即休眠 ──────────────────────────────────
/usr/bin/pmset -a disablesleep 0

printf 'pmset=%s\n' "$(/usr/bin/pmset -g 2>/dev/null | /usr/bin/awk '/SleepDisabled[ \t]/{print $2}')"
if /bin/launchctl print system/com.yyz.keepawake >/dev/null 2>&1; then
  printf 'daemon=running\n'
else
  printf 'daemon=missing\n'
fi
exit 0
