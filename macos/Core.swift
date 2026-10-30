// Core.swift — localsocks 客户端的内核：节点存储、配置渲染、shell 探测。
// 使用 Foundation；菜单栏界面由 AppKit 实现。

import Foundation

// MARK: - 节点模型

struct ProxyNode: Codable, Equatable {
    var name: String
    var server: String
    var port: Int
    var password: String
    var sni: String
    var insecure: Bool
    var obfs: String            // none | salamander
    var obfsPassword: String
    var up: String              // "100 mbps"
    var down: String
    var udp: Bool
    var nodeType: String        // 源自订阅里的 type 字段
    var flag: String            // 源自订阅里的 flag 字段

    static let fallback = ProxyNode(
        name: "Example Hysteria2",
        server: "proxy.example.com",
        port: 443,
        password: "CHANGE_ME",
        sni: "proxy.example.com",
        insecure: false,
        obfs: "none",
        obfsPassword: "",
        up: "100 mbps",
        down: "300 mbps",
        udp: true,
        nodeType: "Hysteria2",
        flag: "EXAMPLE"
    )

    var endpoint: String { "\(server):\(port)" }

    var summary: String {
        let tls = insecure ? "insecure" : "verified"
        return "\(nodeType) · \(endpoint) · sni \(sni.isEmpty ? "—" : sni) · \(tls)"
    }
}

struct NodeFile: Codable {
    var selected: String
    var nodes: [ProxyNode]
}

// MARK: - 设置

struct LocalsocksSettings: Codable {
    var localHost: String
    var socksPort: Int
    var httpPort: Int
    var egressURL: String
    var geoURL: String
    var autoRefresh: Bool
    var installMode: String      // 遗留字段，仅为兼容旧配置
    var domainPreference: String?

    static let defaults = LocalsocksSettings(
        localHost: "127.0.0.1",
        socksPort: 10800,
        httpPort: 10801,
        egressURL: "https://api.ipify.org",
        geoURL: "https://ipinfo.io/json",
        autoRefresh: true,
        installMode: "user",
        domainPreference: "user"
    )

    /// 服务装在哪个 launchd 域。默认用户域：免密码，登录后自启，与系统级代理软件同一种做法。
    /// 只有显式选「system」才走 /Library/LaunchDaemons（开机即起，但每次启停要授权）。
    var domainMode: String { domainPreference == "system" ? "system" : "user" }
    var useSystemDomain: Bool { domainMode == "system" }

    var socksProxyURL: String { "socks5h://\(localHost):\(socksPort)" }
}

// MARK: - 路径

enum Paths {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }
    static var configDir: URL { home.appendingPathComponent(".config/localsocks", isDirectory: true) }
    static var nodesFile: URL { configDir.appendingPathComponent("nodes.json") }
    static var settingsFile: URL { configDir.appendingPathComponent("settings.json") }

    /// 项目目录：优先环境变量，其次 UserDefaults，最后 ~/Projects/localsocks
    static var projectDir: URL {
        let env = ProcessInfo.processInfo.environment["LOCALSOCKS_DIR"]
        if let env, !env.isEmpty { return URL(fileURLWithPath: env) }
        if let stored = UserDefaults.standard.string(forKey: "projectDir"), !stored.isEmpty {
            return URL(fileURLWithPath: stored)
        }
        return home.appendingPathComponent("Projects/localsocks", isDirectory: true)
    }

    static func setProjectDir(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "projectDir")
    }

    static var clientConfig: URL { projectDir.appendingPathComponent("hysteria2-client.yaml") }
    static var logsDir: URL { projectDir.appendingPathComponent("logs", isDirectory: true) }
    static var daemonLog: URL { logsDir.appendingPathComponent("hysteria2.log") }
    static var hysteriaBin: URL { projectDir.appendingPathComponent("bin/hysteria") }
}

// MARK: - 节点 + 设置存储

enum Store {
    static func ensureDir() {
        try? FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
    }

    static func loadNodeFile() -> NodeFile {
        ensureDir()
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Paths.nodesFile),
           let file = try? decoder.decode(NodeFile.self, from: data), !file.nodes.isEmpty {
            return file
        }
        // 首次运行：从项目里的 nodes.json 播种，否则用内置节点
        let projectNodes = Paths.projectDir.appendingPathComponent("nodes.json")
        if let data = try? Data(contentsOf: projectNodes),
           let file = try? decoder.decode(NodeFile.self, from: data), !file.nodes.isEmpty {
            saveNodeFile(file)
            return file
        }
        let seeded = NodeFile(selected: ProxyNode.fallback.name, nodes: [ProxyNode.fallback])
        saveNodeFile(seeded)
        return seeded
    }

    static func saveNodeFile(_ file: NodeFile) {
        ensureDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(file) { try? data.write(to: Paths.nodesFile) }
    }

    static func loadSettings() -> LocalsocksSettings {
        ensureDir()
        if let data = try? Data(contentsOf: Paths.settingsFile),
           var s = try? JSONDecoder().decode(LocalsocksSettings.self, from: data) {
            // 旧版本默认装在系统域，导致每次启停都弹管理员授权。
            // 这里一次性迁移到用户域（遗留的系统域安装由界面上一键清理）。
            if s.domainPreference == nil {
                s.domainPreference = "user"
                saveSettings(s)
            }
            return s
        }
        var initial = LocalsocksSettings.defaults
        if let mode = ProcessInfo.processInfo.environment["LOCALSOCKS_DOMAIN_MODE"], !mode.isEmpty {
            initial.domainPreference = mode
        }
        saveSettings(initial)
        return initial
    }

    static func saveSettings(_ s: LocalsocksSettings) {
        ensureDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(s) { try? data.write(to: Paths.settingsFile) }
    }

    static func selectedNode(_ file: NodeFile) -> ProxyNode {
        file.nodes.first { $0.name == file.selected } ?? file.nodes.first ?? .fallback
    }
}

// MARK: - 配置渲染

enum ConfigWriter {
    /// 生成与 hysteria2-client.yaml 结构一致的客户端配置
    static func render(node: ProxyNode, settings: LocalsocksSettings) -> String {
        var lines: [String] = []
        lines.append("# 由 localsocks 客户端生成 — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("# 节点：\(node.name)  (\(node.nodeType))")
        lines.append("")
        lines.append("server: \(node.endpoint)")
        lines.append("auth: \(node.password)")
        lines.append("")
        lines.append("tls:")
        lines.append("  sni: \(node.sni.isEmpty ? node.server : node.sni)")
        lines.append("  insecure: \(node.insecure ? "true" : "false")")
        lines.append("")
        if node.obfs.lowercased() == "salamander" && !node.obfsPassword.isEmpty {
            lines.append("obfs:")
            lines.append("  type: salamander")
            lines.append("  salamander:")
            lines.append("    password: \(node.obfsPassword)")
            lines.append("")
        }
        lines.append("bandwidth:")
        lines.append("  up: \(node.up.isEmpty ? "100 mbps" : node.up)")
        lines.append("  down: \(node.down.isEmpty ? "300 mbps" : node.down)")
        lines.append("")
        lines.append("quic:")
        lines.append("  initStreamReceiveWindow: 8388608")
        lines.append("  maxStreamReceiveWindow: 8388608")
        lines.append("  initConnReceiveWindow: 20971520")
        lines.append("  maxConnReceiveWindow: 20971520")
        lines.append("  keepAlivePeriod: 10s")
        lines.append("  disablePathMTUDiscovery: false")
        lines.append("")
        lines.append("fastOpen: true")
        lines.append("lazy: true")
        lines.append("")
        lines.append("socks5:")
        lines.append("  listen: \(settings.localHost):\(settings.socksPort)")
        lines.append("  disableUDP: \(node.udp ? "false" : "true")")
        lines.append("  udpFragmentSize: 1400")
        lines.append("")
        lines.append("http:")
        lines.append("  listen: \(settings.localHost):\(settings.httpPort)")
        lines.append("  disableUDP: \(node.udp ? "false" : "true")")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    @discardableResult
    static func write(node: ProxyNode, settings: LocalsocksSettings) -> Result<URL, Error> {
        let text = render(node: node, settings: settings)
        do {
            // 先备份，写入失败也不会毁掉可用配置
            let dest = Paths.clientConfig
            if FileManager.default.fileExists(atPath: dest.path) {
                let backup = dest.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: dest, to: backup)
            }
            try text.write(to: dest, atomically: true, encoding: .utf8)
            return .success(dest)
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - shell 执行

enum Shell {
    struct Result {
        var code: Int32
        var output: String
        var ok: Bool { code == 0 }
        var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func capture(_ process: Process, timeout: TimeInterval) -> Result {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let handle = pipe.fileHandleForReading

        var data = Data()
        let lock = NSLock()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let chunk = handle.readDataToEndOfFile()
            lock.lock(); data.append(chunk); lock.unlock()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            return Result(code: -1, output: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = group.wait(timeout: .now() + 2)
            return Result(code: -2, output: "timeout after \(Int(timeout))s")
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        lock.lock(); let text = String(data: data, encoding: .utf8) ?? ""; lock.unlock()
        return Result(code: process.terminationStatus, output: text)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        return capture(process, timeout: timeout)
    }

    /// 通过 osascript 提权执行（系统级 launchctl 需要 root）
    @discardableResult
    static func runAdmin(_ command: String) -> Result {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script], timeout: 90)
    }

    /// launchd 服务需要的最小 PATH；GUI 应用默认环境里没有 /opt/homebrew/bin
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
}

// MARK: - 探测

struct EgressReport {
    var ok: Bool
    var ip: String
    var latencyMS: Double?
    var geo: String
    var error: String
}

struct DirectReport {
    var ok: Bool
    var ip: String
    var latencyMS: Double?
}

enum Probe {
    static func tcpOpen(host: String, port: Int, timeout: TimeInterval = 3) -> Bool {
        let r = Shell.run("/usr/bin/nc", ["-z", "-G", "\(Int(timeout))", host, "\(port)"], timeout: timeout + 2)
        // nc 的 -z 只报告连接结果；部分版本在成功时返回 0
        if r.code == 0 { return true }
        return false
    }

    /// curl 失败时 -w 的输出会跟着 stderr 一起进来，只保留第一行真实错误
    private static func cleanError(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && Double($0) == nil }
        return lines.first ?? "curl 失败（无输出）"
    }

    /// 通过本地 SOCKS5 走一次真实请求，同时测延迟
    static func egress(settings: LocalsocksSettings) -> EgressReport {
        let r = Shell.run("/usr/bin/curl", [
            "--silent", "--show-error", "--fail",
            "--proxy", settings.socksProxyURL,
            "--max-time", "15",
            "--write-out", "\n%{time_total}",
            settings.egressURL
        ], timeout: 20)

        guard r.ok else {
            return EgressReport(ok: false, ip: "", latencyMS: nil, geo: "",
                                error: r.trimmed.isEmpty ? "curl exit \(r.code)" : cleanError(r.output))
        }
        let parts = r.output.components(separatedBy: "\n")
        let ip = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var ms: Double?
        if parts.count >= 2, let seconds = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            ms = seconds * 1000
        }
        return EgressReport(ok: !ip.isEmpty, ip: ip, latencyMS: ms, geo: "",
                            error: ip.isEmpty ? "出口返回空响应" : "")
    }

    static func geo(settings: LocalsocksSettings) -> String {
        guard !settings.geoURL.isEmpty else { return "" }
        let r = Shell.run("/usr/bin/curl", [
            "--silent", "--show-error", "--fail",
            "--proxy", settings.socksProxyURL,
            "--max-time", "10",
            settings.geoURL
        ], timeout: 15)
        guard r.ok, let data = r.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let city = object["city"] as? String ?? ""
        let country = object["country"] as? String ?? ""
        let org = object["org"] as? String ?? ""
        let pieces = [city, country, org].filter { !$0.isEmpty }
        return pieces.joined(separator: " · ")
    }

    static func direct(settings: LocalsocksSettings) -> DirectReport {
        let r = Shell.run("/usr/bin/curl", [
            "--silent", "--show-error", "--fail",
            "--max-time", "8",
            "--write-out", "\n%{time_total}",
            settings.egressURL
        ], timeout: 12)
        guard r.ok else { return DirectReport(ok: false, ip: "", latencyMS: nil) }
        let parts = r.output.components(separatedBy: "\n")
        let ip = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var ms: Double?
        if parts.count >= 2, let seconds = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            ms = seconds * 1000
        }
        return DirectReport(ok: !ip.isEmpty, ip: ip, latencyMS: ms)
    }

    static func ping(host: String, count: Int = 4, timeout: TimeInterval = 8) -> String {
        let r = Shell.run("/sbin/ping", ["-c", "\(count)", "-t", "\(Int(timeout))", host], timeout: timeout + 3)
        let line = r.output.components(separatedBy: "\n").first { $0.contains("avg") }
            ?? r.output.components(separatedBy: "\n").first { $0.contains("min/avg") }
        return (line ?? r.trimmed).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - launchd 服务控制

enum ServiceDomain {
    case system
    case user
    case notInstalled
}

struct ServiceStatus {
    var domain: ServiceDomain
    var running: Bool
    var detail: String
}

enum Service {
    static let label = "com.localsocks.hysteria2"

    static var systemPlistPath: String { "/Library/LaunchDaemons/\(label).plist" }
    static var userPlistPath: String { "\(NSHomeDirectory())/Library/LaunchAgents/\(label).plist" }

    static var uid: String { String(getuid()) }

    static func domainTarget(_ domain: ServiceDomain) -> String {
        switch domain {
        case .system: return "system/\(label)"
        case .user: return "gui/\(uid)/\(label)"
        case .notInstalled: return "system/\(label)"
        }
    }

    /// 用哪个域启停：**用户域优先**。
    /// 本代理监听的是 127.0.0.1，本来只服务当前用户；LaunchDaemon（系统域）除了每次启停
    /// 都要管理员授权之外没有任何好处，所以只在用户显式选择时才用。
    static func activeDomain(settings: LocalsocksSettings) -> ServiceDomain {
        if settings.useSystemDomain { return systemInstalled() ? .system : .notInstalled }
        if userInstalled() { return .user }
        return .notInstalled
    }

    static func userInstalled() -> Bool { FileManager.default.fileExists(atPath: userPlistPath) }
    static func systemInstalled() -> Bool { FileManager.default.fileExists(atPath: systemPlistPath) }

    /// 以前装过系统域、但当前偏好是用户域：不需要密码也能干活，只是有个遗留文件
    static func hasSystemLeftover(settings: LocalsocksSettings) -> Bool {
        !settings.useSystemDomain && systemInstalled() && !userInstalled()
    }

    static func status(settings: LocalsocksSettings) -> ServiceStatus {
        let domain = activeDomain(settings: settings)
        guard domain != .notInstalled else {
            let leftover = hasSystemLeftover(settings: settings) ? "（有系统域遗留安装）" : ""
            return ServiceStatus(domain: .notInstalled, running: false, detail: "未安装\(leftover)")
        }
        let target = domainTarget(domain)
        let r = Shell.run("/bin/launchctl", ["print", target], timeout: 8)
        let running = r.ok && r.output.contains("state = running")
        // launchctl print 在非 root 读 system 域时可能失败，此时用端口兜底
        if !r.ok {
            let open = Probe.tcpOpen(host: settings.localHost, port: settings.socksPort, timeout: 2)
            return ServiceStatus(domain: domain, running: open,
                                 detail: open ? "运行中（端口探测）" : "未运行")
        }
        return ServiceStatus(domain: domain, running: running,
                             detail: running ? "运行中" : "已停止")
    }

    private static func needsAdmin(_ domain: ServiceDomain) -> Bool { domain == .system }

    private static func execute(_ args: [String], domain: ServiceDomain, settings: LocalsocksSettings) -> Shell.Result {
        let command = "/bin/launchctl " + args.map { shellQuote($0) }.joined(separator: " ")
        if needsAdmin(domain) {
            return Shell.runAdmin(command)
        }
        return Shell.run("/bin/launchctl", args, timeout: 30)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func start(settings: LocalsocksSettings) -> String {
        let domain = activeDomain(settings: settings)
        switch domain {
        case .notInstalled:
            return install(mode: settings.domainMode, settings: settings)
        case .system:
            // enable：取消之前「关闭」时写下的禁用标记，否则重启后依然不会自启
            _ = execute(["enable", domainTarget(.system)], domain: .system, settings: settings)
            var out = execute(["bootstrap", "system", systemPlistPath], domain: .system, settings: settings).trimmed
            let kick = execute(["kickstart", "-k", domainTarget(.system)], domain: .system, settings: settings)
            out += kick.trimmed.isEmpty ? "" : " / \(kick.trimmed)"
            return "已开启（系统域，需授权）\(out.isEmpty ? "" : " · \(out)")"
        case .user:
            _ = execute(["enable", domainTarget(.user)], domain: .user, settings: settings)
            var out = execute(["bootstrap", "gui/\(uid)", userPlistPath], domain: .user, settings: settings).trimmed
            let kick = execute(["kickstart", "-k", domainTarget(.user)], domain: .user, settings: settings)
            out += kick.trimmed.isEmpty ? "" : " / \(kick.trimmed)"
            return "已开启（用户域，免密码）\(out.isEmpty ? "" : " · \(out)")"
        }
    }

    /// 切换安装域：把旧域的安装清掉、装到新域、再启动。
    /// 切到用户域时，清理系统域遗留需要一次管理员授权；之后启停就再也不用密码了。
    static func applyDomain(_ mode: String, settings: LocalsocksSettings) -> String {
        var log: [String] = []
        if mode == "user" {
            if userInstalled() {
                // 已经在用户域
            } else {
                if systemInstalled() {
                    let removal = uninstall(mode: "system", settings: settings)
                    log.append("清理系统域：\(removal)")
                }
                log.append(install(mode: "user", settings: settings))
            }
            log.append(start(settings: settings))
        } else {
            if !systemInstalled() {
                if userInstalled() { log.append(uninstall(mode: "user", settings: settings)) }
                log.append(install(mode: "system", settings: settings))
            } else {
                log.append(start(settings: settings))
            }
        }
        return log.joined(separator: " / ")
    }

    /// 关闭 = 从 launchd 卸下 + 写禁用标记，否则 KeepAlive 会把它拉回来、重启后也会自启
    static func stop(settings: LocalsocksSettings) -> String {
        let domain = activeDomain(settings: settings)
        guard domain != .notInstalled else { return "本地 SOCKS 代理本来就未安装" }
        let target = domainTarget(domain)
        let out = execute(["bootout", target], domain: domain, settings: settings)
        let dis = execute(["disable", target], domain: domain, settings: settings)
        if out.ok || dis.ok {
            return "已关闭（端口释放，不会随开机自启）"
        }
        return "关闭失败：\(out.trimmed.isEmpty ? dis.trimmed : out.trimmed)"
    }

    static func restart(settings: LocalsocksSettings) -> String {
        let domain = activeDomain(settings: settings)
        guard domain != .notInstalled else { return install(mode: settings.domainMode, settings: settings) }
        let r = execute(["kickstart", "-k", domainTarget(domain)], domain: domain, settings: settings)
        return r.ok ? "已重启" : "重启失败：\(r.trimmed)"
    }

    static func install(mode: String, settings: LocalsocksSettings) -> String {
        let script = Paths.projectDir.appendingPathComponent("install.sh").path
        guard FileManager.default.fileExists(atPath: script) else {
            return "找不到 \(script)"
        }
        // 先 enable：关掉时写的 disable 标记会让 bootstrap 报 "Bootstrap failed: 5"
        let target = mode == "system" ? domainTarget(.system) : domainTarget(.user)
        let enable = "/bin/launchctl enable \(shellQuote(target)); "
        let command = enable + "/bin/bash \(shellQuote(script)) \(shellQuote(mode))"
        let r = mode == "system"
            ? Shell.runAdmin(command)                                  // 系统域：一次授权
            : Shell.run("/bin/bash", ["-c", command], timeout: 60)     // 用户域：免密码
        return r.ok ? "已安装为\(mode == "system" ? "系统域（开机即起）" : "用户域（免密码）")服务" : "安装失败：\(r.trimmed)"
    }

    static func uninstall(mode: String, settings: LocalsocksSettings) -> String {
        let script = Paths.projectDir.appendingPathComponent("install.sh").path
        guard FileManager.default.fileExists(atPath: script) else { return "找不到 \(script)" }
        // bootout 后把 disable 标记也清掉，否则下次 bootstrap 会被它挡住
        let target = mode == "system" ? domainTarget(.system) : domainTarget(.user)
        let enable = "/bin/launchctl enable \(shellQuote(target)); "
        let command = "/bin/bash \(shellQuote(script)) uninstall \(shellQuote(mode)); " + enable
        let r = mode == "system"
            ? Shell.runAdmin(command)
            : Shell.run("/bin/bash", ["-c", command], timeout: 60)
        return r.ok ? "已卸载（\(mode)）" : "卸载失败：\(r.trimmed)"
    }
}

// MARK: - 隧道日志诊断
//
// hysteria 的 lazy + socks5 模式会先把监听端口打开，即使到服务端的 QUIC 握手
// 一直失败。因此“端口在监听”并不等于“链路可用”，这里从守护日志里给出旁证。

enum TunnelLog {
    struct Summary {
        var healthy: Bool
        var fatal: Bool
        var detail: String
    }

    private static let fatalMarkers = [
        "authentication failed",
        "failed to authenticate",
        "invalid password",
        "no such user"
    ]

    private static let transportMarkers = [
        "no recent network activity",
        "connect error",
        "failed to connect",
        "connection attempt failed"
    ]

    static func inspect(logFile: URL, tailLines: Int = 300) -> Summary {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else {
            return Summary(healthy: false, fatal: false, detail: "无日志（服务可能未启动）")
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""

        var all = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // 只看当前这一次会话：daemon.sh 每次尝试前都会写 "launching client"
        // （手动 ./run.sh 启动时没有这行，那就看全部）
        if let last = all.lastIndex(where: { $0.contains("launching client") }), last + 1 < all.count {
            all = Array(all[(last + 1)...])
        }
        let lines = all.suffix(tailLines)

        var fatalLine: String?
        var transportLine: String?
        for line in lines {
            let lowered = line.lowercased()
            if fatalMarkers.contains(where: { lowered.contains($0) }) { fatalLine = line }
            else if transportMarkers.contains(where: { lowered.contains($0) }) { transportLine = line }
        }

        if let fatalLine {
            return Summary(healthy: false, fatal: true, detail: "认证失败 · \(clip(fatalLine))")
        }
        if let transportLine {
            return Summary(healthy: false, fatal: false,
                           detail: "QUIC/UDP 无响应 · \(clip(transportLine))")
        }
        return Summary(healthy: true, fatal: false, detail: "日志无握手错误")
    }

    private static func clip(_ line: String) -> String {
        var s = line.replacingOccurrences(of: "(\u{1b})?\\[[0-9;]*m", with: "", options: .regularExpression)
        // hysteria 的日志是“时间\t级别\t消息”，去掉前半段只留消息
        if let tab = s.firstIndex(of: "\t") { s = String(s[s.index(after: tab)...]) }
        s = s.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        return s.count > 120 ? String(s.prefix(120)) + "…" : s
    }
}

// MARK: - 系统代理（参考项目没有的能力）

enum SystemProxy {
    static func services() -> [String] {
        let r = Shell.run("/usr/sbin/networksetup", ["-listallnetworkservices"], timeout: 10)
        guard r.ok else { return [] }
        return r.output
            .components(separatedBy: .newlines)
            .dropFirst()                                  // 第一行是说明文字
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }  // 星号表示已停用的服务
    }

    static func state(service: String) -> (enabled: Bool, host: String, port: Int)? {
        let r = Shell.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service], timeout: 10)
        guard r.ok else { return nil }
        var enabled = false
        var host = ""
        var port = 0
        for line in r.output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Enabled": enabled = value.lowercased() == "yes"
            case "Server": host = value
            case "Port": port = Int(value) ?? 0
            default: break
            }
        }
        return (enabled, host, port)
    }

    /// 开关系统 SOCKS 代理。
    ///
    /// 注意 networksetup 的两个坑：
    ///   1. `-setsocksfirewallproxy <svc> <host> <port> [authenticated]` 的第 4 个参数是
    ///      “是否需要认证”，不是 on/off。把 off 传在那里等于什么都不做，而代理已经被设成开启。
    ///   2. 真正开关要用 `-setsocksfirewallproxystate <svc> on|off`。
    /// 两者都不需要 root（实测 exit=0）。
    @discardableResult
    static func set(service: String, host: String, port: Int, enabled: Bool) -> String {
        let write = Shell.run("/usr/sbin/networksetup",
                              ["-setsocksfirewallproxy", service, host, "\(port)", "off"], timeout: 15)
        guard write.ok else { return "设置失败：\(write.trimmed)" }
        let toggle = Shell.run("/usr/sbin/networksetup",
                               ["-setsocksfirewallproxystate", service, enabled ? "on" : "off"], timeout: 15)
        guard toggle.ok else { return "切换失败：\(toggle.trimmed)" }
        return "\(enabled ? "已开启" : "已关闭") \(service) 的系统 SOCKS 代理"
    }

    /// 关闭时 networksetup 仍要求 server/port 参数，沿用当前值或本地默认值
    static func disable(service: String, fallbackHost: String = "127.0.0.1", fallbackPort: Int = 10800) -> String {
        let current = state(service: service)
        return set(service: service,
                   host: current?.host.isEmpty == false ? current!.host : fallbackHost,
                   port: (current?.port ?? 0) > 0 ? current!.port : fallbackPort,
                   enabled: false)
    }
}
