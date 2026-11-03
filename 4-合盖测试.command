#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  ④ 合盖测试
#  一次运行自动完成：监听合盖 → 每 5 秒采样 → 开盖后自动给出 PASS / FAIL
#  采样内容：合盖状态、电源、电量、Tailscale 状态、公网连通性、屏幕截图大小
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=.lib.sh
source "$HERE/.lib.sh"

STOP_FILE="$LOG_DIR/合盖测试.stop"
SAMPLE_FILE="$LOG_DIR/合盖测试采样.log"
CAP_DIR="$LOG_DIR/合盖测试截图"
SAMPLER_PID_FILE="$LOG_DIR/合盖测试.sampler.pid"
RESULT_FILE="$LOG_DIR/合盖测试最近结果.txt"

MIN_CLOSE_SECS="${MIN_CLOSE_SECS:-8}"      # 合盖至少持续这么久才算一次有效测试
WAIT_CLOSE_MAX="${WAIT_CLOSE_MAX:-900}"    # 最多等多久让你合盖（秒）
WAIT_OPEN_MAX="${WAIT_OPEN_MAX:-600}"      # 合盖后最多等多久让你开盖（秒）
MAX_GAP="${MAX_GAP:-30}"                   # 采样间隔超过这个值就说明系统被挂起/休眠过（秒）
# 采样器最长运行多久（秒）：比"等合盖 + 等开盖"再宽裕一些，避免长时间等待时采样提前断掉
SAMPLE_MAX_SECS="${SAMPLE_MAX_SECS:-$((WAIT_CLOSE_MAX + WAIT_OPEN_MAX + 600))}"
LOCK_FILE="$LOG_DIR/合盖测试.lock"

# ═════════════════════════════════════════════════════════════════════
#  采样模式（由 --sample 启动的后台子进程使用，正常运行时不会走到这里）
# ═════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--sample" ]; then
  rm -rf "$CAP_DIR"
  mkdir -p "$CAP_DIR"
  : > "$SAMPLE_FILE"
  started=$SECONDS
  n=0
  while [ $((SECONDS - started)) -lt "${SAMPLE_MAX_SECS:-1800}" ] && [ ! -f "$STOP_FILE" ]; do
    ts_epoch="$(date +%s)"
    ts_human="$(date '+%Y-%m-%d %H:%M:%S')"
    closed="$(clamshell_closed)"
    src="$(power_source)"
    bat="$(battery_percent)"
    tsb="$(tailscale_backend)"
    net="$(net_ok)"
    cap="-"
    # 合盖期间每 20 秒抓一张图，用文件大小判断画面是否还能被看到
    if [ "$closed" = "Yes" ] && [ "${CAP_ENABLED:-0}" = "1" ] && [ $((n % 4)) -eq 0 ]; then
      f="$CAP_DIR/$(date '+%H%M%S').png"
      /usr/bin/perl -e 'alarm shift; exec @ARGV' 12 /usr/sbin/screencapture -x "$f" >/dev/null 2>&1
      if [ -f "$f" ]; then
        cap="$(stat -f%z "$f" 2>/dev/null || echo 0)"
      else
        cap=0
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ts_epoch" "$ts_human" "$closed" "$src" "${bat:-?}" "${tsb:-?}" "$net" "$cap" >>"$SAMPLE_FILE"
    n=$((n + 1))
    sleep 5
  done
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════
#  正式测试
# ═════════════════════════════════════════════════════════════════════
case "${1:-}" in
  "") ;;
  -h|--help)
    printf '用法：双击运行，或在终端里执行本脚本，然后按提示合盖即可。\n'
    printf '本脚本不需要任何参数；请不要从命令行带参数运行，否则会被当成一次完整测试。\n'
    exit 0
    ;;
  *)
    printf '未知参数：%s\n' "$1" >&2
    printf '本脚本不需要参数，直接双击运行即可。\n' >&2
    exit 1
    ;;
esac

title "④ 合盖测试 · 验证合盖后系统是否保持运行"
hr

# ── 前置检查 ────────────────────────────────────────────────────────
sd="$(sleep_disabled)"
sd_kern="$(sleep_disabled_kernel)"
if [ "$sd" != "1" ] || [ "$sd_kern" != "Yes" ]; then
  bad "「合盖不休眠」还没开启，现在测试没有意义。"
  info "请先双击运行「1-开启防合盖休眠.command」，然后再运行本测试。"
  log "合盖测试：前置条件不满足（pmset=${sd:-空} / 内核=${sd_kern:-空}）"
  pause_exit
  exit 1
fi
ok "前置检查通过：合盖不休眠已开启（pmset=1 / 内核 SleepDisabled=Yes）"

# ── 屏幕录制权限自检（决定要不要在合盖时截图）───────────────────────
CAP_ENABLED=0
probe="$LOG_DIR/.截图自检.png"
rm -f "$probe"
/usr/bin/perl -e 'alarm shift; exec @ARGV' 12 /usr/sbin/screencapture -x "$probe" >/dev/null 2>&1
if [ -f "$probe" ]; then
  psize="$(stat -f%z "$probe" 2>/dev/null || echo 0)"
  [ "${psize:-0}" -gt 200000 ] && CAP_ENABLED=1
fi
rm -f "$probe"
if [ "$CAP_ENABLED" = "1" ]; then
  ok "屏幕录制权限正常，合盖期间会截图检查画面是否可用"
else
  warn "没有屏幕录制权限，本次跳过「画面是否可用」检测（休眠检测不受影响）"
  info "如果刚才弹出了「终端想录制屏幕」的提示，允许后重新运行本脚本即可包含画面检测。"
fi

# ── 防止重复运行（两个人同时跑会互相覆盖采样文件）──────────────────
if [ -f "$LOCK_FILE" ]; then
  lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [ -n "${lock_pid:-}" ] && kill -0 "$lock_pid" 2>/dev/null; then
    bad "已经有一个合盖测试正在运行（pid ${lock_pid}）。"
    info "如果这是你之前启动的测试，直接去合盖就行，不用重复启动。"
    info "如果确认是上次异常退出留下的残留，删掉 ${LOCK_FILE} 后再试。"
    pause_exit
    exit 3
  fi
  rm -f "$LOCK_FILE"
fi
printf '%s' "$$" > "$LOCK_FILE"

# ── 准备采样文件 ────────────────────────────────────────────────────
rm -f "$STOP_FILE"
: > "$SAMPLE_FILE"

# ── 启动后台采样器 ──────────────────────────────────────────────────
SELF="$HERE/$(basename "$0")"
CAP_ENABLED="$CAP_ENABLED" SAMPLE_MAX_SECS="$SAMPLE_MAX_SECS" nohup "$SELF" --sample >"$LOG_DIR/合盖测试采样器.log" 2>&1 &
SAMPLER_PID=$!
printf '%s' "$SAMPLER_PID" >"$SAMPLER_PID_FILE"
disown "$SAMPLER_PID" 2>/dev/null || true

cleanup() {
  touch "$STOP_FILE" 2>/dev/null
  if [ -n "${SAMPLER_PID:-}" ]; then
    kill "$SAMPLER_PID" 2>/dev/null
  fi
  rm -f "$LOCK_FILE" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── 操作指引 ────────────────────────────────────────────────────────
printf '\n'
hr
printf '%s现在开始测试，请按顺序操作：%s\n' "$BOLD" "$NC"
printf '  1) 合上笔记本盖子\n'
printf '  2) 等待 60～120 秒（建议 90 秒；系统合盖后约有 20 秒延迟才会休眠，太短测不出来）\n'
printf '  3) 打开盖子，回到这个窗口 —— 结论会自动打印出来\n'
printf '\n'
info "合盖期间屏幕熄灭是正常的；中途打开也没关系，脚本会自动记录真实合盖时长。"
info "测试期间请不要关闭这个终端窗口。"
if [ "$WAIT_CLOSE_MAX" -ge 120 ]; then
  wait_desc="$((WAIT_CLOSE_MAX / 60)) 分钟"
else
  wait_desc="${WAIT_CLOSE_MAX} 秒"
fi
wait_till="$(/bin/date -r $(( $(date +%s) + WAIT_CLOSE_MAX )) '+%H:%M' 2>/dev/null || true)"
printf '\n%s正在监听合盖状态…（最多等待 %s%s，可随时按 Ctrl+C 中断）%s\n' "$CYAN" "$wait_desc" "${wait_till:+，到 $wait_till 为止}" "$NC"

# ── 等待合盖 → 开盖 ─────────────────────────────────────────────────
deadline=$(( $(date +%s) + WAIT_CLOSE_MAX ))
closed_at=0
opened_at=0
valid=0

while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ "$(clamshell_closed)" = "Yes" ]; then
    closed_at="$(date +%s)"
    printf '  → 已检测到合盖（%s），保持合盖中…\n' "$(date '+%H:%M:%S')"
    hard=$((closed_at + WAIT_OPEN_MAX))
    while [ "$(date +%s)" -lt "$hard" ]; do
      [ "$(clamshell_closed)" = "No" ] && break
      sleep 2
    done
    opened_at="$(date +%s)"
    dur=$((opened_at - closed_at))
    if [ "$dur" -ge "$MIN_CLOSE_SECS" ]; then
      printf '  → 已检测到开盖（%s），本次合盖时长 %s 秒\n' "$(date '+%H:%M:%S')" "$dur"
      valid=1
      break
    fi
    warn "合盖只持续了 ${dur} 秒，太短了，请重新合盖并保持 60 秒以上…"
    closed_at=0
  fi
  sleep 2
done

if [ "$valid" != "1" ]; then
  bad "没有检测到有效的合盖（超时或合盖时间过短），本次测试结束。"
  info "本次等待了 ${wait_desc}，期间没有检测到持续 ${MIN_CLOSE_SECS} 秒以上的合盖。"
  info "请重新运行本脚本，并在听到「咔哒」后保持合盖 60 秒以上。"
  log "合盖测试：未检测到有效合盖"
  pause_exit
  exit 2
fi

# ── 停止采样并统计 ──────────────────────────────────────────────────
touch "$STOP_FILE"
sleep 1
kill "$SAMPLER_PID" 2>/dev/null
SAMPLER_PID=""

close_dur=$((opened_at - closed_at))

# 只统计「本次合盖的时间窗口内」的睡眠记录。
# 不能用「测试前后总数相减」：pmset 日志会滚动，旧记录被挤掉会让差值变成负数。
w_start="$(/bin/date -r $((closed_at - 3)) '+%Y-%m-%d %H:%M:%S')"
w_end="$(/bin/date -r $((opened_at + 3)) '+%Y-%m-%d %H:%M:%S')"
pmlog="$(/usr/bin/pmset -g log 2>/dev/null)"
sleep_new="$(printf '%s\n' "$pmlog" | awk -v s="$w_start" -v e="$w_end" '
  $1 ~ /^[0-9][0-9][0-9][0-9]-/ { d = $1 " " $2; if (d >= s && d <= e && index($0, "Entering Sleep state")) n++ }
  END { print n + 0 }')"
clamshell_new="$(printf '%s\n' "$pmlog" | awk -v s="$w_start" -v e="$w_end" '
  $1 ~ /^[0-9][0-9][0-9][0-9]-/ { d = $1 " " $2; if (d >= s && d <= e && index($0, "Entering Sleep state") && index($0, "Clamshell Sleep")) n++ }
  END { print n + 0 }')"
wake_new="$(printf '%s\n' "$pmlog" | awk -v s="$w_start" -v e="$w_end" '
  $1 ~ /^[0-9][0-9][0-9][0-9]-/ { d = $1 " " $2; if (d >= s && d <= e && index($0, "Wake from")) n++ }
  END { print n + 0 }')"

W1=$((closed_at - 5))
W2=$((opened_at + 5))
read -r n closedn tsok netok capn capmin capmax maxgap <<EOF
$(awk -F'\t' -v w1="$W1" -v w2="$W2" '
  BEGIN { capmin = 0; capmax = 0; maxgap = 0; n = 0; closedn = 0; tsok = 0; netok = 0; capn = 0; prev = 0 }
  $1 >= w1 && $1 <= w2 {
    n++
    if (prev > 0) { g = $1 - prev; if (g > maxgap) maxgap = g }
    prev = $1
    if ($3 == "Yes") closedn++
    if ($6 == "Running") tsok++
    if ($7 == "OK") netok++
    if ($8 != "-" && $8 + 0 > 0) {
      capn++
      if (capmin == 0 || $8 + 0 < capmin) capmin = $8 + 0
      if ($8 + 0 > capmax) capmax = $8 + 0
    }
  }
  END { printf "%d %d %d %d %d %d %d %d\n", n, closedn, tsok, netok, capn, capmin, capmax, maxgap }
' "$SAMPLE_FILE")
EOF

: "${n:=0}"; : "${closedn:=0}"; : "${tsok:=0}"; : "${netok:=0}"
: "${capn:=0}"; : "${capmin:=0}"; : "${capmax:=0}"; : "${maxgap:=0}"

[ "$n" -eq 0 ] && maxgap=0

# ── 判定 ────────────────────────────────────────────────────────────
verdict="PASS"
reasons=""
if [ "$sleep_new" -gt 0 ]; then
  verdict="FAIL"
  reasons="${reasons}   · 合盖窗口内出现了 ${sleep_new} 条休眠记录（说明合盖后还是睡了）\n"
fi
if [ "$clamshell_new" -gt 0 ]; then
  verdict="FAIL"
  reasons="${reasons}   · 其中「合盖休眠 Clamshell Sleep」${clamshell_new} 条\n"
fi
if [ "$maxgap" -gt "$MAX_GAP" ]; then
  verdict="FAIL"
  reasons="${reasons}   · 采样在合盖期间中断了 ${maxgap} 秒，说明系统被挂起或休眠过\n"
fi
if [ "$n" -eq 0 ]; then
  verdict="FAIL"
  reasons="${reasons}   · 一个采样点都没有，无法判断（可能是脚本被中断）\n"
fi
if [ "$closedn" -eq 0 ] && [ "$n" -gt 0 ]; then
  verdict="FAIL"
  reasons="${reasons}   · 采样期间没有记录到「已合盖」状态，可能盖子没合严\n"
fi
if [ "$netok" -lt "$n" ] && [ "$n" -gt 0 ]; then
  reasons="${reasons}   · 有 $((n - netok)) 次公网探测失败（网络可能短暂中断）\n"
fi
if [ "$tsok" -lt "$n" ] && [ "$n" -gt 0 ]; then
  reasons="${reasons}   · 有 $((n - tsok)) 次 Tailscale 不在 Running 状态\n"
fi

# 画面可用性判断
if [ "$CAP_ENABLED" != "1" ]; then
  cap_line="未开启屏幕录制权限，跳过画面检测"
elif [ "$capn" -eq 0 ]; then
  cap_line="没有截到图（截图失败），无法判断画面是否可用"
elif [ "$capmax" -gt 200000 ]; then
  cap_line="合盖期间截图 ${capn} 张，大小 $((capmin / 1024)) KB ~ $((capmax / 1024)) KB —— 画面正常，远程桌面通常能看到桌面"
else
  cap_line="合盖期间截图 ${capn} 张，都很小（最大 $((capmax / 1024)) KB）—— 画面可能是黑的，远程桌面可能只看到黑屏"
fi

REPORT_FILE="$LOG_DIR/合盖测试报告-$(date '+%Y%m%d-%H%M%S').log"
{
  echo "防合盖休眠 · 合盖测试报告"
  echo "────────────────────────────────────────────────────────────"
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "机器：$(sysctl -n hw.model 2>/dev/null) · $(sysctl -n machdep.cpu.brand_string 2>/dev/null) · macOS $(sw_vers -productVersion 2>/dev/null)"
  echo "设置：pmset SleepDisabled=$(sleep_disabled) · 内核 SleepDisabled=$(sleep_disabled_kernel)"
  echo ""
  echo "一、合盖过程"
  echo "  合盖时间：$(date -r "$closed_at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  echo "  开盖时间：$(date -r "$opened_at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  echo "  合盖时长：${close_dur} 秒"
  echo ""
  echo "二、休眠检测"
  echo "  检测窗口：${w_start} ～ ${w_end}"
  echo "  窗口内「Entering Sleep state」：${sleep_new} 条"
  echo "  窗口内「Clamshell Sleep」：${clamshell_new} 条"
  echo "  窗口内「Wake from」：${wake_new} 条"
  echo "  合盖期间采样点：${n} 个，最大采样间隔：${maxgap} 秒（超过 ${MAX_GAP} 秒说明系统被挂起/休眠过）"
  echo ""
  echo "三、网络"
  echo "  公网探测成功：${netok}/${n}"
  echo "  Tailscale 状态 Running：${tsok}/${n}"
  echo ""
  echo "四、画面（远程桌面能否看到画面）"
  echo "  ${cap_line}"
  echo ""
  echo "五、结论"
  if [ "$verdict" = "PASS" ]; then
    echo "  ✅ 通过：合盖 ${close_dur} 秒期间系统没有休眠，网络与 Tailscale 保持正常。"
  else
    echo "  ❌ 未通过"
    printf '%b' "$reasons"
  fi
  echo ""
  echo "建议：合盖后用另一台设备 tailscale ping 本机，或用 RustDesk / ToDesk 实际连一次，"
  echo "      确认远程桌面画面与操作都正常（这一步无法完全自动化）。"
  echo ""
  echo "采样明细：${SAMPLE_FILE}"
  [ "$capn" -gt 0 ] && echo "截图目录：${CAP_DIR}"
} >"$REPORT_FILE"

cat "$REPORT_FILE"

# ── 屏幕上的彩色结论 ────────────────────────────────────────────────
printf '\n'
hr
if [ "$verdict" = "PASS" ]; then
  printf '%s✅ 测试通过：合盖 %s 秒期间系统保持运行，没有休眠。%s\n' "$GREEN" "$close_dur" "$NC"
  info "网络探测 ${netok}/${n} 成功 · Tailscale Running ${tsok}/${n} 次"
  if [ "$CAP_ENABLED" = "1" ] && [ "$capn" -gt 0 ] && [ "$capmax" -le 200000 ]; then
    warn "不过合盖期间画面偏黑（截图都小于 100 KB），远程桌面可能会看到黑屏 —— 请按 README 的排查步骤处理。"
  fi
  printf '\n%s最后一步：%s合上盖子后，从你的另一台电脑（yyzwindows11）用 RustDesk 连这台 Mac，确认能看到画面并能操作。\n' "$CYAN" "$NC"
else
  printf '%s❌ 测试未通过：合盖后系统仍然休眠了。%s\n' "$RED" "$NC"
  printf '%b' "$reasons"
  printf '\n%s下一步：%s\n' "$CYAN" "$NC"
  printf '   1) 先运行「③ 查看状态.command」，确认「合盖不休眠」显示为已开启\n'
  printf '   2) 把本报告文件发给助手，或运行「1-开启防合盖休眠.command」重新设置后重启再试\n'
fi
printf '\n%s报告已保存：%s%s\n' "$DIM" "$REPORT_FILE" "$NC"

{
  echo "测试时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "合盖时长：${close_dur} 秒"
  if [ "$verdict" = "PASS" ]; then
    echo "结论：✅ 通过（合盖后系统未休眠，网络/Tailscale 正常）"
  else
    echo "结论：❌ 未通过（合盖后系统仍休眠）"
  fi
  echo "报告文件：$(basename "$REPORT_FILE")"
} >"$RESULT_FILE"

log "合盖测试：${verdict}，合盖 ${close_dur} 秒，新增休眠 ${sleep_new} 条，最大采样间隔 ${maxgap} 秒"

pause_exit
