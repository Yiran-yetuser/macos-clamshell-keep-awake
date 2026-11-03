#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  ② 关闭「合盖不休眠」（恢复到 macOS 默认行为：合盖即休眠）
#  建议：把 Mac 装进包里、出差路上、或者不打算远程连接时运行本脚本。
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=.lib.sh
source "$HERE/.lib.sh"

title "② 关闭「合盖不休眠」"
hr

cur="$(sleep_disabled)"
kern="$(sleep_disabled_kernel)"

if [ "$cur" != "1" ] && [ "$kern" != "Yes" ]; then
  ok "当前已经是 macOS 默认行为（合盖即休眠），无需修改。"
  log "关闭脚本：检测到已关闭（pmset=$cur / 内核=$kern），跳过设置"
  pause_exit
  exit 0
fi

printf '将把合盖行为恢复为 macOS 默认：合上盖子就休眠（省电、不发热）。\n'
info "稍后会弹出系统授权窗口，请输入开机密码。"
printf '\n'

out="$(run_pmset_admin "disablesleep 0" "恢复默认合盖休眠需要管理员权限")"
rc=$?

if [ $rc -ne 0 ]; then
  case "$out" in
    *-128*|*User\ canceled*)
      warn "已取消授权，设置没有改变（当前仍是「合盖不休眠」）。"
      log "关闭脚本：用户取消授权"
      ;;
    *)
      bad "设置失败：$out"
      log "关闭脚本：设置失败，osascript 输出：$out"
      ;;
  esac
  pause_exit
  exit 1
fi

printf '\n'
after="$(sleep_disabled)"
kern_after="$(sleep_disabled_kernel)"

if [ "$after" != "1" ] && [ "$kern_after" != "Yes" ]; then
  ok "已关闭「合盖不休眠」，恢复为合盖即休眠。"
  info "pmset 记录 SleepDisabled=${after:-未设置}  ·  内核实时值 SleepDisabled=${kern_after:-No}"
  info "现在合上盖子系统会正常休眠，不再持续耗电。"
  log "关闭脚本：设置成功（pmset=${after:-空} / 内核=${kern_after:-空}）"
else
  bad "设置似乎没有生效（pmset=$after，内核=$kern_after）"
  info "请把上面的输出截图发给助手。"
  log "关闭脚本：设置后验证失败（pmset=$after / 内核=$kern_after）"
fi

pause_exit
