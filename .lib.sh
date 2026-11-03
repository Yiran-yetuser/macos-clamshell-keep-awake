#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  防合盖休眠 · 公共函数库
#  被 1/2/3/4 号脚本引用，请勿单独双击运行（文件名以 . 开头，Finder 默认隐藏）
# ─────────────────────────────────────────────────────────────────────

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$TOOL_DIR/logs"
LOG_FILE="$LOG_DIR/操作记录.log"
mkdir -p "$LOG_DIR" 2>/dev/null

# 颜色（输出被重定向时自动降级为纯文本）
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
  NC=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

# ── 输出/日志 ────────────────────────────────────────────────────────
log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

title() {
  printf '\n%s%s%s\n' "$BOLD" "$*" "$NC"
}

hr() {
  printf '%s\n' "────────────────────────────────────────────────────────────"
}

ok()   { printf '%s✅ %s%s\n' "$GREEN" "$*" "$NC"; }
warn() { printf '%s⚠️  %s%s\n' "$YELLOW" "$*" "$NC"; }
bad()  { printf '%s❌ %s%s\n' "$RED" "$*" "$NC"; }
info() { printf '%s   %s%s\n' "$DIM" "$*" "$NC"; }

# 双击 .command 运行时，结束时暂停一下，方便看清结果
pause_exit() {
  if [ -t 0 ]; then
    printf '\n%s按回车键关闭窗口…%s' "$DIM" "$NC"
    read -r _
  fi
}

# ── 系统状态探测 ─────────────────────────────────────────────────────
# 合盖休眠是否已禁用：输出 1（已禁用）/ 0（未禁用）/ 空（读取失败）
sleep_disabled() {
  /usr/bin/pmset -g 2>/dev/null | awk '/SleepDisabled[ \t]/{print $2; exit}'
}

# 内核中的实时值：Yes / No
sleep_disabled_kernel() {
  /usr/sbin/ioreg -r -n IOPMrootDomain -d 1 2>/dev/null \
    | awk -F'= ' '/"SleepDisabled"/{print $2; exit}'
}

# 合盖状态：Yes（已合上）/ No（已打开）
clamshell_closed() {
  /usr/sbin/ioreg -r -n IOPMrootDomain -d 1 2>/dev/null \
    | awk -F'= ' '/"AppleClamshellState"/{print $2; exit}'
}

# AC / Battery
power_source() {
  /usr/bin/pmset -g batt 2>/dev/null | awk -F"'" 'NR==1{print $2}'
}

# 电量百分比，如 59%
battery_percent() {
  /usr/bin/pmset -g batt 2>/dev/null | sed -n '2p' | grep -o '[0-9]\+%' | head -1
}

# 电量详情（人类可读）："65% · 充电中 · 预计 2:09 后充满"
battery_text() {
  local raw pct st remain
  raw="$(/usr/bin/pmset -g batt 2>/dev/null | sed -n '2p')"
  [ -n "$raw" ] || return 0
  pct="$(printf '%s' "$raw" | grep -o '[0-9]\+%' | head -1)"
  case "$raw" in
    *"finishing charge"*) st="即将充满" ;;
    *"not charging"*)     st="已接电源未充电" ;;
    *discharging*)        st="放电中" ;;
    *charging*)           st="充电中" ;;
    *charged*)            st="已充满" ;;
    *)                    st="" ;;
  esac
  remain="$(printf '%s' "$raw" | grep -o '[0-9]\+:[0-9]\+ remaining' | head -1 | awk '{print $1}')"
  [ -n "$pct" ] && printf '%s' "$pct"
  [ -n "$st" ] && printf ' · %s' "$st"
  if [ -n "$remain" ]; then
    case "$st" in
      *放电*) printf ' · 剩余 %s' "$remain" ;;
      *)      printf ' · 预计 %s 后充满' "$remain" ;;
    esac
  fi
}

# Tailscale 后台状态：Running / Stopped / NoState / 空（未安装）
tailscale_backend() {
  tailscale status --json 2>/dev/null \
    | grep -m1 -o '"BackendState": "[^"]*"' | cut -d'"' -f4
}

# Tailscale 本机是否在线：true / false / 空
tailscale_self_online() {
  tailscale status --json 2>/dev/null | awk '
    /"Self": \{/      { in_self=1 }
    in_self && /"Online":/ { gsub(/[",]/, ""); print $2; exit }'
}

# Tailscale 本机 IP（IPv4），如 100.91.137.116
tailscale_ip() {
  tailscale ip -4 2>/dev/null | head -1
}

# 本机 Wi-Fi 名称（拿不到时输出空）
wifi_ssid() {
  local dev ssid
  dev="$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null \
    | awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')"
  [ -n "$dev" ] || return 0
  ssid="$(/usr/sbin/networksetup -getairportnetwork "$dev" 2>/dev/null \
    | sed -n 's/^Current Wi-Fi Network: //p')"
  [ -n "$ssid" ] || ssid="$(/usr/sbin/ipconfig getsummary "$dev" 2>/dev/null \
    | awk -F' : ' '/SSID/{print $2; exit}')"
  printf '%s' "$ssid"
}

# 默认路由的网关与接口
default_gateway() {
  /sbin/route -n get default 2>/dev/null | awk '/gateway:/{print $2}'
}

# 公网连通性探测：OK / FAIL（本机网络封禁 ICMP，所以用 TCP 探测 DNS 服务器）
net_ok() {
  if /usr/bin/nc -z -G 1 -w 2 223.5.5.5 53 2>/dev/null \
     || /usr/bin/nc -z -G 1 -w 2 1.1.1.1 53 2>/dev/null; then
    printf 'OK'
  else
    printf 'FAIL'
  fi
}

# 系统自带屏幕共享（VNC 5900 端口）是否在监听
screensharing_listening() {
  if /usr/bin/nc -z -G 1 -w 1 127.0.0.1 5900 2>/dev/null; then
    printf '1'
  else
    printf '0'
  fi
}

# ── 管理员权限执行 pmset ─────────────────────────────────────────────
# 用法: out=$(run_pmset_admin "disablesleep 1" "提示文字")  ; rc=$?
# rc=0 成功；rc≠0 失败/取消（输出里含 -128 表示用户点了「取消」）
run_pmset_admin() {
  local args="$1" prompt="$2" out rc
  out="$(/usr/bin/osascript 2>&1 <<APPLESCRIPT
do shell script "/usr/bin/pmset -a ${args}" with administrator privileges with prompt "${prompt}"
APPLESCRIPT
)"
  rc=$?
  printf '%s' "$out"
  return $rc
}
