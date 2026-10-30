// LocalsocksApp.swift — localsocks 菜单栏客户端
//
// 参考 ChatGPTWayApp.swift 的结构（AppKit + 单文件 app delegate + launchctl 管理），
// 额外补上参考项目没有的三件事：
//   1. 出口延迟测量（curl %{time_total}）与地区信息；
//   2. 多节点切换，自动重写 hysteria2-client.yaml；
//   3. 一键开关 macOS 系统 SOCKS 代理（networksetup）。

import AppKit

// MARK: - 健康指示灯

enum HealthLevel {
    case unknown, healthy, warning, failed

    var color: NSColor {
        switch self {
        case .unknown: return .tertiaryLabelColor
        case .healthy: return NSColor(calibratedRed: 0.15, green: 0.68, blue: 0.55, alpha: 1)
        case .warning: return NSColor(calibratedRed: 0.92, green: 0.62, blue: 0.10, alpha: 1)
        case .failed: return NSColor(calibratedRed: 0.84, green: 0.22, blue: 0.24, alpha: 1)
        }
    }
}

private final class HealthRow: NSStackView {
    private let light = NSImageView()
    private let detailLabel: NSTextField

    init(title: String) {
        detailLabel = NSTextField(labelWithString: "检查中…")
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8

        light.image = Self.dotImage(color: .tertiaryLabelColor, size: 10)
        light.imageScaling = .scaleProportionallyUpOrDown
        light.translatesAutoresizingMaskIntoConstraints = false
        light.widthAnchor.constraint(equalToConstant: 10).isActive = true
        light.heightAnchor.constraint(equalToConstant: 10).isActive = true
        addArrangedSubview(light)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        addArrangedSubview(titleLabel)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        addArrangedSubview(detailLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(level: HealthLevel, detail: String) {
        light.image = Self.dotImage(color: level.color, size: 10)
        detailLabel.stringValue = detail
    }

    private static func dotImage(color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        image.unlockFocus()
        return image
    }
}

// MARK: - 图标

enum LocalsocksLogo {
    static let deep = NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.42, alpha: 1)
    static let teal = NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.58, alpha: 1)
    static let mint = NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.78, alpha: 1)

    /// 三个端点 + 一条本地回环弧线：表示“本机出口经过远端节点”
    static func image(size: CGFloat, tint: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocusFlipped(false)
        let s = size

        if tint == nil {
            let card = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
            let path = NSBezierPath(roundedRect: card, xRadius: s * 0.25, yRadius: s * 0.25)
            NSGradient(starting: deep, ending: teal)?.draw(in: path, angle: -35)
        }

        let stroke = tint ?? mint
        let route = NSBezierPath()
        route.lineWidth = max(1.4, s * 0.085)
        route.lineCapStyle = .round
        route.move(to: NSPoint(x: s * 0.20, y: s * 0.30))
        route.curve(to: NSPoint(x: s * 0.80, y: s * 0.70),
                    controlPoint1: NSPoint(x: s * 0.50, y: s * 0.12),
                    controlPoint2: NSPoint(x: s * 0.50, y: s * 0.88))
        stroke.setStroke()
        route.stroke()

        let nodes = [NSPoint(x: s * 0.20, y: s * 0.30),
                     NSPoint(x: s * 0.50, y: s * 0.50),
                     NSPoint(x: s * 0.80, y: s * 0.70)]
        for (index, point) in nodes.enumerated() {
            let dotSize = s * (index == 1 ? 0.15 : 0.20)
            let dot = NSBezierPath(ovalIn: NSRect(x: point.x - dotSize / 2, y: point.y - dotSize / 2,
                                                  width: dotSize, height: dotSize))
            (tint == nil ? NSColor.white : tint!).setFill()
            dot.fill()
            stroke.setStroke()
            dot.lineWidth = max(0.8, s * 0.04)
            dot.stroke()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

// MARK: - 分栏页面容器

/// NSTabViewController 需要的是 NSViewController，这里把已经搭好的 NSView 直接当成页面
private final class PageViewController: NSViewController {
    private let page: NSView

    init(page: NSView) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = page }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var socksItem: NSMenuItem!
    private var egressItem: NSMenuItem!
    private var serviceItem: NSMenuItem!
    private var autoProbeItem: NSMenuItem!
    private var testItem: NSMenuItem!
    private var sysProxyMenu: NSMenu!

    private var controlWindow: NSWindow!
    private var nodePopup: NSPopUpButton!
    private var endpointLabel: NSTextField!
    private var serviceLabel: NSTextField!
    private var nodeSummaryLabel: NSTextField!
    private var resultLabel: NSTextField!
    private var healthCheckLabel: NSTextField!
    private var healthRows: [String: HealthRow] = [:]

    // 本地 SOCKS 代理的独立开关
    private var proxySwitch: NSSwitch!
    private var proxyStateLabel: NSTextField!
    private var proxyPill: NSTextField!
    private var proxyToggleItem: NSMenuItem!
    private var sysProxySwitch: NSSwitch!
    private var sysProxyServiceLabel: NSTextField!
    private var domainLabel: NSTextField!
    private var proxyToggling = false

    // 分栏页面里的控件
    private var autoProbeSwitch: NSSwitch!
    private var nodeDetailFields: [String: NSTextField] = [:]
    private var projectPathLabel: NSTextField!

    private var nodeFile = Store.loadNodeFile()
    private var settings = Store.loadSettings()

    private var refreshTimer: Timer?
    private var probeTimer: Timer?
    private var lastEgress = EgressReport(ok: false, ip: "", latencyMS: nil, geo: "", error: "尚未检测")
    private var probing = false

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        let trace = ProcessInfo.processInfo.environment["LOCALSOCKS_UI_SELFTEST"] == "1"
            ? (ProcessInfo.processInfo.environment["LOCALSOCKS_UI_SELFTEST_OUT"] ?? "/tmp/localsocks-ui-selftest.txt") + ".trace"
            : nil
        func mark(_ step: String) {
            guard let trace else { return }
            let line = "\(Date().timeIntervalSince1970) \(step)\n"
            if let handle = FileHandle(forWritingAtPath: trace) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: trace, atomically: true, encoding: .utf8)
            }
        }

        mark("start")
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        mark("menu")
        buildControlWindow()
        mark("window")
        refreshStatus()
        mark("refresh")
        performProbe()
        mark("probe")
        openControlPanel()
        mark("panel")

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        probeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.settings.autoRefresh else { return }
            self.performProbe()
        }

        if trace != nil {
            runUISelfTest()
            mark("selftest-done")
        }
    }

    /// 无头自检：把分栏结构写成文本，用来验证界面真的搭起来了（不依赖肉眼）
    private func runUISelfTest() {
        let out = ProcessInfo.processInfo.environment["LOCALSOCKS_UI_SELFTEST_OUT"] ?? "/tmp/localsocks-ui-selftest.txt"
        try? dumpUI().write(toFile: out, atomically: true, encoding: .utf8)
        // 等一轮异步探测（launchctl + curl）跑完，再看状态是否真的被回填
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [weak self] in
            guard let self else { return }
            try? self.dumpUI().write(toFile: out + ".late", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private func dumpUI() -> String {
        var lines: [String] = []
        lines.append("window.title=\(controlWindow.title) frame=\(controlWindow.frame)")
        lines.append("window.subtitle=\(controlWindow.subtitle)")
        lines.append("window.toolbar=\(controlWindow.toolbar?.identifier ?? "nil") items=\(controlWindow.toolbar?.items.count ?? -1)")
        if let tabs = controlWindow.contentViewController as? NSTabViewController {
            lines.append("tabStyle=\(tabs.tabStyle.rawValue) tabs=\(tabs.tabViewItems.count) preferred=\(tabs.preferredContentSize)")
            for (index, item) in tabs.tabViewItems.enumerated() {
                let pageSize = item.view?.frame.size ?? .zero
                let subviews = item.view?.subviews.count ?? -1
                lines.append("  [\(index)] label=\(item.label) image=\(item.image == nil ? "nil" : "ok") size=\(pageSize) subviews=\(subviews)")
            }
        } else {
            lines.append("ERROR contentViewController is not NSTabViewController")
        }
        lines.append("proxyPill=\(proxyPill?.stringValue ?? "nil") width=\(proxyPill.map { "\($0.frame.width)" } ?? "-") color=\(proxyPill?.textColor?.description ?? "-")")
        lines.append("proxySwitch=\(proxySwitch?.state.rawValue ?? -1) enabled=\(proxySwitch?.isEnabled ?? false)")
        lines.append("proxyState=\(proxyStateLabel?.stringValue ?? "nil")")
        lines.append("menuToggle=\(proxyToggleItem?.title ?? "nil") state=\(proxyToggleItem?.state.rawValue ?? -1)")
        for key in ["listener", "service", "egress", "tunnel", "direct"] {
            let row = healthRows[key]
            let detail = (row?.arrangedSubviews.last as? NSTextField)?.stringValue ?? "?"
            lines.append("health[\(key)]=\(detail)")
        }
        lines.append("nodeDetails=\(nodeDetailFields.count) nodePopupItems=\(nodePopup?.numberOfItems ?? -1) summary=\(nodeSummaryLabel?.stringValue ?? "-")")
        lines.append("resultLabel=\(resultLabel?.stringValue ?? "-")")
        lines.append("domainLabel=\((domainLabel?.stringValue ?? "nil").replacingOccurrences(of: "\n", with: " | "))")
        lines.append("domainMode=\(settings.domainMode) systemLeftover=\(Service.hasSystemLeftover(settings: settings))")
        lines.append("autoProbe=\(autoProbeSwitch?.state.rawValue ?? -1) serviceLabel=\(serviceLabel?.stringValue ?? "-")")
        return lines.joined(separator: "\n")
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        probeTimer?.invalidate()
    }

    // MARK: 菜单

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = LocalsocksLogo.image(size: 18)
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.toolTip = "localsocks 代理"

        statusMenu = NSMenu()
        statusMenu.delegate = self
        let title = NSMenuItem(title: "localsocks 代理", action: nil, keyEquivalent: "")
        title.isEnabled = false
        statusMenu.addItem(title)
        addAction("打开控制面板", #selector(openControlPanel))
        statusMenu.addItem(.separator())

        // —— 本地 SOCKS 代理：唯一的总开关，单独一段
        proxyToggleItem = NSMenuItem(title: "开启本地 SOCKS 代理",
                                     action: #selector(toggleLocalProxyFromMenu),
                                     keyEquivalent: "p")
        proxyToggleItem.target = self
        statusMenu.addItem(proxyToggleItem)
        socksItem = disabled("SOCKS5 \(settings.localHost):\(settings.socksPort)")
        statusMenu.addItem(socksItem)
        egressItem = disabled("出口：尚未检测")
        statusMenu.addItem(egressItem)
        serviceItem = disabled("服务：检查中…")
        statusMenu.addItem(serviceItem)
        statusMenu.addItem(.separator())

        // —— 以下都是其他功能
        statusMenu.addItem(disabled("其他功能"))
        addAction("重启代理进程", #selector(restartService))

        testItem = NSMenuItem(title: "测试出口", action: #selector(testEgress), keyEquivalent: "t")
        testItem.target = self
        statusMenu.addItem(testItem)

        autoProbeItem = NSMenuItem(title: "自动探测", action: #selector(toggleAutoProbe), keyEquivalent: "")
        autoProbeItem.target = self
        autoProbeItem.state = settings.autoRefresh ? .on : .off
        statusMenu.addItem(autoProbeItem)

        let pingItem = NSMenuItem(title: "Ping 节点", action: #selector(pingNode), keyEquivalent: "")
        pingItem.target = self
        statusMenu.addItem(pingItem)
        statusMenu.addItem(.separator())

        let copyItem = NSMenuItem(title: "复制代理环境变量", action: #selector(copyProxyEnv), keyEquivalent: "c")
        copyItem.target = self
        statusMenu.addItem(copyItem)

        let sysItem = NSMenuItem(title: "macOS 系统代理（按网络服务）", action: nil, keyEquivalent: "")
        sysProxyMenu = NSMenu()
        sysItem.submenu = sysProxyMenu
        statusMenu.addItem(sysItem)
        statusMenu.addItem(.separator())

        addAction("打开客户端配置", #selector(openClientConfig))
        addAction("打开节点文件", #selector(openNodeFile))
        addAction("打开日志目录", #selector(openLogs))
        addAction("选择项目目录…", #selector(chooseProjectDir))
        statusMenu.addItem(.separator())
        addAction("退出", #selector(quit))
        statusItem.menu = statusMenu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func addAction(_ title: String, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        statusMenu.addItem(item)
    }

    /// 打开菜单时刷新动态内容（节点列表、网络服务列表、当前状态）
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        rebuildSystemProxyMenu()
        refreshStatus()
    }

    private func rebuildSystemProxyMenu() {
        sysProxyMenu.removeAllItems()
        let header = disabled("本机 \(settings.localHost):\(settings.socksPort)")
        sysProxyMenu.addItem(header)
        sysProxyMenu.addItem(.separator())

        let services = SystemProxy.services()
        if services.isEmpty {
            sysProxyMenu.addItem(disabled("未找到网络服务"))
            return
        }
        for service in services {
            let state = SystemProxy.state(service: service)
            let on = state?.enabled == true
                && state?.host == settings.localHost
                && state?.port == settings.socksPort
            let item = NSMenuItem(title: service, action: #selector(toggleSystemProxy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = service
            item.state = on ? .on : .off
            sysProxyMenu.addItem(item)
        }
    }

    // MARK: 控制面板

    private func buildControlWindow() {
        controlWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        controlWindow.title = "localsocks"
        controlWindow.subtitle = "正在检查…"
        controlWindow.isReleasedWhenClosed = false
        controlWindow.toolbarStyle = .preference        // System Settings 那种圆角工具栏
        controlWindow.center()

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar                        // 分栏显示在窗口顶部
        tabs.addTabViewItem(tabItem("代理", symbol: "power", page: buildProxyPage()))
        tabs.addTabViewItem(tabItem("节点", symbol: "globe", page: buildNodePage()))
        tabs.addTabViewItem(tabItem("诊断", symbol: "waveform.path.ecg", page: buildDiagnosticsPage()))
        tabs.addTabViewItem(tabItem("维护", symbol: "gearshape", page: buildMaintenancePage()))
        tabs.preferredContentSize = NSSize(width: 640, height: 560)
        controlWindow.contentViewController = tabs
        controlWindow.setContentSize(NSSize(width: 640, height: 560))
        controlWindow.minSize = NSSize(width: 560, height: 420)
    }

    // MARK: 分栏页面

    private func buildProxyPage() -> NSView {
        proxySwitch = NSSwitch()
        proxySwitch.target = self
        proxySwitch.action = #selector(toggleLocalProxy)
        proxySwitch.translatesAutoresizingMaskIntoConstraints = false
        proxySwitch.controlSize = .large

        let switchTitle = NSTextField(labelWithString: "本地 SOCKS 代理")
        switchTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        proxyPill = pill("检查中", color: .tertiaryLabelColor)

        let header = NSStackView(views: [proxySwitch, switchTitle, proxyPill])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        proxyStateLabel = NSTextField(labelWithString: "检查中…")
        proxyStateLabel.textColor = .secondaryLabelColor
        proxyStateLabel.font = .systemFont(ofSize: 11.5)

        endpointLabel = NSTextField(labelWithString: "入口  SOCKS5 \(settings.localHost):\(settings.socksPort)  ·  HTTP \(settings.httpPort)")
        endpointLabel.textColor = .tertiaryLabelColor
        endpointLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

        let actionRow = NSStackView(views: [
            button("重启代理进程", #selector(restartService)),
            hint("关掉即释放端口并停掉重连")
        ])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 12

        let powerCard = card([header, proxyStateLabel, endpointLabel, divider(), actionRow])

        sysProxySwitch = NSSwitch()
        sysProxySwitch.target = self
        sysProxySwitch.action = #selector(toggleAttachedSystemProxy)
        sysProxySwitch.translatesAutoresizingMaskIntoConstraints = false
        sysProxyServiceLabel = NSTextField(labelWithString: "同时设为 macOS 系统代理")
        sysProxyServiceLabel.textColor = .labelColor
        let sysRow = NSStackView(views: [sysProxySwitch, sysProxyServiceLabel])
        sysRow.orientation = .horizontal
        sysRow.alignment = .centerY
        sysRow.spacing = 10

        let healthCard = card([healthStack(keys: [
            ("listener", "本地监听  \(settings.localHost):\(settings.socksPort)"),
            ("service", "launchd 服务  \(Service.label)")
        ])])

        resultLabel = NSTextField(wrappingLabelWithString: "就绪。面板上的开关只控制上面这个本地端口。")
        resultLabel.textColor = .tertiaryLabelColor
        resultLabel.font = .systemFont(ofSize: 11)

        return page(title: "本地 SOCKS 代理",
                    subtitle: "只服务把代理指向这个端口的本机程序；与下面的节点、诊断、维护互不影响。",
                    blocks: [powerCard, card([sysRow]), healthCard, resultLabel])
    }

    private func buildNodePage() -> NSView {
        nodePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        nodePopup.target = self
        nodePopup.action = #selector(applySelectedNode)
        nodePopup.translatesAutoresizingMaskIntoConstraints = false
        nodePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pickerRow = NSStackView(views: [nodePopup])
        pickerRow.orientation = .horizontal
        pickerRow.alignment = .centerY

        nodeSummaryLabel = NSTextField(wrappingLabelWithString: "")
        nodeSummaryLabel.textColor = .secondaryLabelColor
        nodeSummaryLabel.font = .systemFont(ofSize: 11.5)

        nodeDetailFields = [:]
        let grid = NSGridView(views: [])
        grid.rowSpacing = 6
        grid.columnSpacing = 14
        for key in ["类型", "服务器", "端口", "SNI", "认证", "obfs", "带宽", "UDP"] {
            let name = NSTextField(labelWithString: key)
            name.textColor = .secondaryLabelColor
            name.font = .systemFont(ofSize: 11.5)
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            nodeDetailFields[key] = value
            grid.addRow(with: [name, value])
        }
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }

        let actionRow = NSStackView(views: [
            button("重新读取节点文件", #selector(reloadNodeFile)),
            button("打开节点文件", #selector(openNodeFile)),
            button("Ping 节点", #selector(pingNode))
        ])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let detailCard = card([nodeSummaryLabel, divider(), grid])
        let actionCard = card([actionRow, hint("下拉即切换：重写 hysteria2-client.yaml（先备份 .bak）并重启代理。")])

        let pageView = page(title: "节点",
                            subtitle: "来源是 \(Paths.nodesFile.path)，下拉选择立即生效。",
                            blocks: [card([pickerRow]), detailCard, actionCard])
        reloadNodePopup()
        return pageView
    }

    private func buildDiagnosticsPage() -> NSView {
        let healthCard = card([healthStack(keys: [
            ("egress", "代理出口  \(settings.egressURL)"),
            ("tunnel", "隧道日志  \(Paths.daemonLog.lastPathComponent)"),
            ("direct", "直连对比  \(settings.egressURL)")
        ])])

        healthCheckLabel = NSTextField(labelWithString: "最近检测：尚未检测")
        healthCheckLabel.textColor = .secondaryLabelColor
        healthCheckLabel.font = .systemFont(ofSize: 11.5)

        autoProbeSwitch = NSSwitch()
        autoProbeSwitch.target = self
        autoProbeSwitch.action = #selector(toggleAutoProbe)
        autoProbeSwitch.translatesAutoresizingMaskIntoConstraints = false
        autoProbeSwitch.state = settings.autoRefresh ? .on : .off
        let autoRow = NSStackView(views: [
            autoProbeSwitch,
            label("每 30 秒自动探测"),
            boxSpacer(),
            button("测试出口", #selector(testEgress)),
            button("复制代理环境变量", #selector(copyProxyEnv))
        ])
        autoRow.orientation = .horizontal
        autoRow.alignment = .centerY
        autoRow.spacing = 10

        return page(title: "诊断",
                    subtitle: "「监听中」不等于「链路过」。hysteria 是 lazy 监听，服务端 QUIC 不通时端口照样开着，所以这里单独看出口和日志。",
                    blocks: [healthCard, card([healthCheckLabel]), card([autoRow])])
    }

    private func buildMaintenancePage() -> NSView {
        serviceLabel = NSTextField(labelWithString: "服务：检查中…")
        serviceLabel.textColor = .secondaryLabelColor
        serviceLabel.font = .systemFont(ofSize: 11.5)

        let serviceRow = NSStackView(views: [
            button("用户域（免密码）", #selector(useUserDomain)),
            button("系统域（需授权）", #selector(useSystemDomain)),
            button("卸载服务", #selector(uninstallService))
        ])
        serviceRow.orientation = .horizontal
        serviceRow.alignment = .centerY
        serviceRow.spacing = 8

        projectPathLabel = NSTextField(wrappingLabelWithString: Paths.projectDir.path)
        projectPathLabel.textColor = .secondaryLabelColor
        projectPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let fileRow = NSStackView(views: [
            button("客户端配置", #selector(openClientConfig)),
            button("节点文件", #selector(openNodeFile)),
            button("日志目录", #selector(openLogs)),
            button("更换项目目录…", #selector(chooseProjectDir))
        ])
        fileRow.orientation = .horizontal
        fileRow.alignment = .centerY
        fileRow.spacing = 8

        let sysHint = hint("「macOS 系统代理」在菜单栏里按网络服务单独开关，它和上面的本地端口是两回事。")

        domainLabel = NSTextField(wrappingLabelWithString: "运行位置：检查中…")
        domainLabel.textColor = .secondaryLabelColor
        domainLabel.font = .systemFont(ofSize: 11.5)

        let domainHint = hint("代理只监听 127.0.0.1，用户域就够用：免密码、登录后自启。系统域只在“未登录也要跑”时才有意义，代价是每次启停都要管理员授权。")

        return page(title: "维护",
                    subtitle: "安装位置、启停方式与文件路径。",
                    blocks: [card([domainLabel, serviceRow, domainHint]),
                            card([serviceLabel, sysHint]),
                            card([projectPathLabel, fileRow])])
    }

    // MARK: 界面构件

    private func page(title: String, subtitle: String, blocks: [NSView]) -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])

        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(head)

        if !subtitle.isEmpty {
            let sub = NSTextField(wrappingLabelWithString: subtitle)
            sub.textColor = .secondaryLabelColor
            sub.font = .systemFont(ofSize: 11.5)
            stack.addArrangedSubview(sub)
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        for block in blocks {
            stack.addArrangedSubview(block)
            block.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        return container
    }

    private func tabItem(_ title: String, symbol: String, page: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: PageViewController(page: page))
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func card(_ views: [NSView], spacing: CGFloat = 10) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views {
            stack.addArrangedSubview(view)
            if view is NSStackView || view is NSGridView {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor

        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14)
        ])
        return box
    }

    private func healthStack(keys: [(String, String)]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for (key, title) in keys { addHealthRow(key, title, to: stack) }
        return stack
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    /// 自适应宽度的状态胶囊
    private func pill(_ text: String, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .center
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.wantsLayer = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 19).isActive = true
        Self.style(pill: field, text: text, color: color)
        return field
    }

    private static func style(pill field: NSTextField, text: String, color: NSColor) {
        field.stringValue = text
        field.textColor = color
        field.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        field.layer?.cornerRadius = 5
        field.layer?.masksToBounds = true

        // NSTextField 没有 contentInsets，用显式宽度当内边距
        let font = field.font ?? NSFont.systemFont(ofSize: 11)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let width = textWidth + 18
        if let existing = field.constraints.first(where: { $0.firstAttribute == .width }) {
            existing.constant = width
        } else {
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        return field
    }

    /// 横向占位：把后面的控件挤到右边
    private func boxSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        return spacer
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .tertiaryLabelColor
        field.font = .systemFont(ofSize: 11)
        return field
    }


    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func addHealthRow(_ key: String, _ title: String, to stack: NSStackView) {
        let row = HealthRow(title: title)
        healthRows[key] = row
        stack.addArrangedSubview(row)
    }

    private func reloadNodePopup() {
        guard nodePopup != nil else { return }
        let selected = Store.selectedNode(nodeFile)
        nodePopup.removeAllItems()
        nodePopup.addItems(withTitles: nodeFile.nodes.map { "\($0.name) — \($0.endpoint)" })
        if let index = nodeFile.nodes.firstIndex(where: { $0.name == selected.name }) {
            nodePopup.selectItem(at: index)
        }
        nodeSummaryLabel?.stringValue = "当前：\(selected.summary)"
        refreshNodeDetails(selected)
    }

    private func refreshNodeDetails(_ node: ProxyNode) {
        guard !nodeDetailFields.isEmpty else { return }
        let auth = node.password.isEmpty ? "—" : "已配置（\(node.password.count) 字符）"
        let obfs = node.obfs.lowercased() == "none" || node.obfs.isEmpty
            ? "无"
            : "\(node.obfs)\(node.obfsPassword.isEmpty ? "" : "（已配密码）")"
        let values: [String: String] = [
            "类型": node.nodeType.isEmpty ? "Hysteria2" : node.nodeType,
            "服务器": node.server,
            "端口": "\(node.port)",
            "SNI": node.sni.isEmpty ? "—" : "\(node.sni)\(node.insecure ? "（不校验证书）" : "")",
            "认证": auth,
            "obfs": obfs,
            "带宽": "上 \(node.up.isEmpty ? "—" : node.up) / 下 \(node.down.isEmpty ? "—" : node.down)",
            "UDP": node.udp ? "开启" : "关闭"
        ]
        for (key, field) in nodeDetailFields {
            field.stringValue = values[key] ?? "—"
        }
    }

    @objc private func reloadNodeFile() {
        nodeFile = Store.loadNodeFile()
        reloadNodePopup()
        resultLabel?.stringValue = "已重新读取 \(Paths.nodesFile.path)（\(nodeFile.nodes.count) 个节点）"
    }

    @objc private func openControlPanel() {
        controlWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 状态刷新

    private func refreshStatus() {
        let settings = self.settings
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listener = Probe.tcpOpen(host: settings.localHost, port: settings.socksPort, timeout: 2)
            let status = Service.status(settings: settings)
            DispatchQueue.main.async {
                guard let self else { return }
                self.socksItem.title = "SOCKS5 \(settings.localHost):\(settings.socksPort)：\(listener ? "监听中" : "无监听")"
                self.serviceItem.title = "服务：\(status.detail) · \(self.domainName(status.domain))"
                self.serviceLabel?.stringValue =
                    "服务：\(status.detail) · \(self.domainName(status.domain)) · \(Service.label)"
                let domainLevel: HealthLevel = status.running ? .healthy
                    : (status.domain == .notInstalled ? .failed : .warning)
                self.healthRows["service"]?.update(level: domainLevel, detail: status.detail)
                self.healthRows["listener"]?.update(level: listener ? .healthy : .failed,
                                                    detail: listener ? "监听中" : "无监听")

                // 本地 SOCKS 代理总开关：以真实监听状态为准
                let localOn = listener || status.running
                if !self.proxyToggling {
                    self.proxySwitch?.state = localOn ? .on : .off
                    self.proxySwitch?.isEnabled = true
                }
                self.proxyToggleItem.state = localOn ? .on : .off
                self.proxyToggleItem.title = localOn ? "关闭本地 SOCKS 代理" : "开启本地 SOCKS 代理"
                self.proxyStateLabel?.stringValue = localOn
                    ? "运行中 · \(settings.localHost):\(settings.socksPort) · \(self.domainName(status.domain))"
                    : "已关闭（端口未监听）"
                if let pill = self.proxyPill {
                    let color = localOn ? HealthLevel.healthy.color : NSColor.secondaryLabelColor
                    Self.style(pill: pill, text: localOn ? "运行中" : "已关闭", color: color)
                }
                self.sysProxySwitch?.isEnabled = localOn && !self.proxyToggling
                self.updateDomainLabel(status: status)
                self.controlWindow?.subtitle = self.statusSubtitle(localOn: localOn, domain: status.domain)

                self.updateTunnelRow()
                self.updateMenuBarTitle(listener: listener, status: status)
            }
        }
    }

    /// 窗口副标题：每个分栏都能看到的即时状态
    private func statusSubtitle(localOn: Bool, domain: ServiceDomain) -> String {
        var parts = [localOn ? "本地 SOCKS 代理运行中" : "本地 SOCKS 代理已关闭"]
        if localOn, lastEgress.ok, let ms = lastEgress.latencyMS {
            parts.append("出口 \(lastEgress.ip) · \(Int(ms.rounded()))ms")
        } else if localOn {
            parts.append("出口不可用")
        }
        parts.append(domainName(domain))
        return parts.joined(separator: "  ·  ")
    }

    /// 监听端口开着但隧道可能已经死了（lazy 模式），所以单独看日志
    private func updateTunnelRow() {
        let summary = TunnelLog.inspect(logFile: Paths.daemonLog)
        let level: HealthLevel = summary.healthy ? .healthy : (summary.fatal ? .failed : .warning)
        healthRows["tunnel"]?.update(level: level, detail: summary.detail)
    }

    private func domainName(_ domain: ServiceDomain) -> String {
        switch domain {
        case .system: return "系统域"
        case .user: return "用户域"
        case .notInstalled: return "未安装"
        }
    }

    /// 维护页的“运行位置”一行：说清楚现在走哪个域、要不要密码、有没有遗留
    private func updateDomainLabel(status: ServiceStatus) {
        guard let field = domainLabel else { return }
        let settings = self.settings
        var lines: [String] = []
        switch status.domain {
        case .user:
            lines.append("运行位置：用户域（LaunchAgent）— 免密码，登录后自启")
        case .system:
            lines.append("运行位置：系统域（LaunchDaemon）— 每次启停需管理员授权")
        case .notInstalled:
            lines.append("运行位置：未安装 — 下次开启时按下面选择的方式安装")
        }
        lines.append("下次安装方式：\(settings.domainMode == "system" ? "系统域" : "用户域（免密码）")")
        if Service.hasSystemLeftover(settings: settings) {
            lines.append("检测到遗留的系统域安装（/Library/LaunchDaemons）—— 不需要密码也能工作，想要干净就点「用户域（免密码）」清掉")
        }
        field.stringValue = lines.joined(separator: "\n")
    }

    /// 菜单栏标题显示延迟（参考项目没有）：健康时是 "42ms"，异常时隐藏
    private func updateMenuBarTitle(listener: Bool, status: ServiceStatus) {
        guard let button = statusItem.button else { return }
        let level: HealthLevel
        if listener, status.running { level = .healthy }
        else if listener || status.running { level = .warning }
        else { level = .failed }

        var text = ""
        if level == .healthy, let ms = lastEgress.latencyMS, lastEgress.ok {
            text = " \(Int(ms.rounded()))ms"
        }
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: level.color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            ]
        )
        var tooltip = "localsocks · \(domainName(status.domain)) \(status.detail)"
        if lastEgress.ok { tooltip += " · 出口 \(lastEgress.ip)" }
        button.toolTip = tooltip
    }

    // MARK: 探测

    private func performProbe() {
        guard !probing else { return }
        probing = true
        let settings = self.settings
        if Thread.isMainThread { testItem?.title = "测试中…" }
        refreshAttachedSystemProxyState()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let egress = Probe.egress(settings: settings)
            let geo = egress.ok ? Probe.geo(settings: settings) : ""
            let direct = Probe.direct(settings: settings)
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                self.testItem?.title = "测试出口"
                var report = egress
                report.geo = geo
                self.lastEgress = report
                self.applyProbeResults(report, direct: direct)
                self.refreshStatus()
            }
        }
    }

    private func applyProbeResults(_ egress: EgressReport, direct: DirectReport) {
        if egress.ok {
            let ms = egress.latencyMS.map { " · \(Int($0.rounded()))ms" } ?? ""
            let geo = egress.geo.isEmpty ? "" : " · \(egress.geo)"
            healthRows["egress"]?.update(level: .healthy, detail: "正常 · \(egress.ip)\(ms)\(geo)")
            egressItem.title = "出口：\(egress.ip)\(ms)"
        } else {
            healthRows["egress"]?.update(level: .failed, detail: "不可用 · \(egress.error)")
            egressItem.title = "出口：不可用"
        }

        if direct.ok {
            let same = direct.ip == egress.ip
            let ms = direct.latencyMS.map { " · \(Int($0.rounded()))ms" } ?? ""
            healthRows["direct"]?.update(
                level: same ? .warning : .healthy,
                detail: same
                    ? "与代理出口相同（\(direct.ip)）· 流量可能没走代理"
                    : "直连 \(direct.ip)\(ms) · 与代理出口不同，链路生效"
            )
        } else {
            healthRows["direct"]?.update(level: .unknown, detail: "直连不可用（可能被网络策略阻断）")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        healthCheckLabel?.stringValue = "最近检测：\(formatter.string(from: Date()))  ·  节点 \(Store.selectedNode(nodeFile).name)"
    }

    // MARK: 动作

    // MARK: 本地 SOCKS 代理总开关

    /// 控制面板里的开关
    @objc private func toggleLocalProxy() {
        setLocalProxy(on: proxySwitch.state == .on)
    }

    /// 菜单栏里的开关（带勾选态，点一下切一次）
    @objc private func toggleLocalProxyFromMenu() {
        setLocalProxy(on: proxyToggleItem.state != .on)
    }

    private func setLocalProxy(on: Bool) {
        guard !proxyToggling else { return }
        proxyToggling = true
        proxySwitch?.isEnabled = false
        proxyToggleItem.isEnabled = false
        sysProxySwitch?.isEnabled = false
        proxyStateLabel?.textColor = .secondaryLabelColor
        proxyStateLabel?.stringValue = on ? "正在开启…" : "正在关闭…"
        resultLabel?.stringValue = on
            ? "正在开启本地 SOCKS 代理（\(settings.domainMode == "system" ? "系统域，会请求一次授权" : "用户域，不需要密码")）…"
            : "正在关闭本地 SOCKS 代理…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var message = on
                ? Service.start(settings: self.settings)
                : Service.stop(settings: self.settings)
            // 关代理时顺手把指向本机端口的系统代理也关掉，避免把系统网络弄断
            if !on, let service = self.primaryNetworkService {
                let current = SystemProxy.state(service: service)
                if current?.enabled == true,
                   current?.host == self.settings.localHost,
                   current?.port == self.settings.socksPort {
                    message += " / " + SystemProxy.disable(service: service,
                                                            fallbackHost: self.settings.localHost,
                                                            fallbackPort: self.settings.socksPort)
                }
            }
            let finalMessage = message
            DispatchQueue.main.async {
                self.proxyToggling = false
                self.proxySwitch?.isEnabled = true
                self.proxyToggleItem.isEnabled = true
                self.resultLabel?.stringValue = finalMessage
                self.refreshStatus()
                self.refreshAttachedSystemProxyState()
                if on {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.performProbe() }
                } else {
                    self.healthRows["egress"]?.update(level: .unknown, detail: "代理已关闭")
                    self.healthRows["tunnel"]?.update(level: .unknown, detail: "代理已关闭")
                    self.lastEgress = EgressReport(ok: false, ip: "", latencyMS: nil, geo: "", error: "代理已关闭")
                }
            }
        }
    }

    /// 主网络服务：Wi-Fi 优先，其次第一个可用服务
    private var primaryNetworkService: String? {
        let services = SystemProxy.services()
        return services.first {
            $0.localizedCaseInsensitiveContains("wi-fi") || $0.localizedCaseInsensitiveContains("wifi")
        } ?? services.first
    }

    /// 本地代理旁边的「同时设为 macOS 系统代理」
    @objc private func toggleAttachedSystemProxy() {
        guard let service = primaryNetworkService else {
            sysProxySwitch.state = .off
            resultLabel?.stringValue = "未找到可用的网络服务（networksetup 没列出任何服务）"
            return
        }
        let wantOn = sysProxySwitch.state == .on
        let settings = self.settings
        sysProxySwitch.isEnabled = false
        resultLabel?.stringValue = "正在设置 \(service) 的系统代理…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message = wantOn
                ? SystemProxy.set(service: service, host: settings.localHost, port: settings.socksPort, enabled: true)
                : SystemProxy.disable(service: service,
                                      fallbackHost: settings.localHost, fallbackPort: settings.socksPort)
            DispatchQueue.main.async {
                self?.resultLabel?.stringValue = "\(message)（\(service)）"
                self?.refreshAttachedSystemProxyState()
                self?.rebuildSystemProxyMenu()
            }
        }
    }

    /// 按真实 networksetup 状态回填开关，不猜
    private func refreshAttachedSystemProxyState() {
        guard let service = primaryNetworkService else {
            sysProxySwitch?.state = .off
            sysProxySwitch?.isEnabled = false
            sysProxyServiceLabel?.stringValue = "同时设为 macOS 系统代理（无网络服务）"
            return
        }
        let settings = self.settings
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = SystemProxy.state(service: service)
            let on = state?.enabled == true
                && state?.host == settings.localHost
                && state?.port == settings.socksPort
            DispatchQueue.main.async {
                guard let self else { return }
                self.sysProxySwitch?.state = on ? .on : .off
                if !self.proxyToggling {
                    self.sysProxySwitch?.isEnabled = true
                }
                self.sysProxyServiceLabel?.stringValue = "同时设为 macOS 系统代理（\(service)）"
            }
        }
    }

    @objc private func restartService() {
        runServiceAction { Service.restart(settings: self.settings) }
    }

    private func runServiceAction(_ action: @escaping () -> String) {
        resultLabel?.stringValue = "执行中…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message = action()
            DispatchQueue.main.async {
                guard let self else { return }
                self.resultLabel?.stringValue = message
                self.refreshStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.performProbe() }
            }
        }
    }

    @objc private func testEgress() {
        resultLabel?.stringValue = "正在通过本地 SOCKS5 测试出口…"
        performProbe()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let report = self.lastEgress
            let message = report.ok
                ? "出口 IP：\(report.ip)\(report.latencyMS.map { " · \(Int($0.rounded()))ms" } ?? "")\(report.geo.isEmpty ? "" : " · \(report.geo)")"
                : "测试失败：\(report.error)"
            self.resultLabel?.stringValue = message
            self.showAlert(title: report.ok ? "代理正常" : "代理测试失败", message: message)
        }
    }

    @objc private func pingNode() {
        let node = Store.selectedNode(nodeFile)
        resultLabel?.stringValue = "正在 ping \(node.server)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = Probe.ping(host: node.server)
            DispatchQueue.main.async {
                guard let self else { return }
                self.resultLabel?.stringValue = "ping \(node.server)：\(output)"
                self.showAlert(title: "Ping \(node.name)", message: output)
            }
        }
    }

    @objc private func toggleAutoProbe() {
        settings.autoRefresh.toggle()
        autoProbeItem.state = settings.autoRefresh ? .on : .off
        autoProbeSwitch?.state = settings.autoRefresh ? .on : .off
        Store.saveSettings(settings)
    }

    @objc private func applySelectedNode() {
        let index = nodePopup.indexOfSelectedItem
        guard index >= 0, index < nodeFile.nodes.count else { return }
        let node = nodeFile.nodes[index]
        nodeFile.selected = node.name
        Store.saveNodeFile(nodeFile)

        if case .failure(let error) = ConfigWriter.write(node: node, settings: settings) {
            resultLabel?.stringValue = "写入配置失败：\(error.localizedDescription)"
            return
        }
        nodeSummaryLabel?.stringValue = "当前：\(node.summary)"
        resultLabel?.stringValue = "已切换到 \(node.name) 并重写 hysteria2-client.yaml，正在重启服务…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let message = Service.restart(settings: self.settings)
            DispatchQueue.main.async {
                self.resultLabel?.stringValue = "节点 \(node.name)：\(message)"
                self.refreshStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.performProbe() }
            }
        }
    }

    @objc private func useUserDomain() {
        settings.domainPreference = "user"
        Store.saveSettings(settings)
        runServiceAction { Service.applyDomain("user", settings: self.settings) }
    }

    @objc private func useSystemDomain() {
        settings.domainPreference = "system"
        Store.saveSettings(settings)
        resultLabel?.stringValue = "切换到系统域需要一次管理员授权（装在 /Library/LaunchDaemons）…"
        runServiceAction { Service.applyDomain("system", settings: self.settings) }
    }

    @objc private func uninstallService() {
        let mode = settings.domainMode
        runServiceAction { Service.uninstall(mode: mode, settings: self.settings) }
    }

    @objc private func toggleSystemProxy(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? String else { return }
        let settings = self.settings
        resultLabel?.stringValue = "正在设置 \(service)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let current = SystemProxy.state(service: service)
            let isOn = current?.enabled == true
                && current?.host == settings.localHost
                && current?.port == settings.socksPort
            let message = isOn
                ? SystemProxy.disable(service: service, fallbackHost: settings.localHost, fallbackPort: settings.socksPort)
                : SystemProxy.set(service: service, host: settings.localHost, port: settings.socksPort, enabled: true)
            DispatchQueue.main.async {
                self?.resultLabel?.stringValue = message
                self?.rebuildSystemProxyMenu()
            }
        }
    }

    /// 主网络服务上开/关 SOCKS 代理（Wi-Fi 优先，其次有线）
    @objc private func togglePrimarySystemProxy() {
        guard let target = primaryNetworkService else {
            resultLabel?.stringValue = "未找到可用的网络服务"
            return
        }
        let item = NSMenuItem()
        item.representedObject = target
        toggleSystemProxy(item)
    }

    @objc private func copyProxyEnv() {
        let text = """
        export ALL_PROXY=\(settings.socksProxyURL)
        export HTTP_PROXY=http://\(settings.localHost):\(settings.httpPort)
        export HTTPS_PROXY=http://\(settings.localHost):\(settings.httpPort)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        resultLabel?.stringValue = "已复制代理环境变量到剪贴板"
    }

    // MARK: 文件

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    @objc private func openClientConfig() {
        if !FileManager.default.fileExists(atPath: Paths.clientConfig.path) {
            let node = Store.selectedNode(nodeFile)
            ConfigWriter.write(node: node, settings: settings)
        }
        open(Paths.clientConfig)
    }

    @objc private func openNodeFile() {
        open(Paths.nodesFile.deletingLastPathComponent())
    }

    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)
        open(Paths.logsDir)
    }

    @objc private func chooseProjectDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Paths.projectDir
        panel.message = "选择 localsocks 项目目录（含 install.sh 与 hysteria2-client.yaml）"
        if panel.runModal() == .OK, let url = panel.url {
            Paths.setProjectDir(url)
            nodeFile = Store.loadNodeFile()
            reloadNodePopup()
            projectPathLabel?.stringValue = url.path
            resultLabel?.stringValue = "项目目录：\(url.path)"
            refreshStatus()
        }
    }

    // MARK: 杂项

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
enum LocalsocksMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
