#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  合盖画面守护（用户级常驻）
#
#  合盖时做两件事，目标是「屏幕物理上不亮，但远程桌面拿到又大又清晰的画面」：
#
#    ① 高清投屏（默认开启，可调尺寸）
#       建一块 HiDPI 虚拟屏（默认逻辑 2560×1600 / 物理 5120×3200），再把内建屏
#       「镜像到」这块虚拟屏上 —— 虚拟屏成为母屏，整个桌面按 5120×3200 渲染，
#       内建屏作为从屏由系统关掉（active=0，物理上不亮）。
#       这样远程拿到的就是精确 16:10 的高清画面，不会因为内建屏 3:2 的宽高比
#       被塞进 16:10/16:9 的客户端窗口而缩放发软。
#       尺寸可在 ~/Library/Application Support/yz-keepawake/hd.conf 里改，
#       或运行「5-投屏尺寸.command」选择：2560×1600 / 1920×1200（4K+界面放大）/
#       1920×1080（4K+16:9）/ 关闭。
#
#    ② 兜底（高清投屏关闭或失败时）
#       只把内建屏背光调到 0；每 15 秒截图自检，只有系统真的停止渲染才补虚拟屏。
#
#  打开盖子：解除镜像 → 移除虚拟屏 → 恢复背光，一切复原。
#
#  安装位置：~/Library/Application Support/yz-keepawake/lidwatch.sh
#  由 LaunchAgent com.yyz.lidawake 以当前登录用户身份常驻（必须在图形会话中）。
#  日志：同目录 logs/合盖画面守护.log
# ─────────────────────────────────────────────────────────────────────

SUPPORT_DIR="$HOME/Library/Application Support/yz-keepawake"
BIN_DIR="$SUPPORT_DIR/bin"
LOG_DIR="$SUPPORT_DIR/logs"
LOG="$LOG_DIR/合盖画面守护.log"
SAVED_BR="$SUPPORT_DIR/brightness.saved"
VDISP_PIDFILE="$SUPPORT_DIR/vdisp.pid"
VDISP_IDFILE="$SUPPORT_DIR/vdisp.id"
HD_ACTIVE="$SUPPORT_DIR/hd.active"
HD_CONF="$SUPPORT_DIR/hd.conf"
STATE_FILE="$SUPPORT_DIR/lid.state"
LAST_BR="$SUPPORT_DIR/brightness.last"
RENDER_PROBE="$LOG_DIR/渲染自检.png"   # 注意：screencapture 不能写以 . 开头的文件名

# ── 高清投屏尺寸（可被 hd.conf 覆盖）────────────────────────────────
HD_ENABLED=1
HD_W=2560
HD_H=1600
HD_HIDPI=1        # 1 = Retina 2x（物理 5120×3200）
CHECK_SECS=15     # 无高清模式时的渲染自检间隔
RENDER_MIN_BYTES=300000
BLACK_TRIGGER=2

mkdir -p "$BIN_DIR" "$LOG_DIR" 2>/dev/null

log() { printf '%s  %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

load_hd_conf() {
  [ -f "$HD_CONF" ] || return 0
  local line w h d
  line="$(/usr/bin/grep -v '^[[:space:]]*#' "$HD_CONF" 2>/dev/null | /usr/bin/grep -v '^[[:space:]]*$' | /usr/bin/head -1)"
  [ -n "${line:-}" ] || return 0
  case "$line" in
    off|OFF|Off|关闭) HD_ENABLED=0; return 0 ;;
  esac
  w="$(printf '%s' "$line" | /usr/bin/awk '{print $1}')"
  h="$(printf '%s' "$line" | /usr/bin/awk '{print $2}')"
  d="$(printf '%s' "$line" | /usr/bin/awk '{print $3}')"
  case "$w$h" in *[!0-9]*|"") return 0 ;; esac
  [ "$w" -ge 800 ] && [ "$h" -ge 600 ] || return 0
  HD_W="$w"; HD_H="$h"
  [ -n "${d:-}" ] && { [ "$d" = "0" ] && HD_HIDPI=0 || HD_HIDPI=1; }
  HD_ENABLED=1
}

rotate_log() {
  local sz
  sz="$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)"
  if [ "${sz:-0}" -gt 524288 ]; then /bin/mv -f "$LOG" "$LOG.1" 2>/dev/null; fi
}

clamshell() {
  /usr/sbin/ioreg -r -n IOPMrootDomain -d 1 2>/dev/null \
    | /usr/bin/awk -F'= ' '/"AppleClamshellState"/{print $2; exit}'
}

brightness() {
  local i v
  for i in 1 2 3; do
    v="$("$BIN_DIR/setbright" 2>/dev/null)"
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    /bin/sleep 0.2
  done
  return 1
}

is_dark() { /usr/bin/awk -v c="$1" 'BEGIN{ exit !(c + 0 <= 0.001) }'; }

render_ok() {
  /bin/rm -f "$RENDER_PROBE" 2>/dev/null
  /usr/sbin/screencapture -x "$RENDER_PROBE" >/dev/null 2>&1 || return 1
  local sz
  sz="$(/usr/bin/stat -f%z "$RENDER_PROBE" 2>/dev/null || echo 0)"
  /bin/rm -f "$RENDER_PROBE" 2>/dev/null
  [ "${sz:-0}" -ge "$RENDER_MIN_BYTES" ]
}

vdisp_alive() {
  local p
  p="$(/bin/cat "$VDISP_PIDFILE" 2>/dev/null)"
  [ -n "$p" ] && /bin/kill -0 "$p" 2>/dev/null
}

dim_screen() {
  local cur
  cur="$(brightness)"
  if [ -z "$cur" ]; then
    if [ ! -f "$SAVED_BR" ]; then
      if [ -s "$LAST_BR" ]; then /bin/cp -f "$LAST_BR" "$SAVED_BR" 2>/dev/null
      else /bin/echo "0.42" >"$SAVED_BR" 2>/dev/null; fi
    fi
    "$BIN_DIR/setbright" 0 >/dev/null 2>&1
    log "合盖：读取原亮度失败，背光仍已归零（开盖按备用值恢复）"
    return 0
  fi
  [ -f "$SAVED_BR" ] || /bin/echo "$cur" >"$SAVED_BR" 2>/dev/null
  "$BIN_DIR/setbright" 0 >/dev/null 2>&1
  log "合盖：内建屏背光 0（原亮度 $cur，已记录以便开盖恢复）"
}

restore_screen() {
  local v i
  [ -f "$SAVED_BR" ] || return 0
  v="$(/bin/cat "$SAVED_BR" 2>/dev/null)"
  for i in 1 2 3 4; do
    "$BIN_DIR/setbright" "$v" >/dev/null 2>&1
    /bin/sleep 0.3
    local now; now="$(brightness)"
    [ -n "$now" ] && ! is_dark "$now" && break
  done
  log "开盖：内建屏背光已恢复为 ${v}"
  /bin/rm -f "$SAVED_BR"
}

# ── 高清投屏：建 HiDPI 虚拟屏 + 内建屏镜像过去 ─────────────────────
start_hd() {
  [ "$HD_ENABLED" = "1" ] || return 1
  [ -x "$BIN_DIR/vdisp" ] && [ -x "$BIN_DIR/mirror" ] || { log "错误：缺少 vdisp/mirror，无法进入高清投屏"; return 1; }
  : >"$LOG_DIR/vdisp.out"
  "$BIN_DIR/vdisp" "$HD_W" "$HD_H" "$HD_HIDPI" >>"$LOG_DIR/vdisp.out" 2>&1 &
  local p=$!
  /bin/echo "$p" >"$VDISP_PIDFILE" 2>/dev/null
  /bin/sleep 3
  if ! /bin/kill -0 "$p" 2>/dev/null; then
    log "合盖：虚拟屏创建失败，详见 $LOG_DIR/vdisp.out"
    /bin/rm -f "$VDISP_PIDFILE"
    return 1
  fi
  local vid
  vid="$(/usr/bin/grep -o 'display=[0-9]*' "$LOG_DIR/vdisp.out" 2>/dev/null | /usr/bin/tail -1 | /usr/bin/cut -d= -f2)"
  if [ -z "${vid:-}" ]; then
    log "合盖：拿不到虚拟屏 id，回退为只关背光"
    /bin/kill -9 "$p" 2>/dev/null; /bin/rm -f "$VDISP_PIDFILE"
    return 1
  fi
  /bin/echo "$vid" >"$VDISP_IDFILE" 2>/dev/null
  if "$BIN_DIR/mirror" "$vid" >>"$LOG" 2>&1; then
    /bin/sleep 1
    /bin/echo "$vid" >"$HD_ACTIVE" 2>/dev/null
    log "合盖：高清投屏已生效（虚拟屏 $((HD_W))×${HD_H} 逻辑 / $((HD_W*2))×$((HD_H*2)) 物理，内建屏已镜像过去，物理屏由系统关闭）"
    return 0
  fi
  log "合盖：镜像失败，回退为只关背光（详见日志）"
  "$BIN_DIR/mirror" off >/dev/null 2>&1
  /bin/kill -9 "$p" 2>/dev/null
  /bin/rm -f "$VDISP_PIDFILE" "$VDISP_IDFILE"
  return 1
}

stop_hd() {
  local p
  if [ -f "$HD_ACTIVE" ]; then
    "$BIN_DIR/mirror" off >>"$LOG" 2>&1
    /bin/sleep 0.5
    log "开盖：已解除内建屏镜像"
    /bin/rm -f "$HD_ACTIVE"
  fi
  p="$(/bin/cat "$VDISP_PIDFILE" 2>/dev/null)"
  if [ -n "$p" ] && /bin/kill -0 "$p" 2>/dev/null; then
    /bin/kill -9 "$p" 2>/dev/null   # vdisp 忽略 SIGTERM，必须 -9
    log "开盖：已移除虚拟屏（pid=$p）"
  fi
  /bin/rm -f "$VDISP_PIDFILE" "$VDISP_IDFILE"
}

cleanup() {
  stop_hd
  restore_screen
  /bin/echo "exited" >"$STATE_FILE" 2>/dev/null
  log "合盖画面守护退出（已清理虚拟屏/镜像与背光）"
}
trap 'cleanup; exit 0' INT TERM HUP

cleanup_stale() {
  local p
  if [ -f "$HD_ACTIVE" ]; then
    "$BIN_DIR/mirror" off >/dev/null 2>&1
    /bin/rm -f "$HD_ACTIVE"
    log "启动：清理了上次残留的镜像关系"
  fi
  p="$(/bin/cat "$VDISP_PIDFILE" 2>/dev/null)"
  if [ -n "$p" ] && /bin/kill -0 "$p" 2>/dev/null; then
    /bin/kill -9 "$p" 2>/dev/null
    log "启动：清理了上次残留的虚拟屏（pid=$p）"
  fi
  /bin/rm -f "$VDISP_PIDFILE" "$VDISP_IDFILE"
}

load_hd_conf
cleanup_stale
if [ "$HD_ENABLED" = "1" ]; then
  log "合盖画面守护启动（盖子=$(clamshell)，当前亮度=$(brightness)，高清投屏 ${HD_W}×${HD_H} 逻辑 / $((HD_W*2))×$((HD_H*2)) 物理）"
else
  log "合盖画面守护启动（盖子=$(clamshell)，当前亮度=$(brightness)，高清投屏已关闭，只关背光）"
fi

black_streak=0

while :; do
  rotate_log
  st="$(clamshell)"
  if [ "$st" = "Yes" ]; then
    # 先关背光（记录原始亮度）
    if [ -f "$SAVED_BR" ]; then
      cur="$(brightness)"
      if [ -n "$cur" ] && ! is_dark "$cur"; then
        "$BIN_DIR/setbright" 0 >/dev/null 2>&1
        log "合盖：背光被调高到 $cur，已重新调回 0"
      fi
    else
      dim_screen
    fi

    # 高清投屏（虚拟屏 + 内建屏镜像）
    if [ "$HD_ENABLED" = "1" ]; then
      if [ -f "$HD_ACTIVE" ]; then
        if ! vdisp_alive; then
          log "合盖：虚拟屏进程消失了，清理残留镜像"
          "$BIN_DIR/mirror" off >/dev/null 2>&1
          /bin/rm -f "$HD_ACTIVE" "$VDISP_IDFILE"
        fi
      else
        start_hd || black_streak=0
      fi
    fi

    # 兜底：高清投屏没生效时才做渲染自检
    if [ ! -f "$HD_ACTIVE" ]; then
      if vdisp_alive; then
        :   # 之前的兜底虚拟屏还在
      elif render_ok; then
        black_streak=0
      else
        black_streak=$(( ${black_streak:-0} + 1 ))
        log "合盖：渲染自检未通过（第 $black_streak 次），截图疑似纯黑"
        if [ "$black_streak" -ge "$BLACK_TRIGGER" ]; then
          start_hd || true
          black_streak=0
        fi
      fi
    fi

    /bin/echo "closed" >"$STATE_FILE" 2>/dev/null
    /bin/sleep "$CHECK_SECS"
  else
    if [ -f "$HD_ACTIVE" ] || vdisp_alive; then stop_hd; fi
    [ -f "$SAVED_BR" ] && restore_screen
    cur="$(brightness)" && [ -n "$cur" ] && /bin/echo "$cur" >"$LAST_BR" 2>/dev/null
    black_streak=0
    /bin/echo "open" >"$STATE_FILE" 2>/dev/null
    /bin/sleep 1
  fi
done
