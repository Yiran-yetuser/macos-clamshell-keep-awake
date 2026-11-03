import SwiftUI
import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────
//  合盖不休眠 · 控制面板（本地小工具）
//  - 系统层：pmset -a disablesleep 1 + root 守护 com.yyz.keepawake（每 2 秒纠正被第三方改回的值）
//  - 画面层：合盖/远程时建 HiDPI 虚拟屏，内建屏镜像过去；远程断开自动恢复本机屏幕
// ─────────────────────────────────────────────────────────────────────

let kSupportDir = NSString(string: "~/Library/Application Support/yz-keepawake").expandingTildeInPath
let kLogDir = kSupportDir + "/logs"
let kAgentLabel = "com.yyz.lidawake"
let kAgentPlist = NSString(string: "~/Library/LaunchAgents/com.yyz.lidawake.plist").expandingTildeInPath
let kHdConf = kSupportDir + "/hd.conf"
let kUid = String(getuid())

func shell(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func resourcePath(_ name: String) -> String {
    if let r = Bundle.main.resourcePath { return r + "/" + name }
    return name
}

func runAdmin(script: String, prompt: String, log: String) -> (ok: Bool, message: String) {
    let src = resourcePath(script)
    let tmpdir = "/tmp/yzapp-" + UUID().uuidString
    _ = shell("/bin/mkdir -p '\(tmpdir)' && /bin/cp -f '\(src)' '\(tmpdir)/run.sh' && /bin/chmod 755 '\(tmpdir)/run.sh'")
    let out = shell("/usr/bin/osascript -e 'do shell script \"/bin/bash \(tmpdir)/run.sh\" with administrator privileges with prompt \"\(prompt)\"'")
    _ = shell("/bin/rm -rf '\(tmpdir)'")
    if out.contains("-128") || out.lowercased().contains("user canceled") || out.lowercased().contains("用户已取消") {
        return (false, "已取消（没有管理员授权）")
    }
    if out.contains("error") || out.contains("错误") {
        return (false, out)
    }
    return (true, out)
}

func installScreenDaemon() -> String {
    let bin = kSupportDir + "/bin"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: kLogDir, withIntermediateDirectories: true)
    for f in ["vdisp", "setbright", "mirror", "capprobe"] {
        let dst = bin + "/" + f
        try? fm.removeItem(atPath: dst)
        try? fm.copyItem(atPath: resourcePath(f), toPath: dst)
        _ = shell("/bin/chmod 755 '\(dst)'")
    }
    let script = kSupportDir + "/lidwatch.sh"
    try? fm.removeItem(atPath: script)
    try? fm.copyItem(atPath: resourcePath("lidwatch.sh"), toPath: script)
    _ = shell("/bin/chmod 755 '\(script)'")

    let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key><string>\(kAgentLabel)</string>
\t<key>ProgramArguments</key>
\t<array><string>/bin/bash</string><string>\(script)</string></array>
\t<key>RunAtLoad</key><true/>
\t<key>KeepAlive</key><true/>
\t<key>ThrottleInterval</key><integer>5</integer>
\t<key>LimitLoadToSessionType</key><string>Aqua</string>
\t<key>ProcessType</key><string>Interactive</string>
\t<key>StandardOutPath</key><string>\(kLogDir)/lidwatch.out</string>
\t<key>StandardErrorPath</key><string>\(kLogDir)/lidwatch.err</string>
</dict>
</plist>
"""
    try? plist.write(toFile: kAgentPlist, atomically: true, encoding: .utf8)
    _ = shell("/bin/launchctl bootout gui/\(kUid)/\(kAgentLabel) 2>/dev/null; /bin/sleep 1; /bin/launchctl bootstrap gui/\(kUid) '\(kAgentPlist)'")
    let st = shell("/bin/launchctl print gui/\(kUid)/\(kAgentLabel) >/dev/null 2>&1 && echo running || echo missing")
    if st != "running" {
        _ = shell("/bin/sleep 1; /bin/launchctl bootstrap gui/\(kUid) '\(kAgentPlist)'")
    }
    return shell("/bin/launchctl print gui/\(kUid)/\(kAgentLabel) >/dev/null 2>&1 && echo running || echo missing")
}

func uninstallScreenDaemon() {
    _ = shell("/bin/launchctl bootout gui/\(kUid)/\(kAgentLabel) 2>/dev/null")
    _ = shell("/bin/sleep 1; /bin/rm -f '\(kAgentPlist)'")
    _ = shell("pkill -9 -f '\(kSupportDir)/lidwatch.sh' 2>/dev/null; pkill -9 -f '\(kSupportDir)/bin/vdisp' 2>/dev/null")
    let mirror = kSupportDir + "/bin/mirror"
    if FileManager.default.isExecutableFile(atPath: mirror) { _ = shell("'\(mirror)' off >/dev/null 2>&1") }
}

func writeHdPreset(_ value: String) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: kSupportDir, withIntermediateDirectories: true)
    try? (value + "\n").write(toFile: kHdConf, atomically: true, encoding: .utf8)
    _ = shell("/bin/launchctl kickstart -k gui/\(kUid)/\(kAgentLabel) 2>/dev/null")
}

// ───────────────────────────── 状态模型 ─────────────────────────────
final class Model: ObservableObject {
    @Published var pmset = "-"
    @Published var kernel = "-"
    @Published var keepDaemon = "-"
    @Published var driftCount = "0"
    @Published var driftLast = ""
    @Published var lidwatch = "-"
    @Published var hdActive = false
    @Published var mainSize = "-"
    @Published var brightness = "-"
    @Published var lidClosed = false
    @Published var tailscale = "-"
    @Published var tsIP = "-"
    @Published var uuRunning = false
    @Published var hdPreset = "-"
    @Published var busy = false
    @Published var toast = ""
    @Published var lastRefresh = Date()

    var healthy: Bool { pmset == "1" && kernel == "Yes" && keepDaemon == "running" && lidwatch == "running" }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            var pmset = shell("/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled[ \\t]/{print $2}'")
            let kernel = shell("/usr/sbin/ioreg -r -n IOPMrootDomain -d 1 | /usr/bin/awk -F'= ' '/\"SleepDisabled\"/{print $2; exit}'")
            if pmset != "1" {
                usleep(1_300_000)   // 第三方软件刚改回 0，给守护 2 秒纠正时间，避免界面抖动
                pmset = shell("/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled[ \\t]/{print $2}'")
            }
            let keep = shell("/bin/launchctl print system/com.yyz.keepawake >/dev/null 2>&1 && echo running || echo missing")
            let drift = shell("/usr/bin/grep -c '已恢复为 1' /var/log/yz-keepawake.log 2>/dev/null || echo 0")
            let driftLast = shell("/usr/bin/tail -1 /var/log/yz-keepawake.log 2>/dev/null")
            let lw = shell("/bin/launchctl print gui/\(kUid)/\(kAgentLabel) >/dev/null 2>&1 && echo running || echo missing")
            let hdA = shell("/bin/test -f '\(kSupportDir)/hd.active' && echo yes || echo no") == "yes"
            let size = shell("'\(kSupportDir)/bin/vdisp' --size 2>/dev/null | /usr/bin/awk 'NF>=2{print $1\"×\"$2}'")
            var bright = shell("'\(kSupportDir)/bin/setbright' 2>/dev/null")
            if bright.isEmpty { bright = "—" }
            let lid = shell("/usr/sbin/ioreg -r -n IOPMrootDomain -d 1 | /usr/bin/awk -F'= ' '/\"AppleClamshellState\"/{print $2; exit}'")
            let ts = shell("/usr/local/bin/tailscale status --json 2>/dev/null | /usr/bin/grep -m1 -o '\"BackendState\": \"[^\"]*\"' | /usr/bin/awk -F'\"' '{print $4}'")
            let ip = shell("/usr/local/bin/tailscale ip -4 2>/dev/null | /usr/bin/head -1")
            let uu = shell("/usr/bin/pgrep -f UURemoteServer >/dev/null 2>&1 && echo yes || echo no") == "yes"
            let conf = (try? String(contentsOfFile: kHdConf, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
            DispatchQueue.main.async {
                self.pmset = pmset.isEmpty ? "-" : pmset
                self.kernel = kernel.isEmpty ? "-" : kernel
                self.keepDaemon = keep
                self.driftCount = drift.isEmpty ? "0" : drift
                self.driftLast = driftLast
                self.lidwatch = lw
                self.hdActive = hdA
                self.mainSize = size.isEmpty ? "-" : size
                self.brightness = bright
                self.lidClosed = (lid == "Yes")
                self.tailscale = ts.isEmpty ? "-" : ts
                self.tsIP = ip.isEmpty ? "-" : ip
                self.uuRunning = uu
                self.hdPreset = conf
                self.lastRefresh = Date()
            }
        }
    }

    func enableAll() {
        busy = true; toast = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let lw = installScreenDaemon()
            let r = runAdmin(script: "admin-enable.sh", prompt: "开启合盖不休眠需要管理员权限", log: "")
            DispatchQueue.main.async {
                self.busy = false
                if r.ok {
                    self.toast = "已开启：合盖不休眠 + 守护进程" + (lw == "running" ? " + 画面守护" : "（画面守护未启动）")
                } else {
                    self.toast = r.message.isEmpty ? "开启失败" : r.message
                }
                self.refresh()
            }
        }
    }

    func disableAll() {
        busy = true; toast = ""
        DispatchQueue.global(qos: .userInitiated).async {
            uninstallScreenDaemon()
            let r = runAdmin(script: "admin-disable.sh", prompt: "关闭合盖不休眠需要管理员权限", log: "")
            DispatchQueue.main.async {
                self.busy = false
                self.toast = r.ok ? "已关闭：合盖即休眠（恢复系统默认）" : (r.message.isEmpty ? "关闭失败" : r.message)
                self.refresh()
            }
        }
    }

    func reinstallScreen() {
        busy = true; toast = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let st = installScreenDaemon()
            DispatchQueue.main.async {
                self.busy = false
                self.toast = st == "running" ? "画面守护已安装并启动" : "画面守护启动失败"
                self.refresh()
            }
        }
    }
}

// ───────────────────────────── 界面 ─────────────────────────────
struct Row: View {
    let label: String
    let value: String
    var good: Bool? = nil
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(good == nil ? Color.primary : (good! ? Color.green : Color.orange))
        }
        .font(.system(size: 13))
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.tint)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct ContentView: View {
    @StateObject var m = Model()
    @State private var preset: String = "1920 1080 1 always"
    @State private var ready = false
    @State private var timer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: m.healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(m.healthy ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.healthy ? "合盖不休眠：已开启" : "合盖不休眠：未完全开启")
                        .font(.system(size: 17, weight: .bold))
                    Text("系统层 disablesleep + 守护进程 · 画面层虚拟屏镜像 · 远程断开自动恢复")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if m.busy { ProgressView().controlSize(.small) }
            }

            Card(title: "系统层（合盖不休眠）", icon: "power") {
                Row(label: "pmset SleepDisabled", value: m.pmset, good: m.pmset == "1")
                Row(label: "内核 SleepDisabled", value: m.kernel, good: m.kernel == "Yes")
                Row(label: "休眠守护 com.yyz.keepawake", value: m.keepDaemon == "running" ? "运行中" : "未运行", good: m.keepDaemon == "running")
                Row(label: "被第三方改回的次数", value: "\(m.driftCount) 次" + (m.driftLast.isEmpty ? "" : "（最近：\(m.driftLast.prefix(19))）"), good: true)
            }

            Card(title: "画面层（远程能看到画面）", icon: "display") {
                Row(label: "画面守护 com.yyz.lidawake", value: m.lidwatch == "running" ? "运行中" : "未运行", good: m.lidwatch == "running")
                Row(label: "高清投屏", value: m.hdActive ? "已启用（虚拟屏镜像中）" : "未启用（本机屏幕正常）", good: true)
                Row(label: "本机主屏逻辑分辨率", value: m.mainSize)
                Row(label: "内建屏亮度", value: m.brightness, good: true)
                Row(label: "盖子", value: m.lidClosed ? "已合上" : "已打开", good: true)
                Row(label: "当前投屏预设", value: m.hdPreset, good: true)
            }

            Card(title: "网络（Tailscale）", icon: "network") {
                Row(label: "状态", value: m.tailscale, good: m.tailscale == "Running")
                Row(label: "Tailscale IP", value: m.tsIP, good: !m.tsIP.isEmpty && m.tsIP != "-")
                Row(label: "UU 远程（被控端）", value: m.uuRunning ? "运行中" : "未运行", good: m.uuRunning)
            }

            Card(title: "投屏尺寸（远程画面清晰度）", icon: "rectangle.on.rectangle") {
                Picker("预设", selection: $preset) {
                    Text("1920×1080 @2x（3840×2160 · 16:9 · 推荐）").tag("1920 1080 1 always")
                    Text("1920×1200 @2x（3840×2400 · 16:10）").tag("1920 1200 1 always")
                    Text("2560×1600 @2x（5120×3200 · 更细腻、字更小）").tag("2560 1600 1 always")
                    Text("仅合盖时生效（开盖恢复本机屏）").tag("1920 1080 1 lidonly")
                    Text("关闭高清投屏（只关背光）").tag("off")
                }
                .pickerStyle(.menu)
                .onChange(of: preset) { _, newValue in
                    guard ready else { return }
                    writeHdPreset(newValue)
                    m.toast = "投屏预设已切换，守护正在重启"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { m.refresh() }
                }
            }

            HStack(spacing: 8) {
                Button("开启全部") { m.enableAll() }.keyboardShortcut("e")
                Button("关闭全部") { m.disableAll() }
                Button("重装画面守护") { m.reinstallScreen() }
                Button("刷新") { m.refresh() }
                Spacer()
                Button("打开日志") { NSWorkspace.shared.open(URL(fileURLWithPath: kLogDir)) }
            }
            .buttonStyle(.bordered)
            .disabled(m.busy)

            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(m.toast.isEmpty ? "提示：远程连接时自动切到虚拟屏，断开后自动恢复本机屏幕；合盖时保持不休眠。" : m.toast)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("刷新于 \(m.lastRefresh.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 620)
        .onAppear {
            let c = (try? String(contentsOfFile: kHdConf, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1920 1080 1 always"
            preset = ["1920 1080 1 always", "1920 1200 1 always", "2560 1600 1 always", "1920 1080 1 lidonly", "off"].contains(c) ? c : "1920 1080 1 always"
            if c == "off" { preset = "off" }
            m.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ready = true }
            timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in m.refresh() }
        }
        .onDisappear { timer?.invalidate() }
    }
}

@main
struct KeepAwakeApp: App {
    var body: some Scene {
        WindowGroup("合盖不休眠") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
