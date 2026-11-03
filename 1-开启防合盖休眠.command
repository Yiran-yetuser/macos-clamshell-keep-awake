#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  ① 开启「合盖不休眠」
#  效果：合上笔记本盖子后，系统继续运行、网络不断、Tailscale 保持在线、
#        远程桌面（RustDesk / ToDesk / 屏幕共享）随时可以连进来。
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=.lib.sh
source "$HERE/.lib.sh"

title "① 开启「合盖不休眠」"
hr
info "机型：$(sysctl -n hw.model 2>/dev/null) · 芯片：$(sysctl -n machdep.cpu.brand_string 2>/dev/null) · 系统：macOS $(sw_vers -productVersion 2>/dev/null)"
printf '\n'

cur="$(sleep_disabled)"
kern="$(sleep_disabled_kernel)"

if [ "$cur" = "1" ] && [ "$kern" = "Yes" ]; then
  ok "「合盖不休眠」已经处于开启状态，无需重复设置。"
  info "（pmset 记录 SleepDisabled=1，内核实时值 SleepDisabled=Yes）"
  log "开启脚本：检测到已开启（pmset=1 / 内核=Yes），跳过设置"
  printf '\n'
  info "如果想确认效果，直接运行「4-合盖测试.command」即可。"
  pause_exit
  exit 0
fi

printf '正在请求管理员权限…\n'
info "稍后会弹出系统授权窗口，请输入你的开机密码（密码只交给系统，不会保存到任何文件）。"
info "也可以用 Touch ID 授权（如果弹窗里有这个选项）。"
printf '\n'

out="$(run_pmset_admin "disablesleep 1" "开启合盖不休眠需要管理员权限")"
rc=$?

if [ $rc -ne 0 ]; then
  case "$out" in
    *-128*|*User\ canceled*)
      warn "已取消授权，「合盖不休眠」没有开启。"
      log "开启脚本：用户在授权窗口点了取消"
      ;;
    *)
      bad "设置失败：$out"
      log "开启脚本：设置失败，osascript 输出：$out"
      ;;
  esac
  pause_exit
  exit 1
fi

# ── 验证 ────────────────────────────────────────────────────────────
printf '\n'
after="$(sleep_disabled)"
kern_after="$(sleep_disabled_kernel)"

if [ "$after" = "1" ] && [ "$kern_after" = "Yes" ]; then
  ok "已开启「合盖不休眠」"
  info "pmset 记录 SleepDisabled=$after  ·  内核实时值 SleepDisabled=$kern_after"
  hr
  printf '%s效果：%s\n' "$BOLD" "$NC"
  printf '  · 合上盖子后系统不再休眠，Wi-Fi / 有线网络保持连接\n'
  printf '  · Tailscale 保持在线，可以从别的设备随时连回这台 Mac\n'
  printf '  · RustDesk / ToDesk 等远程桌面保持可连接\n'
  printf '\n%s注意：%s\n' "$YELLOW" "$NC"
  printf '  · 合盖状态下电池会持续耗电（约 5%%%%~10%%%%/小时，取决于负载）\n'
  printf '  · 机器会持续发热，放进包里或抽屉前请先运行「② 关闭防合盖休眠」\n'
  printf '  · 设置会一直保留（关机、重启后依然有效）；macOS 大版本升级后建议再运行「③ 查看状态」复查一次\n'
  printf '\n%s下一步：%s运行「4-合盖测试.command」做一次真实合盖验证。\n' "$CYAN" "$NC"
  log "开启脚本：设置成功（pmset=1 / 内核=Yes）"
else
  bad "设置似乎没有生效（pmset=$after，内核=$kern_after）"
  info "请把上面的输出截图发给助手，或者重启后再试一次。"
  log "开启脚本：设置后验证失败（pmset=$after / 内核=$kern_after）"
fi

pause_exit
