#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  ② 关闭「合盖不休眠」（恢复到 macOS 默认行为：合盖即休眠）
#  建议：把 Mac 装进包里、出差路上、或者不打算远程连接时运行本脚本。
#
#  本脚本会撤掉两样东西：
#    · 用户级「合盖画面守护」com.yyz.lidawake（不需要密码）
#    · 系统级 pmset disablesleep 与休眠守护 com.yyz.keepawake（需要密码）
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=.lib.sh
source "$HERE/.lib.sh"

title "② 关闭「合盖不休眠」"
hr

cur="$(sleep_disabled)"
kern="$(sleep_disabled_kernel)"
dm="$(keepawake_daemon)"
lw="$(lidwatch_status)"

root_on=0
{ [ "$cur" = "1" ] || [ "$kern" = "Yes" ] || [ "$dm" = "running" ]; } && root_on=1
lid_on=0
[ "$lw" = "running" ] && lid_on=1

if [ "$root_on" = "0" ] && [ "$lid_on" = "0" ]; then
  ok "当前已经是 macOS 默认行为（合盖即休眠），无需修改。"
  log "关闭脚本：检测到已关闭（pmset=$cur / 内核=$kern / 休眠守护未运行 / 画面守护未运行），跳过设置"
  pause_exit
  exit 0
fi

# ── 第一步：先停用户级画面守护（不需要密码，顺便恢复屏幕亮度）────────
if [ "$lid_on" = "1" ]; then
  uninstall_lidwatch >/dev/null 2>&1
  info "已停止「合盖画面守护」，屏幕亮度已恢复。"
  log "关闭脚本：已卸载画面守护 com.yyz.lidawake"
fi

# ── 第二步：系统级设置（需要管理员密码）──────────────────────────────
if [ "$root_on" = "1" ]; then
  printf '将把合盖行为恢复为 macOS 默认：合上盖子就休眠（省电、不发热）。\n'
  info "稍后会弹出系统授权窗口，请输入开机密码。"
  printf '\n'
  out="$(run_admin_script "$HERE/.admin-disable.sh" "恢复默认合盖休眠需要管理员权限")"
  rc=$?
  if [ $rc -ne 0 ]; then
    case "$out" in
      *-128*|*User\ canceled*)
        warn "已取消授权，系统设置没有改变（当前仍是「合盖不休眠」）。"
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
fi

# ── 验证 ────────────────────────────────────────────────────────────
printf '\n'
after="$(sleep_disabled)"
kern_after="$(sleep_disabled_kernel)"
lw_after="$(lidwatch_status)"

if [ "$after" != "1" ] && [ "$kern_after" != "Yes" ] && [ "$lw_after" != "running" ]; then
  ok "已关闭「合盖不休眠」，恢复为合盖即休眠。"
  info "pmset 记录 SleepDisabled=${after:-未设置}  ·  内核实时值 SleepDisabled=${kern_after:-No}"
  info "合盖画面守护：已停止（虚拟屏与亮度改动已自动清理）"
  info "现在合上盖子系统会正常休眠，不再持续耗电。"
  log "关闭脚本：设置成功（pmset=${after:-空} / 内核=${kern_after:-空} / 画面守护=${lw_after}）"
else
  bad "设置似乎没有完全生效（pmset=$after，内核=$kern_after，画面守护=$lw_after）"
  info "请把上面的输出截图发给助手。"
  log "关闭脚本：设置后验证失败（pmset=$after / 内核=$kern_after / 画面守护=$lw_after）"
fi

pause_exit
