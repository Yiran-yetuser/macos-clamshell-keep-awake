#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  合盖画面守护（用户级常驻）
#
#  作用：
#    合上盖子 → ① 把内建屏背光调到 0（屏幕物理上黑掉，省电、不发热）
#               ② 每 15 秒做一次“渲染自检”（截图看是否变纯黑）
#                  只有真的停止渲染（捕获纯黑）才补一块 HiDPI 虚拟显示器，
#                  因为某些远程桌面软件（如网易 UU）会优先抓那块虚拟屏，
#                  多出来的空桌面反而会干扰它。
#    打开盖子 → ① 结束虚拟显示器进程（如果创建过）
#               ② 恢复原来的背光亮度
#
#  为什么要“先关背光、必要时才加虚拟屏”：
#    - 只有 `pmset disablesleep 1` 时，合盖后 macOS 通常仍会渲染，只是屏幕亮着；
#      关背光就能做到“屏幕黑掉但远程有画面”，且不影响任何远程桌面软件。
#    - 但在部分机型/状态下，合盖一段时间后 macOS 会真正停止渲染内建屏，
#      此时任何“抓屏”式远程桌面都只能拿到纯黑画面；
#      多一块在线虚拟显示器可以把系统留在“桌面模式”继续渲染。
#    所以用渲染自检按需触发，避免给 UU 这类软件制造一块空的干扰屏。
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
RENDER_PROBE="$LOG_DIR/渲染自检.png"   # 注意：screencapture 不能写以 . 开头的文件名
BLACK_STREAK_FILE="$SUPPORT_DIR/black.streak"

VD_W=1470          # 虚拟屏逻辑宽度（仅在需要兜底时才用到）
VD_H=956
VD_HIDPI=1         # 1 = Retina 2x 背衬，远程画面清晰
RENDER_MIN_BYTES=300000    # 截图小于这个体积视为“纯黑/无渲染”
CHECK_SECS=15              # 渲染自检间隔
BLACK_TRIGGER=2            # 连续几次纯黑才补虚拟屏（避免瞬时抖动误判）

LAST_BR="$SUPPORT_DIR/brightness.last"   # 最近一次读到的亮度（读失败时兜底用）

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

# 读取内建屏当前逻辑尺寸，让虚拟屏跟它一致（用户改过缩放也能跟上）
read_main_size() {
  local w h rest rc
  rest="$("$BIN_DIR/vdisp" --size 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  w="$(printf '%s' "$rest" | /usr/bin/awk '{print $1}')"
  h="$(printf '%s' "$rest" | /usr/bin/awk '{print $2}')"
  case "$w$h" in
    *[!0-9]*|"") return 1 ;;
  esac
  [ "$w" -ge 800 ] || return 1
  [ "$h" -ge 600 ] || return 1
  # 太大的缩放模式按比例收缩到宽度 1920，避免虚拟屏像素过多拖慢编码
  if [ "$w" -gt 1920 ]; then
    h=$(( h * 1920 / w ))
    w=1920
  fi
  VD_W="$w"
  VD_H="$h"
}

brightness() {
  # 读亮度偶尔会瞬时失败（刚唤醒/显示状态切换），重试几次再放弃
  local i v
  for i in 1 2 3; do
    v="$("$BIN_DIR/setbright" 2>/dev/null)"
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    /bin/sleep 0.2
  done
  return 1
}

# 亮度是否接近 0（返回 0=true）
is_dark() {
  local cur="$1"
  /usr/bin/awk -v c="$cur" 'BEGIN{ exit !(c + 0 <= 0.001) }'
}

# 渲染自检：截一张图，看体积。纯黑画面通常只有 ~100 KB，正常桌面 1 MB 以上。
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
    log "合盖：检测到停止渲染，已补建 HiDPI 虚拟屏（pid=$p，逻辑 ${VD_W}×${VD_H}，物理 $((VD_W*2))×$((VD_H*2))）"
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
  local cur
  cur="$(brightness)"
  if [ -z "$cur" ]; then
    # 读不到原亮度也要把背光关掉（否则合盖后屏幕会一直亮）；开盖时按最近记录/默认值恢复
    if [ ! -f "$SAVED_BR" ]; then
      if [ -s "$LAST_BR" ]; then
        /bin/cp -f "$LAST_BR" "$SAVED_BR" 2>/dev/null
      else
        /bin/echo "0.42" >"$SAVED_BR" 2>/dev/null
      fi
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
  /bin/rm -f "$BLACK_STREAK_FILE" 2>/dev/null
  /bin/echo "exited" >"$STATE_FILE" 2>/dev/null
  log "合盖画面守护退出（已清理虚拟屏与背光）"
}
trap 'cleanup; exit 0' INT TERM HUP

log "合盖画面守护启动（盖子=$(clamshell)，当前亮度=$(brightness)，虚拟屏兜底 ${VD_W}×${VD_H} 逻辑 / $((VD_W*2))×$((VD_H*2)) 物理，渲染自检阈值 ${RENDER_MIN_BYTES} B）"

black_streak=0

while :; do
  rotate_log
  st="$(clamshell)"
  if [ "$st" = "Yes" ]; then
    # ── 合盖：先关背光 ───────────────────────────────────────────
    if [ -f "$SAVED_BR" ]; then
      cur="$(brightness)"
      if [ -n "$cur" ] && ! is_dark "$cur"; then
        "$BIN_DIR/setbright" 0 >/dev/null 2>&1
        log "合盖：背光被调高到 $cur，已重新调回 0"
      fi
    else
      dim_screen
    fi

    # ── 合盖：渲染自检，必要时才补虚拟屏 ─────────────────────────
    if vdisp_alive; then
      :   # 已经补过了，保持
    else
      if render_ok; then
        if [ "${black_streak:-0}" -gt 0 ]; then
          log "合盖：画面恢复渲染，取消补虚拟屏"
        fi
        black_streak=0
        /bin/echo 0 >"$BLACK_STREAK_FILE" 2>/dev/null
      else
        black_streak=$(( ${black_streak:-0} + 1 ))
        /bin/echo "$black_streak" >"$BLACK_STREAK_FILE" 2>/dev/null
        log "合盖：渲染自检未通过（第 $black_streak 次），截图疑似纯黑"
        if [ "$black_streak" -ge "$BLACK_TRIGGER" ]; then
          read_main_size || true
          start_vdisp
          black_streak=0
        fi
      fi
    fi

    /bin/echo "closed" >"$STATE_FILE" 2>/dev/null
    /bin/sleep "$CHECK_SECS"
  else
    # ── 开盖：撤虚拟屏、恢复背光 ─────────────────────────────────
    if vdisp_alive; then stop_vdisp; fi
    if [ -f "$SAVED_BR" ]; then restore_screen; fi
    cur="$(brightness)" && [ -n "$cur" ] && /bin/echo "$cur" >"$LAST_BR" 2>/dev/null
    black_streak=0
    /bin/rm -f "$BLACK_STREAK_FILE" 2>/dev/null
    /bin/echo "open" >"$STATE_FILE" 2>/dev/null
    /bin/sleep 1
  fi
done
