#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  5-投屏尺寸.command —— 调整「合盖后远程画面的分辨率」
#
#  合盖时画面守护会建一块虚拟屏，把内建屏镜像过去，远程拿到的就是这块虚拟屏
#  的物理像素尺寸。这里改的就是它的「界面尺寸（逻辑点数）」和像素密度：
#
#    · 逻辑尺寸越小 → 界面元素越大（看起来「放大」）
#    · 逻辑尺寸相同、开 Retina 2x → 物理像素翻倍（看起来更清晰，带宽更高）
#
#  改完会重启画面守护让它立即生效；此时如果正合着盖子，约 15 秒内自动切换。
#  不需要管理员密码。
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
    echo "（未设置，默认 2560 1600 1）"
  fi
}

apply_conf() {   # $1 = 配置文件内容（一行）
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

title "投屏尺寸（合盖后远程画面的清晰度 / 大小）"
echo
info "当前设置：$(current)"
echo
echo "  1) 2560×1600  → 物理 5120×3200   16:10，最清晰，带宽最高（默认）"
echo "  2) 1920×1200  → 物理 3840×2400   4K 像素 + 界面放大，16:10"
echo "  3) 1920×1080  → 物理 3840×2160   4K + 界面放大，16:9（客户端是 16:9 时无黑边）"
echo "  4) 关闭高清投屏 → 合盖只关背光，画面仍来自内建屏（3:2）"
echo "  5) 自定义（自己输入 宽 高 是否 2x）"
echo "  0) 退出"
echo
printf '请选择 [0-5]: '
read -r choice

case "${choice:-}" in
  1) apply_conf "2560 1600 1"; echo; info "说明：内建屏 3:2，用 16:10 画布会左右/上下留一点边，但界面清晰。" ;;
  2) apply_conf "1920 1200 1"; echo; info "说明：物理 3840×2400（4K 级像素），界面按 1920×1200 放大，看着更大更清晰。" ;;
  3) apply_conf "1920 1080 1"; echo; info "说明：物理 3840×2160 正好 4K 16:9，客户端 16:9 时无黑边、字更大。" ;;
  4) apply_conf "off";          echo; info "说明：只关背光；远程画面来自内建屏 2940×1912（3:2）。" ;;
  5)
    echo
    printf '宽（如 1920）: '; read -r w
    printf '高（如 1200）: '; read -r h
    printf 'Retina 2x?（1=是，0=否，默认 1）: '; read -r d
    d="${d:-1}"
    case "${w}${h}${d}" in *[!0-9]*|"") bad "输入无效"; pause_exit 1 ;; esac
    [ "$w" -ge 800 ] && [ "$h" -ge 600 ] || { bad "宽高太小（至少 800×600）"; pause_exit 1; }
    apply_conf "$w $h $d"
    ;;
  0|"") info "已取消"; pause_exit 0 ;;
  *) bad "无效选择"; pause_exit 1 ;;
esac

echo
info "提示：如果正合着盖子，约 15 秒内会自动切换到新尺寸；开盖即恢复原样。"
pause_exit 0
