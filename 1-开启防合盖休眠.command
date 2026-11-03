#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  ① 开启「合盖不休眠」
#  效果：合上笔记本盖子后，系统继续运行、网络不断、Tailscale 保持在线、
#        远程桌面（RustDesk / ToDesk / 屏幕共享）随时可以连进来看到真实画面。
#
#  本脚本会安装两样东西：
#    · 系统级（要管理员密码）：pmset disablesleep 1 + 守护进程
#      com.yyz.keepawake —— 防止开关被第三方软件改回 0（ToDesk 会这么干）
#    · 用户级（不要密码）：合盖画面守护 com.yyz.lidawake
#      合盖时把内建屏背光归零（屏幕物理上不亮，系统继续渲染），
#      只有当系统真的停止渲染时才补建 HiDPI 虚拟屏兜底；开盖恢复亮度
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=.lib.sh
source "$HERE/.lib.sh"

title "① 开启「合盖不休眠」"
hr
info "机型：$(sysctl -n hw.model 2>/dev/null) · 芯片：$(sysctl -n machdep.cpu.brand_string 2>/dev/null) · 系统：macOS $(sw_vers -productVersion 2>/dev/null)"
printf '\n'

# ── 检查当前状态 ────────────────────────────────────────────────────
root_ok=0
[ "$(sleep_disabled)" = "1" ] && [ "$(sleep_disabled_kernel)" = "Yes" ] && [ "$(keepawake_daemon)" = "running" ] && root_ok=1
lid_ok=0
[ "$(lidwatch_status)" = "running" ] && lid_ok=1

if [ "$root_ok" = "1" ] && [ "$lid_ok" = "1" ]; then
  ok "「合盖不休眠」已经处于开启状态，无需重复设置。"
  info "（pmset SleepDisabled=1 · 内核实时值 Yes · 休眠守护进程运行中 · 画面守护进程运行中）"
  log "开启脚本：检测到已完整开启，跳过设置"
  printf '\n'
  info "如果想确认效果，直接运行「4-合盖测试.command」即可。"
  pause_exit
  exit 0
fi

# ── 第一步：系统级设置（需要管理员密码）──────────────────────────────
if [ "$root_ok" = "0" ]; then
  printf '正在请求管理员权限…\n'
  info "稍后会弹出系统授权窗口，请输入你的开机密码（密码只交给系统，不会保存到任何文件）。"
  info "也可以用 Touch ID 授权（如果弹窗里有这个选项）。"
  printf '\n'
  out="$(run_admin_script "$HERE/.admin-enable.sh" "开启合盖不休眠需要管理员权限")"
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
else
  info "系统级设置已经是开启状态（pmset=1 / 内核=Yes / 休眠守护运行中），跳过密码步骤。"
fi

# ── 第二步：用户级「合盖画面守护」（不需要密码）──────────────────────
printf '\n正在安装「合盖画面守护」（合盖后让远程桌面仍能看到画面，不需要密码）…\n'
if [ "$(install_lidwatch)" != "ok" ]; then
  bad "合盖画面守护安装失败"
  info "可以查看日志：$(support_dir)/logs/lidwatch.err"
  log "开启脚本：画面守护安装失败"
  pause_exit
  exit 1
fi
/bin/sleep 2

# ── 验证 ────────────────────────────────────────────────────────────
printf '\n'
after="$(sleep_disabled)"
kern_after="$(sleep_disabled_kernel)"
dm="$(keepawake_daemon)"
lw="$(lidwatch_status)"

if [ "$after" = "1" ] && [ "$kern_after" = "Yes" ] && [ "$lw" = "running" ]; then
  ok "已开启「合盖不休眠」"
  info "pmset 记录 SleepDisabled=$after  ·  内核实时值 SleepDisabled=$kern_after"
  if [ "$dm" = "running" ]; then
    info "休眠守护 yz-keepawake：运行中（每 2 秒检查，开关被改回 0 会自动恢复）"
  else
    warn "休眠守护没起来（daemon=$dm），开关可能被第三方软件改回 0"
  fi
  info "画面守护 com.yyz.lidawake：运行中（合盖→背光归零、按需兜底虚拟屏；开盖→自动恢复）"
  hr
  printf '%s效果：%s\n' "$BOLD" "$NC"
  printf '  · 合上盖子后系统不再休眠，Wi-Fi / 有线网络保持连接\n'
  printf '  · Tailscale 保持在线，可以从别的设备随时连回这台 Mac\n'
  printf '  · 合盖后内建屏会「黑掉」（背光归零）但系统仍在渲染\n'
  printf '    → RustDesk / ToDesk 等远程桌面连进来可以看到真实画面（不是黑屏）\n'
  printf '  · 打开盖子后：屏幕亮度自动恢复，兜底虚拟屏自动移除\n'
  printf '\n%s注意：%s\n' "$YELLOW" "$NC"
  printf '  · 合盖状态下电池会持续耗电（约 5%%~10%%/小时，取决于负载）\n'
  printf '  · 机器会持续发热，放进包里或抽屉前请先运行「② 关闭防合盖休眠」\n'
  printf '  · 设置会一直保留（关机、重启后依然有效）；macOS 大版本升级后建议再运行「③ 查看状态」复查一次\n'
  printf '\n%s关于 ToDesk：%s\n' "$YELLOW" "$NC"
  printf '  · 本机的 ToDesk 辅助进程会在某些时刻调用 pmset，把这个开关改回「0」\n'
  printf '    （证据：~/Library/Logs/ToDesk/ToDesk_XPCHelper_*.log 里的 “set disable sleep: 0”）。\n'
  printf '  · 所以这里额外装了守护进程，发现被改回 0 就自动恢复成 1，并在 /var/log/yz-keepawake.log 记账。\n'
  printf '  · 如果不再需要 ToDesk，退出或卸载它可以让设置更稳定。\n'
  printf '\n%s下一步：%s运行「4-合盖测试.command」做一次真实合盖验证。\n' "$CYAN" "$NC"
  log "开启脚本：设置成功（pmset=1 / 内核=Yes / 休眠守护=$dm / 画面守护=$lw）"
else
  bad "设置似乎没有完全生效（pmset=$after / 内核=$kern_after / 画面守护=$lw）"
  info "请把上面的输出截图发给助手，或者重启后再试一次。"
  log "开启脚本：设置后验证失败（pmset=$after / 内核=$kern_after / 画面守护=$lw）"
fi

pause_exit
