#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  合盖画面守护（用户级常驻）
#
#  作用：
#    合上盖子 → ① 创建一块 HiDPI 虚拟显示器（逻辑 1470×956，物理 2940×1912）
#               ② 把内建屏背光调到 0（屏幕物理上黑掉，省电、不发热）
#               ③ 系统仍在渲染 → 屏幕捕获/远程桌面能看到真实画面
#    打开盖子 → ① 结束虚拟显示器进程（虚拟屏随之消失）
#               ② 恢复原来的背光亮度
#
#  为什么需要它：
#    - 只有 `pmset disablesleep 1` 时，合盖后 macOS 会停止渲染内建屏，
#      任何“抓屏”式远程桌面（RustDesk / ToDesk / VNC）只能拿到纯黑画面；
#    - 多一块在线的虚拟显示器后，系统保持“桌面模式”继续渲染，画面就正常了；
#    - 屏幕不走“显示器休眠”（那会真正停止渲染），只关背光，所以远程仍有画面。
#
#  安装位置：~/Library/Application Support/yz-keepawake/lidwatch.sh
#  由 LaunchAgent com.yyz.lidawake 以当前登录用户身份常驻（必须处于图形会话中）。
#  日志：同目录 logs/合盖画面守护.log
# ─────────────────────────────────────────────────────────────────────

SUPPORT_DIR="$HOME/Library/Application Support/yz-keepawake"
BIN_DIR="$SUPPORT_DIR/bin"
LOG_DIR="$SUPPORT_DIR/logs"
LOG="$LOG_DIR/合盖画面守护.log"
SAVED_BR="$SUPPORT_DIR/brightness.saved"
VDISP_PIDFILE="$SUPPORT_DIR/vdisp.pid"
STATE_FILE="$SUPPORT_DIR/lid.state"

VD_W=1470          # 虚拟屏逻辑宽度（与内建屏缩放一致）
VD_H=956           # 虚拟屏逻辑高度
VD_HIDPI=1         # 1 = Retina 2x 背衬，远程画面清晰

mkdir -p "$BIN_DIR" "$LOG_DIR" 2>/dev/null

log() { printf '%s  %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

rotate_log() {
  local sz
  sz="$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)"
  if [ "${sz:-0}" -gt 524288 ]; then /bin/mv -f "$LOG" "$LOG.1" 2>/dev/null; fi
}

clamshell() {
  /usr/sbin/ioreg -r -n IOPMrootDomain -d 1 2>/dev/null \
    | /usr/bin/awk -F'= ' '/"AppleClamshellState"/{print $2; exit}'
}

brightness() { "$BIN_DIR/setbright" 2>/dev/null; }

# 亮度是否接近 0（返回 0=true）
is_dark() {
  local cur="$1"
  /usr/bin/awk -v c="$cur" 'BEGIN{ exit !(c + 0 <= 0.001) }'
}

vdisp_alive() {
  local p
  p="$(/bin/cat "$VDISP_PIDFILE" 2>/dev/null)"
  [ -n "$p" ] && /bin/kill -0 "$p" 2>/dev/null
}

start_vdisp() {
  if [ ! -x "$BIN_DIR/vdisp" ]; then
    log "错误：找不到可执行文件 $BIN_DIR/vdisp，无法创建虚拟屏"
    return 1
  fi
  "$BIN_DIR/vdisp" "$VD_W" "$VD_H" "$VD_HIDPI" >>"$LOG_DIR/vdisp.out" 2>&1 &
  local p=$!
  /bin/echo "$p" >"$VDISP_PIDFILE" 2>/dev/null
  /bin/sleep 2
  if /bin/kill -0 "$p" 2>/dev/null; then
    log "合盖：已创建 HiDPI 虚拟屏（pid=$p，逻辑 ${VD_W}×${VD_H}，物理 $((VD_W*2))×$((VD_H*2))）"
  else
    log "合盖：虚拟屏创建失败，详见 $LOG_DIR/vdisp.out"
    /bin/rm -f "$VDISP_PIDFILE"
  fi
}

stop_vdisp() {
  local p
  p="$(/bin/cat "$VDISP_PIDFILE" 2>/dev/null)"
  if [ -n "$p" ] && /bin/kill -0 "$p" 2>/dev/null; then
    /bin/kill -9 "$p" 2>/dev/null   # 该工具忽略 SIGTERM，必须 -9
    log "开盖：已移除虚拟屏（pid=$p）"
  fi
  /bin/rm -f "$VDISP_PIDFILE"
}

dim_screen() {
  local cur saved
  cur="$(brightness)"
  [ -n "$cur" ] || return 0
  if [ ! -f "$SAVED_BR" ]; then
    /bin/echo "$cur" >"$SAVED_BR" 2>/dev/null
    saved="$cur"
  fi
  "$BIN_DIR/setbright" 0 >/dev/null 2>&1
  log "合盖：内建屏背光 0（原亮度 $cur，已记录以便开盖恢复）"
}

restore_screen() {
  local v
  [ -f "$SAVED_BR" ] || return 0
  v="$(/bin/cat "$SAVED_BR" 2>/dev/null)"
  if [ -n "$v" ]; then
    "$BIN_DIR/setbright" "$v" >/dev/null 2>&1
    log "开盖：内建屏背光已恢复为 $v"
  fi
  /bin/rm -f "$SAVED_BR"
}

cleanup() {
  stop_vdisp
  restore_screen
  /bin/echo "exited" >"$STATE_FILE" 2>/dev/null
  log "合盖画面守护退出（已清理虚拟屏与背光）"
}
trap 'cleanup; exit 0' INT TERM HUP

log "合盖画面守护启动（盖子=$(clamshell)，当前亮度=$(brightness)，虚拟屏 ${VD_W}×${VD_H}@${VD_HIDPI}x）"

while :; do
  rotate_log
  st="$(clamshell)"
  if [ "$st" = "Yes" ]; then
    # 合盖：确保虚拟屏在、背光为 0
    if ! vdisp_alive; then start_vdisp; fi
    cur="$(brightness)"
    if [ -n "$cur" ] && ! is_dark "$cur"; then
      if [ -f "$SAVED_BR" ]; then
        # 背光被别的程序调高了，静默归零
        "$BIN_DIR/setbright" 0 >/dev/null 2>&1
        log "合盖：背光被调高到 $cur，已重新调回 0"
      else
        dim_screen
      fi
    fi
    /bin/echo "closed" >"$STATE_FILE" 2>/dev/null
    /bin/sleep 1
  else
    # 开盖：撤掉虚拟屏、恢复背光
    if vdisp_alive; then stop_vdisp; fi
    if [ -f "$SAVED_BR" ]; then restore_screen; fi
    /bin/echo "open" >"$STATE_FILE" 2>/dev/null
    /bin/sleep 1
  fi
done
