#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  ③ 查看状态
#  随时体检：设置有没有生效、网络通不通、远程桌面在不在、最近的睡眠记录
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=.lib.sh
source "$HERE/.lib.sh"

# 读取某个模式下某个电源计划项的值（$1 模式，$2 键名）
plan_val() {
  /usr/bin/pmset -g custom 2>/dev/null | awk -v sec="$1" -v k="$2" '
    $0 ~ ("^" sec ": *$")        { inb = 1; next }
    /^[A-Za-z][A-Za-z ]*: *$/    { inb = 0 }
    inb && $1 == k               { print $NF; exit }'
}

fmt_min() {   # 0 → 永不，空 → 默认，其它 → N 分钟
  local v="$1"
  if [ -z "$v" ]; then printf '默认'
  elif [ "$v" = "0" ]; then printf '永不'
  else printf '%s 分钟' "$v"; fi
}

fmt_onoff() {
  [ "${1:-0}" = "1" ] && printf '开' || printf '关'
}

title "③ 防合盖休眠 · 状态检查"
hr

# ── 1. 机器与系统 ────────────────────────────────────────────────────
printf '机器：%s · %s · macOS %s\n' \
  "$(sysctl -n hw.model 2>/dev/null)" \
  "$(sysctl -n machdep.cpu.brand_string 2>/dev/null)" \
  "$(sw_vers -productVersion 2>/dev/null)"

# ── 2. 电源 ─────────────────────────────────────────────────────────
src="$(power_source)"
case "$src" in
  AC*)      src_cn="交流电源（已插电）" ;;
  Battery*) src_cn="电池（未插电，合盖会持续耗电）" ;;
  *)        src_cn="${src:-未知}" ;;
esac
btext="$(battery_text)"
printf '电源：%s' "$src_cn"
[ -n "$btext" ] && printf ' · %s' "$btext"
printf '\n'

# ── 3. 合盖不休眠 设置状态 ───────────────────────────────────────────
sd="$(sleep_disabled)"
sd_kern="$(sleep_disabled_kernel)"
printf '合盖不休眠：'
if [ "$sd" = "1" ] && [ "$sd_kern" = "Yes" ]; then
  printf '%s✅ 已开启%s（pmset=%s · 内核=%s）\n' "$GREEN" "$NC" "$sd" "$sd_kern"
elif [ "$sd" = "1" ]; then
  printf '%s⚠️  已写入但内核未生效%s（pmset=%s · 内核=%s），建议重启后再看\n' \
    "$YELLOW" "$NC" "$sd" "${sd_kern:-No}"
else
  printf '%s❌ 未开启%s（pmset=%s · 内核=%s）→ 请运行「1-开启防合盖休眠.command」\n' \
    "$RED" "$NC" "${sd:-空}" "${sd_kern:-No}"
fi

# ── 4. 当前盖子 ─────────────────────────────────────────────────────
lid="$(clamshell_closed)"
if [ "$lid" = "Yes" ]; then
  printf '当前盖子：%s已合上%s\n' "$YELLOW" "$NC"
else
  printf '当前盖子：打开\n'
fi

# ── 5. 电源计划 ─────────────────────────────────────────────────────
printf '\n%s电源计划%s\n' "$BOLD" "$NC"
printf '  交流电源：系统休眠 %s · 显示器休眠 %s · 硬盘休眠 %s · 网络唤醒 %s · 电源小憩 %s\n' \
  "$(fmt_min "$(plan_val 'AC Power' sleep)")" \
  "$(fmt_min "$(plan_val 'AC Power' displaysleep)")" \
  "$(fmt_min "$(plan_val 'AC Power' disksleep)")" \
  "$(fmt_onoff "$(plan_val 'AC Power' womp)")" \
  "$(fmt_onoff "$(plan_val 'AC Power' powernap)")"
printf '  电池：    系统休眠 %s · 显示器休眠 %s · 硬盘休眠 %s · 网络唤醒 %s · 电源小憩 %s · 低电量模式 %s\n' \
  "$(fmt_min "$(plan_val 'Battery Power' sleep)")" \
  "$(fmt_min "$(plan_val 'Battery Power' displaysleep)")" \
  "$(fmt_min "$(plan_val 'Battery Power' disksleep)")" \
  "$(fmt_onoff "$(plan_val 'Battery Power' womp)")" \
  "$(fmt_onoff "$(plan_val 'Battery Power' powernap)")" \
  "$(fmt_onoff "$(plan_val 'Battery Power' lowpowermode)")"
info "开启「合盖不休眠」后，上面的「系统休眠」计时会被系统忽略（disablesleep 优先）。"

# ── 6. 网络与 Tailscale ─────────────────────────────────────────────
printf '\n%s网络%s\n' "$BOLD" "$NC"
defif="$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
ip=""
[ -n "$defif" ] && ip="$(/usr/sbin/ipconfig getifaddr "$defif" 2>/dev/null)"
ssid="$(wifi_ssid)"
if [ -n "$ssid" ]; then
  netline="  Wi-Fi「${ssid}」· 本机 IP ${ip:-未知}"
else
  netline="  本机 IP ${ip:-未知}"
fi
[ -n "$defif" ] && netline="$netline（$defif）"
gw="$(default_gateway)"
[ -n "$gw" ] && netline="$netline · 网关 $gw"
printf '%s\n' "$netline"

tsb="$(tailscale_backend)"
tso="$(tailscale_self_online)"
tsip="$(tailscale_ip)"
printf '  Tailscale：'
if [ "$tsb" = "Running" ] && [ "$tso" = "true" ]; then
  printf '%s✅ 在线%s' "$GREEN" "$NC"
elif [ -z "$tsb" ]; then
  printf '%s⚠️  未检测到%s（未安装或 CLI 不可用）' "$YELLOW" "$NC"
else
  printf '%s⚠️  状态 %s%s' "$YELLOW" "${tsb:-未知}" "$NC"
fi
[ -n "$tsip" ] && printf ' · %s' "$tsip"
printf '\n'

# ── 7. 远程控制软件 ─────────────────────────────────────────────────
printf '\n%s远程控制%s\n' "$BOLD" "$NC"
rd_pid="$(pgrep -f 'RustDesk --server' 2>/dev/null | head -1)"
if [ -n "$rd_pid" ]; then
  printf '  RustDesk：%s✅ 运行中%s（pid %s）\n' "$GREEN" "$NC" "$rd_pid"
else
  printf '  RustDesk：%s✗ 未运行%s\n' "$DIM" "$NC"
fi
td_pid="$(pgrep -f '/Applications/ToDesk.app' 2>/dev/null | head -1)"
if [ -n "$td_pid" ]; then
  printf '  ToDesk：%s✅ 运行中%s（pid %s）\n' "$GREEN" "$NC" "$td_pid"
else
  printf '  ToDesk：%s✗ 未运行%s\n' "$DIM" "$NC"
fi
if [ "$(screensharing_listening)" = "1" ]; then
  printf '  macOS 屏幕共享：%s✅ 已开启%s（5900 端口监听中）\n' "$GREEN" "$NC"
else
  printf '  macOS 屏幕共享：%s✗ 未开启%s（要用系统自带的：设置 → 通用 → 共享 → 屏幕共享）\n' "$DIM" "$NC"
fi

# ── 8. 最近的睡眠/唤醒记录 ──────────────────────────────────────────
printf '\n%s最近的睡眠/唤醒记录%s\n' "$BOLD" "$NC"
recent="$(/usr/bin/pmset -g log 2>/dev/null | grep -E "Entering Sleep state|Wake from" | tail -4)"
if [ -n "$recent" ]; then
  printf '%s\n' "$recent" | awk -F'\t' '
    {
      split($1, a, " ")
      t = a[4]
      if (t == "Sleep")          tcn = "睡眠"
      else if (t == "Wake")      tcn = "唤醒"
      else if (t == "DarkWake")  tcn = "后台唤醒"
      else                       tcn = t
      reason = $2
      if (reason ~ /Clamshell Sleep/)    rcn = "合盖导致休眠"
      else if (reason ~ /lid/)           rcn = "开盖唤醒"
      else if (reason ~ /UserActivity/)  rcn = "用户活动"
      else if (reason ~ /Idle Sleep/)    rcn = "闲置休眠"
      else                               rcn = substr(reason, 1, 60)
      printf "  %s %s  %-6s %s\n", a[1], a[2], tcn, rcn
    }'
  printf '\n'
  last_cs="$(/usr/bin/pmset -g log 2>/dev/null | grep "Entering Sleep state due to 'Clamshell Sleep'" | tail -1 | awk '{print $1" "$2}')"
  if [ -n "$last_cs" ]; then
    printf '  %s最近一次「合盖休眠」：%s%s\n' "$DIM" "$last_cs" "$NC"
    printf '  %s（如果它发生在你开启「合盖不休眠」之后，说明设置没生效）%s\n' "$DIM" "$NC"
  else
    printf '  %s日志中没有「合盖休眠」记录 —— 好现象%s\n' "$DIM" "$NC"
  fi
else
  info "读取不到系统电源日志"
fi

# ── 9. 最近一次合盖测试结果 ─────────────────────────────────────────
if [ -f "$LOG_DIR/合盖测试最近结果.txt" ]; then
  printf '\n%s最近一次合盖测试%s\n' "$BOLD" "$NC"
  sed 's/^/  /' "$LOG_DIR/合盖测试最近结果.txt"
else
  printf '\n%s还没有做过合盖测试 —— 建议运行「4-合盖测试.command」验证一次%s\n' "$DIM" "$NC"
fi

# ── 10. 结论 ────────────────────────────────────────────────────────
printf '\n'
hr
if [ "$sd" = "1" ] && [ "$sd_kern" = "Yes" ]; then
  printf '%s结论：合盖不休眠已生效 —— 合上盖子后系统、网络、Tailscale、远程桌面都会保持运行。%s\n' \
    "$GREEN" "$NC"
  case "$src" in
    Battery*) printf '%s提示：当前是电池供电，合盖状态下会持续掉电，注意剩余电量。%s\n' "$YELLOW" "$NC" ;;
  esac
  printf '%s验证方法：合盖后从手机/另一台电脑 tailscale ping 本机，或用 RustDesk / ToDesk 连一下。%s\n' "$DIM" "$NC"
else
  printf '%s结论：合盖不休眠尚未生效 —— 请运行「1-开启防合盖休眠.command」。%s\n' "$RED" "$NC"
fi

log "状态检查：SleepDisabled=${sd:-空} 内核=${sd_kern:-空} 电源=${src:-未知} 电池=${btext:-?} Tailscale=${tsb:-未知} RustDesk=${rd_pid:-未运行} ToDesk=${td_pid:-未运行}"

pause_exit
