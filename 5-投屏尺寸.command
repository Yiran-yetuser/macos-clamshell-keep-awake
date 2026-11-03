#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  5-投屏尺寸.command —— 调整远程端看到的画面比例 / 大小 / 清晰度
#
#  高清投屏会建一块虚拟屏并把内建屏镜像过去，远程端只看到这一块屏：
#    · 比例由虚拟屏决定（16:10 表示远程窗口不会被拉伸）
#    · 「界面大小」由逻辑分辨率决定：逻辑越小，字越大
#    · 「清晰度」由物理像素决定：开 2x 后物理像素翻倍
#    · 第 4 个词 always = 开盖也保持该比例；lidonly = 只在合盖时启用
#
#  改完立即重启画面守护生效；不需要管理员密码。
# ─────────────────────────────────────────────────────────────────────

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/.lib.sh"

SUP="$(support_dir)"
CONF="$SUP/hd.conf"
mkdir -p "$SUP" 2>/dev/null

current() {
  if [ -f "$CONF" ]; then
    /usr/bin/grep -v '^[[:space:]]*#' "$CONF" | /usr/bin/grep -v '^[[:space:]]*$' | /usr/bin/head -1
  else
    echo "（未设置，默认 1920 1200 1 always）"
  fi
}

apply_conf() {   # $1 = 配置内容（一行）
  printf '%s\n' "$1" >"$CONF"
  local uid plist="$HOME/Library/LaunchAgents/com.yyz.lidawake.plist"
  uid="$(/usr/bin/id -u)"
  if [ ! -f "$plist" ]; then
    warn "画面守护还没安装，先运行「1-开启防合盖休眠.command」。配置已保存，安装后即生效。"
    return 0
  fi
  /bin/launchctl kickstart -k "gui/$uid/com.yyz.lidawake" >/dev/null 2>&1 \
    || { /bin/launchctl bootout "gui/$uid/com.yyz.lidawake" >/dev/null 2>&1
         /bin/sleep 1
         /bin/launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1; }
  ok "已更新：$(current)"
}

title "投屏尺寸 / 比例（远程端看到的画面）"
echo
info "当前设置：$(current)"
echo
echo "  1) 1920×1200 @2x  → 物理 3840×2400   16:10，界面大（默认）"
echo "  2) 1920×1200 @2x  → 同上，但【仅合盖时】启用，开盖恢复内建屏 3:2"
echo "  3) 2560×1600 @2x  → 物理 5120×3200   16:10，字更小、更细腻（码率高）"
echo "  4) 1920×1080 @2x  → 物理 3840×2160   16:9，客户端是 16:9 时无黑边"
echo "  5) 关闭高清投屏    → 合盖只关背光，远程看到内建屏 3:2"
echo "  6) 自定义（自己输入 宽 高 是否 2x 是否始终启用）"
echo "  0) 退出"
echo
printf '请选择 [0-6]: '
read -r choice

case "${choice:-}" in
  1) apply_conf "1920 1200 1 always" ;;
  2) apply_conf "1920 1200 1 lidonly" ;;
  3) apply_conf "2560 1600 1 always" ;;
  4) apply_conf "1920 1080 1 always" ;;
  5) apply_conf "off" ;;
  6)
    echo
    printf '宽（如 1920）: '; read -r w
    printf '高（如 1200）: '; read -r h
    printf 'Retina 2x?（1=是，0=否，默认 1）: '; read -r d
    printf '始终启用?（always / lidonly，默认 always）: '; read -r m
    d="${d:-1}"; m="${m:-always}"
    case "${w}${h}${d}" in *[!0-9]*|"") bad "输入无效"; pause_exit 1 ;; esac
    [ "$w" -ge 800 ] && [ "$h" -ge 600 ] || { bad "宽高太小（至少 800×600）"; pause_exit 1; }
    apply_conf "$w $h $d $m"
    ;;
  0|"") info "已取消"; pause_exit 0 ;;
  *) bad "无效选择"; pause_exit 1 ;;
esac

echo
info "约 5~15 秒内生效（守护会自动重建虚拟屏）。"
info "如果开盖时本机屏幕变黑（高清投屏占用了显示器），运行本脚本选 2) 或 5) 即可恢复。"
pause_exit 0
