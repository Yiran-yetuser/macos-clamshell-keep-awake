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

# 以管理员权限运行本目录下的某个脚本（脚本内部自己做 root 操作，输出是脚本的 stdout）
# 注意：桌面目录受 macOS TCC 保护，root 下的 osascript 直接执行桌面上的脚本会报
#      “Operation not permitted”，所以这里先复制到 /tmp 再执行。
# 用法: out=$(run_admin_script "/绝对路径/脚本.sh" "提示文字")  ; rc=$?
run_admin_script() {
  local script="$1" prompt="$2" out rc tmp
  tmp="$(/usr/bin/mktemp /tmp/yz-admin-XXXXXX.sh 2>/dev/null)" || tmp="/tmp/yz-admin-$$.sh"
  /bin/cp "$script" "$tmp" && /bin/chmod 755 "$tmp"
  out="$(/usr/bin/osascript 2>&1 <<APPLESCRIPT
do shell script "/bin/bash '${tmp}'" with administrator privileges with prompt "${prompt}"
APPLESCRIPT
)"
  rc=$?
  /bin/rm -f "$tmp"
  printf '%s' "$out"
  return $rc
}

# 合盖不休眠守护进程是否在运行：输出 running / missing
keepawake_daemon() {
  if /bin/launchctl print system/com.yyz.keepawake >/dev/null 2>&1; then
    printf 'running'
  else
    printf 'missing'
  fi
}

# 读取守护进程记录下来的「开关被别人改回 0」日志（最近 N 行），没有则输出空
keepawake_drift_log() {
  local n="${1:-3}"
  [ -r /var/log/yz-keepawake.log ] && /usr/bin/tail -n "$n" /var/log/yz-keepawake.log 2>/dev/null
}

# ── 合盖画面守护（用户级 LaunchAgent：虚拟屏 + 背光控制）─────────────
# 运行数据放在 ~/Library/Application Support/yz-keepawake（不受桌面 TCC 限制）
support_dir() { printf '%s/Library/Application Support/yz-keepawake' "$HOME"; }

# 合盖画面守护是否在运行：running / missing
lidwatch_status() {
  if /bin/launchctl print "gui/$(/usr/bin/id -u)/com.yyz.lidawake" >/dev/null 2>&1; then
    printf 'running'
  else
    printf 'missing'
  fi
}

# 虚拟屏进程状态：running / stopped
vdisp_running() {
  local p
  p="$(/bin/cat "$(support_dir)/vdisp.pid" 2>/dev/null)"
  if [ -n "$p" ] && /bin/kill -0 "$p" 2>/dev/null; then
    printf 'running'
  else
    printf 'stopped'
  fi
}

# 当前显示亮度（0.000 ~ 1.000），拿不到输出空
display_brightness() { "$(support_dir)/bin/setbright" 2>/dev/null; }

# 合盖画面守护日志最近 N 行
lidwatch_log() {
  local n="${1:-5}"
  /usr/bin/tail -n "$n" "$(support_dir)/logs/合盖画面守护.log" 2>/dev/null
}

# 安装/更新合盖画面守护（用户级，不需要管理员密码）
# 会把 bin/ 下的工具和 .lidwatch.sh 复制到 Application Support，并注册 LaunchAgent
install_lidwatch() {
  local sup plist uid
  sup="$(support_dir)"
  uid="$(/usr/bin/id -u)"
  /bin/mkdir -p "$sup/bin" "$sup/logs" "$HOME/Library/LaunchAgents" || return 1
  /bin/cp -f "$TOOL_DIR/bin/vdisp" "$TOOL_DIR/bin/setbright" "$sup/bin/" || return 1
  /bin/chmod 755 "$sup/bin/vdisp" "$sup/bin/setbright" 2>/dev/null
  /bin/cp -f "$TOOL_DIR/.lidwatch.sh" "$sup/lidwatch.sh" || return 1
  /bin/chmod 755 "$sup/lidwatch.sh" 2>/dev/null
  plist="$HOME/Library/LaunchAgents/com.yyz.lidawake.plist"
  cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.yyz.lidawake</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${sup}/lidwatch.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>${sup}/logs/lidwatch.out</string>
  <key>StandardErrorPath</key>
  <string>${sup}/logs/lidwatch.err</string>
</dict>
</plist>
PLIST
  /bin/launchctl bootout "gui/$uid/com.yyz.lidawake" >/dev/null 2>&1
  /bin/sleep 1   # bootout 是异步的，立刻 bootstrap 会报 "Bootstrap failed: 5"
  if ! /bin/launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null; then
    /bin/sleep 1
    /bin/launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || return 1
  fi
  printf 'ok'
}

# 卸载合盖画面守护：停止 LaunchAgent、清理残留虚拟屏、恢复背光
uninstall_lidwatch() {
  local sup plist uid p saved
  sup="$(support_dir)"
  uid="$(/usr/bin/id -u)"
  plist="$HOME/Library/LaunchAgents/com.yyz.lidawake.plist"
  /bin/launchctl bootout "gui/$uid/com.yyz.lidawake" >/dev/null 2>&1
  /bin/sleep 1   # launchctl bootout 是异步的，等一下再删配置
  /bin/rm -f "$plist"
  p="$(/bin/cat "$sup/vdisp.pid" 2>/dev/null)"
  if [ -n "$p" ] && /bin/kill -0 "$p" 2>/dev/null; then
    /bin/kill -9 "$p" 2>/dev/null
  fi
  /bin/rm -f "$sup/vdisp.pid"
  saved="$(/bin/cat "$sup/brightness.saved" 2>/dev/null)"
  if [ -n "$saved" ]; then
    "$sup/bin/setbright" "$saved" >/dev/null 2>&1
    /bin/rm -f "$sup/brightness.saved"
  fi
  printf 'ok'
}

