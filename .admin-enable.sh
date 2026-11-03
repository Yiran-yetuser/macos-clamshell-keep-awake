#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  以 root 身份执行：开启合盖不休眠 + 安装「守护进程」
#  这个文件由「1-开启防合盖休眠.command」通过 osascript 以管理员权限调用，
#  不要直接双击运行。
#
#  为什么要守护进程：
#    少数第三方软件（本机已确认是 ToDesk 的 ToDesk_XPCHelper）会调用
#    `pmset -a disablesleep 0`，把我们设置的开关改回去（日志证据见
#    ~/Library/Logs/ToDesk/ToDesk_XPCHelper_*.log 里的
#    “[XPCHelper] set disable sleep: 0”）。
#    守护进程每 2 秒检查一次，一旦发现被改回 0 就自动恢复为 1，
#    并把每次「被改动」的时间和次数记录到 /var/log/yz-keepawake.log。
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail

BIN=/usr/local/sbin/yz-keepawake.sh
PLIST=/Library/LaunchDaemons/com.yyz.keepawake.plist
LOG=/var/log/yz-keepawake.log

# ── 1. 先设置开关 ────────────────────────────────────────────────────
/usr/bin/pmset -a disablesleep 1

# ── 2. 写入守护脚本 ──────────────────────────────────────────────────
/bin/mkdir -p /usr/local/sbin
/bin/cat > "$BIN" <<'DAEMON'
#!/bin/bash
# 合盖不休眠守护：SleepDisabled 被别的程序改回 0 时立刻恢复为 1
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOG=/var/log/yz-keepawake.log
cur="$(/usr/bin/pmset -g 2>/dev/null | /usr/bin/awk '/SleepDisabled[ \t]/{print $2}')"
if [ "$cur" != "1" ]; then
  /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1
  printf '%s  SleepDisabled=%s -> 已恢复为 1\n' "$(/bin/date '+%F %T')" "${cur:-空}" >> "$LOG"
fi
exit 0
DAEMON
/bin/chmod 755 "$BIN"
/usr/sbin/chown root:wheel "$BIN"

# ── 3. 写入 LaunchDaemon ─────────────────────────────────────────────
/bin/cat > "$PLIST" <<'PLISTXML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.yyz.keepawake</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>/usr/local/sbin/yz-keepawake.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>2</integer>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>/var/log/yz-keepawake.out</string>
	<key>StandardErrorPath</key>
	<string>/var/log/yz-keepawake.err</string>
</dict>
</plist>
PLISTXML
/bin/chmod 644 "$PLIST"
/usr/sbin/chown root:wheel "$PLIST"

# ── 4. 启动（重启/重装时先卸载旧的）──────────────────────────────────
/bin/launchctl bootout system/com.yyz.keepawake 2>/dev/null
/bin/sleep 0.3
/bin/launchctl bootstrap system "$PLIST"
/bin/launchctl enable system/com.yyz.keepawake 2>/dev/null

# ── 5. 输出结果（.command 脚本会解析这些行）──────────────────────────
printf 'pmset=%s\n' "$(/usr/bin/pmset -g 2>/dev/null | /usr/bin/awk '/SleepDisabled[ \t]/{print $2}')"
if /bin/launchctl print system/com.yyz.keepawake >/dev/null 2>&1; then
  printf 'daemon=running\n'
else
  printf 'daemon=missing\n'
fi
exit 0
