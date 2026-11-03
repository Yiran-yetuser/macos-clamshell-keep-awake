#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  合盖画面守护（用户级常驻）
#
#  目标：远程桌面（UU / RustDesk / ToDesk）无论本机盖子开还是合，都拿到
#        **16:10** 的高清画面；合盖时本机屏幕不亮。
#
#  做法（高清投屏）：
#    ① 建一块 16:10 的 HiDPI 虚拟屏（默认逻辑 1920×1200 / 物理 3840×2400）
#    ② 把内建屏「镜像到」这块虚拟屏上 —— 虚拟屏成为母屏，整个桌面按 3840×2400
#       渲染，内建屏作为从屏由系统处理
#    ③ 远程端因此永远只看到一块 16:10 的 4K 画面，客户端不需要再做缩放
#
#  开关（hd.conf 第 4 个词）：
#    · 默认 always = 开盖也保持 16:10（远程端比例始终一致）
#    · lidonly    = 只在合盖时启用，开盖恢复内建屏 3:2
#    · off        = 彻底不用高清投屏，合盖只关背光
#    改完运行「5-投屏尺寸.command」即时生效。
#
#  兜底：高清投屏没生效时，合盖只把内建屏背光调 0；每 15 秒截图自检，
#        只有系统真的停止渲染才补建虚拟屏。
#
#  安装位置：~/Library/Application Support/yz-keepawake/lidwatch.sh
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
RENDER_PROBE="$LOG_DIR/渲染自检.png"   # screencapture 不能写以 . 开头的文件名

# ── 高清投屏默认值（可被 hd.conf 覆盖）──────────────────────────────
HD_ENABLED=1
HD_W=1920
HD_H=1200
HD_HIDPI=1        # 1 = Retina 2x（物理 3840×2400）
ALWAYS_HD=1       # 1 = 开盖也保持 16:10；0 = 只在合盖时启用
CHECK_SECS=15     # 兜底模式下的渲染自检间隔
RENDER_MIN_BYTES=300000
BLACK_TRIGGER=2
HD_RETRY_SECS=12  # 虚拟屏创建失败后的重试间隔

mkdir -p "$BIN_DIR" "$LOG_DIR" 2>/dev/null

log() { printf '%s  %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

load_hd_conf() {
  [ -f "$HD_CONF" ] || return 0
  local line w h d mode
  line="$(/usr/bin/grep -v '^[[:space:]]*#' "$HD_CONF" 2>/dev/null | /usr/bin/grep -v '^[[:space:]]*$' | /usr/bin/head -1)"
  [ -n "${line:-}" ] || return 0
  case "$line" in
    off|OFF|Off|关闭) HD_ENABLED=0; return 0 ;;
  esac
  w="$(printf '%s' "$line" | /usr/bin/awk '{print $1}')"
  h="$(printf '%s' "$line" | /usr/bin/awk '{print $2}')"
  d="$(printf '%s' "$line" | /usr/bin/awk '{print $3}')"
  mode="$(printf '%s' "$line" | /usr/bin/awk '{print $4}')"
  case "$w$h" in *[!0-9]*|"") return 0 ;; esac
  [ "$w" -ge 800 ] && [ "$h" -ge 600 ] || return 0
  HD_W="$w"; HD_H="$h"
  [ -n "${d:-}" ] && { [ "$d" = "0" ] && HD_HIDPI=0 || HD_HIDPI=1; }
  case "${mode:-}" in
    lidonly|lid|合盖) ALWAYS_HD=0 ;;
    *) ALWAYS_HD=1 ;;
  esac
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
      if [ -s "$LAST_BR" ] && ! is_dark "$(/bin/cat "$LAST_BR")"; then /bin/cp -f "$LAST_BR" "$SAVED_BR" 2>/dev/null
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
  local v i now
  [ -f "$SAVED_BR" ] || return 0
  v="$(/bin/cat "$SAVED_BR" 2>/dev/null)"
  for i in 1 2 3 4; do
    "$BIN_DIR/setbright" "$v" >/dev/null 2>&1
    /bin/sleep 0.3
    now="$(brightness)"
    [ -n "$now" ] && ! is_dark "$now" && break
  done
  log "开盖：内建屏背光已恢复为 ${v}"
  /bin/rm -f "$SAVED_BR"
}

# ── 高清投屏：建 16:10 HiDPI 虚拟屏 + 内建屏镜像过去 ────────────────
stop_hd() {
  local p
  if [ -f "$HD_ACTIVE" ]; then
    "$BIN_DIR/mirror" off >>"$LOG" 2>&1
    /bin/sleep 0.5
    log "已解除内建屏镜像"
    /bin/rm -f "$HD_ACTIVE"
  fi
  p="$(/bin/cat "$VDISP_PIDFILE" 2>/dev/null)"
  if [ -n "$p" ] && /bin/kill -0 "$p" 2>/dev/null; then
    /bin/kill -9 "$p" 2>/dev/null   # vdisp 忽略 SIGTERM，必须 -9
    log "已移除虚拟屏（pid=$p）"
  fi
  /bin/rm -f "$VDISP_PIDFILE" "$VDISP_IDFILE"
}

start_hd() {
  [ -x "$BIN_DIR/vdisp" ] && [ -x "$BIN_DIR/mirror" ] || { log "错误：缺少 vdisp/mirror，无法进入高清投屏"; return 1; }
  : >"$LOG_DIR/vdisp.out"
  "$BIN_DIR/vdisp" "$HD_W" "$HD_H" "$HD_HIDPI" >>"$LOG_DIR/vdisp.out" 2>&1 &
  local p=$!
  /bin/echo "$p" >"$VDISP_PIDFILE" 2>/dev/null
  /bin/sleep 3
  if ! /bin/kill -0 "$p" 2>/dev/null; then
    log "虚拟屏创建失败，详见 $LOG_DIR/vdisp.out"
    /bin/rm -f "$VDISP_PIDFILE"
    return 1
  fi
  local vid
  vid="$(/usr/bin/grep -o 'display=[0-9]*' "$LOG_DIR/vdisp.out" 2>/dev/null | /usr/bin/tail -1 | /usr/bin/cut -d= -f2)"
  if [ -z "${vid:-}" ]; then
    log "拿不到虚拟屏 id，放弃本次高清投屏"
    /bin/kill -9 "$p" 2>/dev/null; /bin/rm -f "$VDISP_PIDFILE"
    return 1
  fi
  /bin/echo "$vid" >"$VDISP_IDFILE" 2>/dev/null
  if "$BIN_DIR/mirror" "$vid" >>"$LOG" 2>&1; then
    /bin/sleep 1
    /bin/echo "$vid" >"$HD_ACTIVE" 2>/dev/null
    log "高清投屏已生效（${HD_W}×${HD_H} 逻辑 / $((HD_W*2))×$((HD_H*2)) 物理，始终启用=${ALWAYS_HD}）"
    return 0
  fi
  log "镜像失败，放弃本次高清投屏（详见日志）"
  "$BIN_DIR/mirror" off >/dev/null 2>&1
  /bin/kill -9 "$p" 2>/dev/null
  /bin/rm -f "$VDISP_PIDFILE" "$VDISP_IDFILE"
  return 1
}

last_hd_try=0
ensure_hd() {
  [ "$HD_ENABLED" = "1" ] || return 1
  if [ -f "$HD_ACTIVE" ]; then
    if vdisp_alive; then return 0; fi
    log "虚拟屏进程消失了，清理残留镜像后重建"
    "$BIN_DIR/mirror" off >/dev/null 2>&1
    /bin/rm -f "$HD_ACTIVE" "$VDISP_IDFILE" "$VDISP_PIDFILE"
  fi
  local now
  now="$(/bin/date +%s)"
  if [ $(( now - last_hd_try )) -lt "$HD_RETRY_SECS" ]; then return 1; fi
  last_hd_try=$now
  start_hd
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

# ── 远程会话检测：UU 出站流量 + 显示抓取状态双信号 ─────────────────
uu_pid() { /usr/bin/pgrep -f "UURemoteServer" 2>/dev/null | /usr/bin/head -1; }

uu_bytes_out() {
  local p
  p="$(uu_pid)"
  [ -n "$p" ] || { /bin/echo "-1"; return; }
  /usr/bin/nettop -P -x -l 1 -p "$p" 2>/dev/null \
    | /usr/bin/awk 'NR>1 && $2 ~ /^UURemote/ {v=$4} END {if (v=="") v="-1"; print v}'
}

remote_viewing() {
  local p b1 b2 d cap
  p="$(uu_pid)"
  [ -n "$p" ] || return 1
  b1="$(uu_bytes_out)"
  [ "${b1:--1}" = "-1" ] && return 1
  /bin/sleep 1
  b2="$(uu_bytes_out)"
  [ "${b2:--1}" = "-1" ] && return 1
  d=$(( b2 - b1 ))
  [ "$d" -ge "${REMOTE_MIN_BYTES:-120000}" ] && return 0
  if [ -x "$BIN_DIR/capprobe" ]; then
    cap="$("$BIN_DIR/capprobe" 2>/dev/null | /usr/bin/awk '/captured=1/{n++} END{print n+0}')"
    [ "${cap:-0}" -gt 0 ] && return 0
  fi
  return 1
}

local_active() {
  local ns
  ns="$(/usr/sbin/ioreg -c IOHIDSystem 2>/dev/null | /usr/bin/awk '/HIDIdleTime/ {print $NF; exit}')"
  [ -n "$ns" ] || return 1
  [ "$ns" -lt "${LOCAL_ACTIVE_NS:-3000000000}" ] 2>/dev/null && return 0
  return 1
}

load_hd_conf
cleanup_stale
if [ "$HD_ENABLED" = "1" ]; then
  log "合盖画面守护启动（盖子=$(clamshell)，亮度=$(brightness)，高清投屏 ${HD_W}×${HD_H}（物理 $((HD_W*2))×$((HD_H*2))），始终启用=$ALWAYS_HD，远程自动开关=1）"
else
  log "合盖画面守护启动（盖子=$(clamshell)，亮度=$(brightness)，高清投屏已关闭，只关背光）"
fi

black_streak=0

while :; do
  rotate_log
  st="$(clamshell)"

  if [ "$st" = "Yes" ]; then
    # ── 合盖：优先高清投屏（面板由镜像关系关掉），否则背光归零 ──
    if [ "$HD_ENABLED" = "1" ]; then
      ensure_hd || true
    fi
    if [ -f "$HD_ACTIVE" ]; then
      :   # 高清投屏已接管：面板由系统关掉，无需再动背光
    else
      if [ -f "$SAVED_BR" ]; then
        cur="$(brightness)"
        if [ -n "$cur" ] && ! is_dark "$cur"; then
          "$BIN_DIR/setbright" 0 >/dev/null 2>&1
          log "合盖：背光被调高到 $cur，已重新调回 0"
        fi
      else
        dim_screen
      fi
      if vdisp_alive; then :; elif render_ok; then
        black_streak=0
      else
        black_streak=$(( ${black_streak:-0} + 1 ))
        log "合盖：渲染自检未通过（第 $black_streak 次）"
        if [ "$black_streak" -ge "$BLACK_TRIGGER" ]; then
          start_hd || true
          black_streak=0
        fi
      fi
    fi
    /bin/echo "closed" >"$STATE_FILE" 2>/dev/null
    /bin/sleep "$CHECK_SECS"
  else
    # ── 开盖：默认保持 16:10（远程端比例一致）；lidonly 模式则复原 ──
    if [ "$HD_ENABLED" = "1" ] && [ "$ALWAYS_HD" = "1" ]; then
      # 开盖时：本机有人操作 > 远程正在看 > 都没有就恢复本机屏幕
      if local_active; then
        want=0; why="本机有人操作"
      elif remote_viewing; then
        want=1; why="远程正在观看"
      else
        want=0; why="没有远程会话"
      fi
      prev_want="${last_hd_want:-}"
      if [ "$want" = "1" ]; then
        hd_off_streak=0
        if [ "$prev_want" != "1" ]; then
          log "开盖：$why，启用高清投屏"
          last_hd_want=1
        fi
        ensure_hd || true
      else
        hd_off_streak=$(( ${hd_off_streak:-0} + 1 ))
        if [ "$hd_off_streak" -ge "${HD_OFF_TRIGGER:-2}" ] && { [ -f "$HD_ACTIVE" ] || vdisp_alive; }; then
          log "开盖：$why，恢复本机屏幕（关闭高清投屏）"
          last_hd_want=0
          stop_hd
          if [ -f "$SAVED_BR" ]; then restore_screen; else
            b="$(brightness)"
            if [ -z "$b" ] && [ -s "$LAST_BR" ]; then
              "$BIN_DIR/setbright" "$(/bin/cat "$LAST_BR")" >/dev/null 2>&1
            fi
          fi
          hd_off_streak=0
        elif [ "$want" = "0" ] && [ ! -f "$HD_ACTIVE" ]; then
          if [ "${last_hd_want:-}" != "0" ]; then
            log "开盖：$why（虚拟屏已关闭，本机屏幕正常）"
            last_hd_want=0
          fi
          hd_off_streak=0
        fi
      fi
    else
      if [ -f "$HD_ACTIVE" ] || vdisp_alive; then stop_hd; fi
      [ -f "$SAVED_BR" ] && restore_screen
    fi
    cur="$(brightness)" && [ -n "$cur" ] && ! is_dark "$cur" && /bin/echo "$cur" >"$LAST_BR" 2>/dev/null
    black_streak=0
    /bin/echo "open" >"$STATE_FILE" 2>/dev/null
    /bin/sleep 3
  fi
done
