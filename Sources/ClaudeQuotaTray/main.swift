import AppKit
import CommonCryptoShim
import CryptoKit
import Foundation
import Security

private let appVersion = "0.1.0"

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var refreshTimer: Timer?
    private var isFetching = false

    private let appDataDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeQuotaTray")
    private lazy var configStore = ConfigStore(appDataDir: appDataDir)
    private lazy var client = ClaudeUsageClient(appDataDir: appDataDir)

    private var config = Config()
    private var state = FetchState.idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        do {
            try configStore.ensureFiles()
            config = try configStore.read()
        } catch {
            state = .failed(error.localizedDescription, Date(), nil)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(openMenu)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.menu = menu

        setIcon(nil, .idle)
        rebuildMenu()
        scheduleTimer()
        Task { await refreshNow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.releaseSingleInstanceLock()
    }

    @objc private func openMenu() {
        rebuildMenu()
        statusItem.button?.performClick(nil)
    }

    @objc private func timerFired() {
        Task { await refreshNow() }
    }

    private func refreshNow() async {
        if isFetching {
            return
        }

        isFetching = true
        let previous = state.usage
        state = .loading(previous)
        setIcon(previous, previous == nil ? .loading : .normal)
        rebuildMenu()

        do {
            let usage = try await client.fetchUsage(sourceMode: config.sourceMode)
            state = .loaded(usage)
            setIcon(usage, .normal)
        } catch {
            state = .failed(error.localizedDescription, Date(), previous)
            setIcon(previous, previous == nil ? .failed : .normal)
        }

        isFetching = false
        rebuildMenu()
    }

    private func rebuildMenu() {
        updateTooltip()
        menu.removeAllItems()

        switch state.kind {
        case .idle:
            addDisabled("未加载")
        case .loading:
            if let usage = state.usage {
                addQuotaDetails(usage)
                addDisabled("正在刷新...")
            } else {
                addDisabled("正在刷新...")
            }
        case .loaded:
            if let usage = state.usage {
                addQuotaDetails(usage)
            }
        case .failed:
            if let usage = state.usage {
                addQuotaDetails(usage)
                addDisabled("刷新失败，继续显示上次成功数据")
            } else {
                addDisabled("获取失败")
            }

            addDisabled(state.message ?? "未知错误")
            if let fetchedAt = state.fetchedAt {
                addDisabled("更新于：\(Self.formatTime(fetchedAt))")
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("立即刷新") { [weak self] in
            Task { await self?.refreshNow() }
        })
        menu.addItem(sourceModeMenu())
        menu.addItem(refreshIntervalMenu())
        menu.addItem(startupMenuItem())
        menu.addItem(item("打开 Claude 配置目录") { Self.openDirectory(ClaudeUsageClient.configDirectory()) })
        menu.addItem(item("打开本工具配置目录") { [appDataDir] in Self.openDirectory(appDataDir) })
        menu.addItem(.separator())
        addDisabled("版本：v\(Self.displayVersion())")
        menu.addItem(item("退出") { NSApp.terminate(nil) })
    }

    private func addQuotaDetails(_ usage: UsageSnapshot) {
        let host = NSMenuItem()
        host.view = QuotaPanelView(usage: usage, frame: NSRect(x: 0, y: 0, width: 320, height: 106))
        menu.addItem(host)
        menu.addItem(.separator())

        addMetricText(usage.fiveHour)
        addMetricText(usage.sevenDay)
        addDisabled("更新于：\(Self.formatTime(usage.fetchedAt))")
        if !usage.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addDisabled("来源：\(usage.sourcePath)")
        }
    }

    private func addMetricText(_ metric: QuotaMetric) {
        guard metric.available else {
            addDisabled("\(metric.label)：不可用")
            return
        }

        addDisabled("\(metric.label)：剩余 \(Self.percent(metric.remainingPercent))（已用 \(Self.percent(metric.usedPercent))）")
        if let resetsAt = metric.resetsAt {
            addDisabled("\(metric.label)重置：\(Self.formatDateTime(resetsAt))（\(Self.remainingText(until: resetsAt))）")
        }
    }

    private func refreshIntervalMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for seconds in [60, 300, 600, 1800] {
            let title = seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分钟"
            let child = NSMenuItem(title: title, action: #selector(selectRefreshInterval(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = seconds
            child.state = config.refreshIntervalSeconds == seconds ? .on : .off
            submenu.addItem(child)
        }
        root.submenu = submenu
        return root
    }

    @objc private func selectRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else {
            return
        }
        config.refreshIntervalSeconds = seconds
        try? configStore.write(config)
        scheduleTimer()
        rebuildMenu()
    }

    private func sourceModeMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "数据来源模式", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for mode in [QuotaSourceMode.active, .passive, .auto] {
            let child = NSMenuItem(title: Self.sourceModeTitle(mode), action: #selector(selectSourceMode(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = mode.rawValue
            child.state = config.sourceMode == mode ? .on : .off
            submenu.addItem(child)
        }

        submenu.addItem(.separator())
        submenu.addItem(item("安装/更新被动模式采集器") { [weak self] in
            self?.installStatusLineCollector()
        })
        root.submenu = submenu
        return root
    }

    @objc private func selectSourceMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = QuotaSourceMode(rawValue: raw) else {
            return
        }
        config.sourceMode = mode
        try? configStore.write(config)
        rebuildMenu()
        Task { await refreshNow() }
    }

    private func startupMenuItem() -> NSMenuItem {
        let child = item("开机自启动") {
            do {
                try StartupManager.setEnabled(!StartupManager.isEnabled())
                self.rebuildMenu()
            } catch {
                Self.showError("设置开机自启动失败", error.localizedDescription)
            }
        }
        child.state = StartupManager.isEnabled() ? .on : .off
        return child
    }

    private func installStatusLineCollector() {
        do {
            try StatusLineInstaller.install(appDataDir: appDataDir)
            Self.showInfo(
                "已安装状态栏采集器",
                "请在 Claude Code 中发送任意一条消息。Claude Code 收到响应后会更新额度缓存，菜单栏随后即可显示 5 小时额度和周额度。")
            Task { await refreshNow() }
        } catch {
            Self.showError("安装状态栏采集器失败", error.localizedDescription)
        }
    }

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: TimeInterval(max(1, config.refreshIntervalSeconds)),
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true)
    }

    private func setIcon(_ usage: UsageSnapshot?, _ tone: IconTone) {
        let image = QuotaStatusIcon.make(usage: usage, tone: tone)
        image.isTemplate = false
        statusItem?.button?.image = image
    }

    private func updateTooltip() {
        let text: String
        switch state.kind {
        case .loaded:
            if let usage = state.usage {
                text = "Claude 5h剩余 \(usage.fiveHour.remainingText) | 周剩余 \(usage.sevenDay.remainingText)"
            } else {
                text = "Claude Quota"
            }
        case .failed:
            if let usage = state.usage {
                text = "Claude 刷新失败，显示旧数据 | 5h \(usage.fiveHour.remainingText) | 周 \(usage.sevenDay.remainingText)"
            } else {
                text = "Claude 获取失败 | \(state.message ?? "未知错误")"
            }
        case .loading:
            if let usage = state.usage {
                text = "Claude 正在刷新 | 5h \(usage.fiveHour.remainingText) | 周 \(usage.sevenDay.remainingText)"
            } else {
                text = "Claude 正在刷新额度..."
            }
        case .idle:
            text = "Claude Quota"
        }
        statusItem?.button?.toolTip = Self.trimTooltip(text)
    }

    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let child = ActionMenuItem(title: title, actionBlock: action)
        child.target = child
        child.action = #selector(ActionMenuItem.run)
        return child
    }

    private func addDisabled(_ title: String) {
        let child = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        child.isEnabled = false
        menu.addItem(child)
    }

    private static func sourceModeTitle(_ mode: QuotaSourceMode) -> String {
        switch mode {
        case .active: return "主动模式（OAuth API）"
        case .passive: return "被动模式（Claude Code statusLine）"
        case .auto: return "自动兜底（主动优先）"
        }
    }

    private static func displayVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? appVersion
    }

    private static func formatTime(_ date: Date) -> String {
        DateFormatters.time.string(from: date)
    }

    private static func formatDateTime(_ date: Date) -> String {
        DateFormatters.dateTime.string(from: date)
    }

    fileprivate static func remainingText(until date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 {
            return "已到期"
        }
        if remaining >= 86_400 {
            let days = Int(remaining / 86_400)
            let hours = Int(remaining.truncatingRemainder(dividingBy: 86_400) / 3600)
            return "\(days) 天 \(hours) 小时后"
        }
        if remaining >= 3600 {
            let hours = Int(remaining / 3600)
            let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
            return "\(hours) 小时 \(minutes) 分钟后"
        }
        return "\(max(1, Int(remaining / 60))) 分钟后"
    }

    fileprivate static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func trimTooltip(_ text: String) -> String {
        text.count <= 63 ? text : String(text.prefix(60)) + "..."
    }

    private static func openDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private static func showError(_ title: String, _ message: String) {
        showAlert(title, message, .critical)
    }

    private static func showInfo(_ title: String, _ message: String) {
        showAlert(title, message, .informational)
    }

    private static func showAlert(_ title: String, _ message: String, _ style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static var lockDescriptor: Int32 = -1

    private static func acquireSingleInstanceLock() -> Bool {
        let lockURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeQuotaTray/app.lock")
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        lockDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else {
            return true
        }
        return flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0
    }

    private static func releaseSingleInstanceLock() {
        guard lockDescriptor >= 0 else {
            return
        }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let actionBlock: () -> Void

    init(title: String, actionBlock: @escaping () -> Void) {
        self.actionBlock = actionBlock
        super.init(title: title, action: nil, keyEquivalent: "")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func run() {
        actionBlock()
    }
}

private final class ClaudeUsageClient {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let jsonDecoder = JSONDecoder()
    private let statusLineCacheURL: URL
    private let desktopUsageCacheURL: URL
    private let diagnosticLogURL: URL

    init(appDataDir: URL) {
        statusLineCacheURL = appDataDir.appendingPathComponent("statusline-usage.json")
        desktopUsageCacheURL = appDataDir.appendingPathComponent("claude-app-usage.json")
        diagnosticLogURL = appDataDir.appendingPathComponent("diagnostic.log")
    }

    func fetchUsage(sourceMode: QuotaSourceMode) async throws -> UsageSnapshot {
        switch sourceMode {
        case .passive:
            return try fetchPassiveUsage()
        case .auto:
            return try await fetchAutoUsage()
        case .active:
            return try await fetchActiveUsage()
        }
    }

    private func fetchActiveUsage() async throws -> UsageSnapshot {
        if let usage = try await tryFetchClaudeAppOAuthUsage() {
            return usage
        }

        if let cached = tryReadDesktopUsageCache(maxAge: 30 * 60) {
            return cached
        }

        throw AppError("主动模式无法获取 Claude App OAuth usage。请先登录 Claude App，或切换到被动模式。")
    }

    private func fetchPassiveUsage() throws -> UsageSnapshot {
        if let cached = tryReadStatusLineCache() {
            return cached
        }
        throw AppError("被动模式尚未生成 statusLine 缓存。请在 Claude Code 中发送一条消息，或切换到主动模式。")
    }

    private func fetchAutoUsage() async throws -> UsageSnapshot {
        if let usage = try await tryFetchClaudeAppOAuthUsage() {
            return usage
        }

        if let cached = tryReadDesktopUsageCache(maxAge: 30 * 60) {
            return cached
        }

        if let cached = tryReadStatusLineCache() {
            return cached
        }

        let credentials = try readCredentials()
        guard let token = credentials.accessToken, !token.isEmpty else {
            throw AppError("Claude Code 凭据里没有 accessToken，请先重新登录 Claude Code。")
        }

        if let expiresAt = credentials.expiresAt, expiresAt <= Date().addingTimeInterval(30) {
            throw AppError("Claude Code OAuth token 已过期，请重新打开 Claude Code 并登录。")
        }

        return try await fetchOAuthUsage(accessToken: token, sourcePath: credentials.sourcePath)
    }

    private func tryReadStatusLineCache() -> UsageSnapshot? {
        guard FileManager.default.fileExists(atPath: statusLineCacheURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: statusLineCacheURL)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: statusLineCacheURL.path)
            let fileDate = attributes[.modificationDate] as? Date ?? Date()
            let fetchedAt = Self.dateValue(root, names: ["fetched_at", "fetchedAt"]) ?? fileDate
            guard Date().timeIntervalSince(fetchedAt) <= 2 * 24 * 60 * 60 else {
                return nil
            }

            root = Self.usagePayloadRoot(root)
            let snapshot = UsageSnapshot(
                fiveHour: Self.readMetric(root, names: ["five_hour", "fiveHour"], label: "5 小时额度"),
                sevenDay: Self.readMetric(root, names: ["seven_day", "sevenDay"], label: "周额度"),
                fetchedAt: fetchedAt,
                sourcePath: statusLineCacheURL.path)
            return Self.hasAnyMetric(snapshot) ? snapshot : nil
        } catch {
            return nil
        }
    }

    private func tryReadDesktopUsageCache(maxAge: TimeInterval) -> UsageSnapshot? {
        guard FileManager.default.fileExists(atPath: desktopUsageCacheURL.path) else {
            return nil
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: desktopUsageCacheURL.path)
            let fetchedAt = attributes[.modificationDate] as? Date ?? Date()
            guard Date().timeIntervalSince(fetchedAt) <= maxAge else {
                return nil
            }

            let data = try Data(contentsOf: desktopUsageCacheURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let root = Self.usagePayloadRoot(object)
            let snapshot = UsageSnapshot(
                fiveHour: Self.readMetric(root, names: ["five_hour", "fiveHour"], label: "5 小时额度"),
                sevenDay: Self.readMetric(root, names: ["seven_day", "sevenDay"], label: "周额度"),
                fetchedAt: fetchedAt,
                sourcePath: desktopUsageCacheURL.path)
            return Self.hasAnyMetric(snapshot) ? snapshot : nil
        } catch {
            return nil
        }
    }

    private func tryFetchClaudeAppOAuthUsage() async throws -> UsageSnapshot? {
        guard let profile = Self.findClaudeAppProfile() else {
            logDiagnostic("Claude App OAuth profile not found.")
            return nil
        }

        guard let token = Self.readClaudeAppOAuthToken(profile: profile) else {
            logDiagnostic("Claude App OAuth token cache unavailable.")
            return nil
        }

        guard token.expiresAt > Date().addingTimeInterval(60) else {
            logDiagnostic("Claude App OAuth token is expired.")
            return nil
        }

        do {
            let snapshot = try await fetchOAuthUsage(accessToken: token.accessToken, sourcePath: "Claude App OAuth usage API")
            cacheDesktopUsage(snapshot.rawContent)
            logDiagnostic("Claude App OAuth usage API succeeded for org \(token.organizationId).")
            return snapshot.withoutRawContent()
        } catch {
            logDiagnostic("Claude App OAuth usage API failed: \(Self.sanitizeForLog(error.localizedDescription))")
            return nil
        }
    }

    private func fetchOAuthUsage(accessToken: String, sourcePath: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1.181", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("usage 请求没有返回 HTTP 响应。")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.tryReadAPIError(data) ?? "usage 请求失败（HTTP \(http.statusCode)）"
            throw AppError(message)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("usage 响应不是 JSON 对象。")
        }

        let root = Self.usagePayloadRoot(object)
        let snapshot = UsageSnapshot(
            fiveHour: Self.readMetric(root, names: ["five_hour", "fiveHour"], label: "5 小时额度"),
            sevenDay: Self.readMetric(root, names: ["seven_day", "sevenDay"], label: "周额度"),
            fetchedAt: Date(),
            sourcePath: sourcePath,
            rawContent: data)
        guard Self.hasAnyMetric(snapshot) else {
            throw AppError("usage 响应中没有 five_hour/seven_day。")
        }
        return snapshot
    }

    private func cacheDesktopUsage(_ data: Data?) {
        guard let data else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: desktopUsageCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: desktopUsageCacheURL, options: .atomic)
        } catch {
            // Cache failures should not hide a usable API response.
        }
    }

    private func logDiagnostic(_ message: String) {
        do {
            try FileManager.default.createDirectory(at: diagnosticLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? FileManager.default.attributesOfItem(atPath: diagnosticLogURL.path)[.size] as? UInt64,
               size > 256 * 1024 {
                try "\(DateFormatters.iso.string(from: Date())) Diagnostic log rotated.\n"
                    .write(to: diagnosticLogURL, atomically: true, encoding: .utf8)
            }
            let line = "\(DateFormatters.iso.string(from: Date())) \(message)\n"
            if FileManager.default.fileExists(atPath: diagnosticLogURL.path),
               let handle = try? FileHandle(forWritingTo: diagnosticLogURL) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try line.write(to: diagnosticLogURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // Diagnostics should never affect quota refresh.
        }
    }

    private static func findClaudeAppProfile() -> URL? {
        let profile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude")
        let config = profile.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: config.path) ? profile : nil
    }

    private static func readClaudeAppOAuthToken(profile: URL) -> ClaudeAppOAuthToken? {
        do {
            let configURL = profile.appendingPathComponent("config.json")
            let data = try Data(contentsOf: configURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cache = object["oauth:tokenCacheV2"] as? String ?? object["oauth:tokenCache"] as? String,
                  let encrypted = Data(base64Encoded: cache),
                  let password = Keychain.readGenericPassword(service: "Claude Safe Storage", account: "Claude Key") ??
                    Keychain.readGenericPassword(service: "Claude Safe Storage", account: nil),
                  let jsonData = Crypto.decryptElectronSafeStorage(encrypted, password: password),
                  let tokenObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }

            for (key, value) in tokenObject {
                guard let entry = value as? [String: Any],
                      let accessToken = Self.stringValue(entry, name: "token"),
                      !accessToken.isEmpty,
                      let expiresRaw = Self.numberValue(entry, names: ["expiresAt", "expires_at"]) else {
                    continue
                }
                let expiresAt = Self.dateFromEpoch(expiresRaw)
                let org = key.split(separator: ":").map(String.init).first(where: Self.isUUID) ?? ""
                return ClaudeAppOAuthToken(accessToken: accessToken, organizationId: org, expiresAt: expiresAt)
            }
            return nil
        } catch {
            return nil
        }
    }

    static func configDirectory() -> URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    private func readCredentials() throws -> ClaudeCredentials {
        let url = Self.configDirectory().appendingPathComponent(".credentials.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError("Claude 已登录，但新版 Claude Code 不再把 OAuth token 写到 .credentials.json。请在菜单中安装 Claude 状态栏采集器，然后在 Claude Code 中发送一条消息以生成额度缓存。")
        }

        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError(".credentials.json 不是 JSON 对象。")
        }
        let oauth = object["claudeAiOauth"] as? [String: Any] ?? object
        let expires = Self.numberValue(oauth, names: ["expiresAt", "expires_at"]).map(Self.dateFromEpoch)
        return ClaudeCredentials(
            accessToken: Self.stringValue(oauth, name: "accessToken"),
            expiresAt: expires,
            sourcePath: url.path)
    }

    private static func readMetric(_ root: [String: Any], names: [String], label: String) -> QuotaMetric {
        guard let element = anyValue(root, names: names) as? [String: Any] else {
            return .unavailable(label)
        }
        let used = min(100, max(0, numberValue(element, names: ["used_percentage", "usedPercent", "percent", "utilization"]) ?? 0))
        let reset = dateValue(element, names: ["resets_at", "resetsAt", "reset_at", "resetAt", "reset_time", "resetTime"])
        return QuotaMetric(label: label, usedPercent: used, resetsAt: reset, available: true)
    }

    private static func usagePayloadRoot(_ object: [String: Any]) -> [String: Any] {
        var root = object
        for name in ["data", "usage", "rateLimits", "rate_limits"] {
            if let next = anyValue(root, names: [name]) as? [String: Any] {
                root = next
            }
        }
        return root
    }

    private static func tryReadAPIError(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any] {
            return stringValue(error, name: "message") ?? stringValue(error, name: "type")
        }
        return stringValue(object, name: "message")
    }

    private static func anyValue(_ object: [String: Any], names: [String]) -> Any? {
        for name in names {
            if let exact = object[name] {
                return exact
            }
            if let match = object.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
                return match.value
            }
        }
        return nil
    }

    private static func stringValue(_ object: [String: Any], name: String) -> String? {
        anyValue(object, names: [name]) as? String
    }

    private static func numberValue(_ object: [String: Any], names: [String]) -> Double? {
        guard let value = anyValue(object, names: names) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func dateValue(_ object: [String: Any], names: [String]) -> Date? {
        guard let value = anyValue(object, names: names) else {
            return nil
        }
        if let number = value as? NSNumber {
            return dateFromEpoch(number.doubleValue)
        }
        if let double = value as? Double {
            return dateFromEpoch(double)
        }
        if let string = value as? String {
            if let number = Double(string) {
                return dateFromEpoch(number)
            }
            return DateFormatters.iso.date(from: string) ?? DateFormatters.isoFractional.date(from: string)
        }
        return nil
    }

    private static func dateFromEpoch(_ raw: Double) -> Date {
        Date(timeIntervalSince1970: raw > 9_999_999_999 ? raw / 1000 : raw)
    }

    private static func hasAnyMetric(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.fiveHour.available || snapshot.sevenDay.available
    }

    private static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private static func sanitizeForLog(_ content: String) -> String {
        let compact = content.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.count <= 400 ? compact : String(compact.prefix(400)) + "..."
    }
}

private enum Keychain {
    static func readGenericPassword(service: String, account: String?) -> Data? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        if let account {
            query[kSecAttrAccount] = account
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }
        return result as? Data
    }
}

private enum Crypto {
    static func decryptElectronSafeStorage(_ encrypted: Data, password: Data) -> Data? {
        if encrypted.starts(with: Data("v10".utf8)) || encrypted.starts(with: Data("v11".utf8)) {
            let payload = encrypted.dropFirst(3)
            if let gcm = decryptAESGCM(payload: payload, key: password) {
                return gcm
            }
            return decryptChromiumCBC(Data(payload), password: password)
        }
        return decryptChromiumCBC(encrypted, password: password)
    }

    private static func decryptAESGCM(payload: Data, key: Data) -> Data? {
        guard key.count == 32, payload.count > 12 + 16 else {
            return nil
        }
        do {
            let nonce = try AES.GCM.Nonce(data: payload.prefix(12))
            let ciphertext = payload.dropFirst(12).dropLast(16)
            let tag = payload.suffix(16)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            return nil
        }
    }

    private static func decryptChromiumCBC(_ ciphertext: Data, password: Data) -> Data? {
        var key = Data(repeating: 0, count: 16)
        let salt = Data("saltysalt".utf8)
        let rounds: UInt32 = 1003
        let keyLength = key.count
        let passwordLength = password.count
        let saltLength = salt.count
        let derivationStatus = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    cq_pbkdf2_sha1(
                        passwordBytes.bindMemory(to: UInt8.self).baseAddress,
                        passwordLength,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        saltLength,
                        rounds,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength)
                }
            }
        }
        guard derivationStatus == 0 else {
            return nil
        }

        var plaintext = Data(repeating: 0, count: ciphertext.count + 16)
        let plaintextCapacity = plaintext.count
        let ciphertextLength = ciphertext.count
        var plaintextLength = 0
        let iv = Data(repeating: 0x20, count: 16)
        let cryptStatus = plaintext.withUnsafeMutableBytes { plainBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        cq_aes_128_cbc_decrypt_pkcs7(
                            keyBytes.bindMemory(to: UInt8.self).baseAddress,
                            ivBytes.bindMemory(to: UInt8.self).baseAddress,
                            cipherBytes.bindMemory(to: UInt8.self).baseAddress,
                            ciphertextLength,
                            plainBytes.bindMemory(to: UInt8.self).baseAddress,
                            plaintextCapacity,
                            &plaintextLength)
                    }
                }
            }
        }
        guard cryptStatus == 0, plaintextLength >= 0, plaintextLength <= plaintext.count else {
            return nil
        }
        plaintext.removeSubrange(plaintextLength..<plaintext.count)
        return plaintext
    }
}

private enum StatusLineInstaller {
    private static let scriptFileName = "claude-quota-statusline.sh"

    static func install(appDataDir: URL) throws {
        let claudeDir = ClaudeUsageClient.configDirectory()
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDataDir, withIntermediateDirectories: true)

        let scriptURL = claudeDir.appendingPathComponent(scriptFileName)
        try script(appDataDir: appDataDir).write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        var root = try readSettings(settingsURL)
        let existing = root["statusLine"]
        let command = "/bin/zsh \(shellQuote(scriptURL.path))"

        if let existingObject = existing as? [String: Any],
           let existingCommand = existingObject["command"] as? String,
           !existingCommand.localizedCaseInsensitiveContains(scriptFileName) {
            let backupURL = appDataDir.appendingPathComponent("previous-statusline.json")
            let backupData = try JSONSerialization.data(withJSONObject: existingObject, options: [.prettyPrinted, .sortedKeys])
            try backupData.write(to: backupURL, options: .atomic)
        }

        root["statusLine"] = [
            "type": "command",
            "command": command,
            "padding": 0,
            "refreshInterval": 5
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func readSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func shellQuote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func script(appDataDir: URL) -> String {
        """
        #!/bin/zsh
        set +e

        app_dir=\(shellQuote(appDataDir.path))
        mkdir -p "$app_dir"
        debug_path="$app_dir/statusline-debug.log"
        cache_path="$app_dir/statusline-usage.json"

        input_json="$(cat)"
        if [[ -z "$input_json" ]]; then
            print "Claude"
            exit 0
        fi

        tmp="$(mktemp)"
        print -rn "$input_json" > "$tmp"

        /usr/bin/python3 - "$tmp" "$cache_path" "$debug_path" <<'PY'
        import json, pathlib, sys, time, datetime

        input_path = pathlib.Path(sys.argv[1])
        cache_path = pathlib.Path(sys.argv[2])
        debug_path = pathlib.Path(sys.argv[3])

        try:
            raw = input_path.read_text()
            data = json.loads(raw)
            rate_limits = data.get("rate_limits") or data.get("rateLimits")
            debug_path.write_text(
                f"{datetime.datetime.now(datetime.timezone.utc).isoformat()} invoked stdin={len(raw)} has_rate_limits={rate_limits is not None}\\n",
                encoding="utf-8"
            )
            payload = {
                "fetched_at": int(time.time()),
                "source": "claude-statusline",
                "rate_limits": rate_limits,
            }
            cache_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

            def remaining(metric):
                if not isinstance(metric, dict) or metric.get("used_percentage") is None:
                    return "--"
                value = max(0, min(100, 100 - float(metric.get("used_percentage"))))
                return f"{value:.0f}%"

            print(f"Claude 5h {remaining((rate_limits or {}).get('five_hour'))} | 7d {remaining((rate_limits or {}).get('seven_day'))}")
        except Exception as exc:
            with debug_path.open("a", encoding="utf-8") as handle:
                handle.write(f"{datetime.datetime.now(datetime.timezone.utc).isoformat()} error {exc}\\n")
            print("Claude")
        PY

        rm -f "$tmp"
        """
    }
}

private enum StartupManager {
    private static let label = "local.ClaudeQuotaTray"
    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            let arguments = startupArguments()
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": arguments,
                "RunAtLoad": true
            ]
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    private static func startupArguments() -> [String] {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return ["/usr/bin/open", "-a", bundle.path]
        }
        return [Bundle.main.executableURL?.path ?? CommandLine.arguments[0]]
    }
}

private final class ConfigStore {
    private let url: URL

    init(appDataDir: URL) {
        url = appDataDir.appendingPathComponent("config.json")
    }

    func ensureFiles() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try write(Config())
        }
    }

    func read() throws -> Config {
        try ensureFiles()
        let data = try Data(contentsOf: url)
        var config = try JSONDecoder().decode(Config.self, from: data)
        config.normalize()
        try write(config)
        return config
    }

    func write(_ config: Config) throws {
        var normalized = config
        normalized.normalize()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(normalized).write(to: url, options: .atomic)
    }
}

private final class QuotaPanelView: NSView {
    private let usage: UsageSnapshot

    init(usage: UsageSnapshot, frame: NSRect) {
        self.usage = usage
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        let secondaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        "Claude 余量".draw(at: NSPoint(x: 14, y: 10), withAttributes: titleAttrs)
        "更新于 \(DateFormatters.time.string(from: usage.fetchedAt))"
            .draw(at: NSPoint(x: 224, y: 12), withAttributes: secondaryAttrs)
        drawMetric(usage.fiveHour, x: 14, y: 36, width: 292, textAttrs: textAttrs, secondaryAttrs: secondaryAttrs)
        drawMetric(usage.sevenDay, x: 14, y: 68, width: 292, textAttrs: textAttrs, secondaryAttrs: secondaryAttrs)
    }

    private func drawMetric(
        _ metric: QuotaMetric,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        textAttrs: [NSAttributedString.Key: Any],
        secondaryAttrs: [NSAttributedString.Key: Any]) {
        let label = metric.available
            ? "\(metric.label)  剩余 \(AppDelegate.percent(metric.remainingPercent))"
            : "\(metric.label)  不可用"
        label.draw(at: NSPoint(x: x, y: y - 1), withAttributes: textAttrs)

        let reset = metric.resetsAt.map { "重置 \(DateFormatters.dateTime.string(from: $0))" } ?? ""
        let resetSize = reset.size(withAttributes: secondaryAttrs)
        reset.draw(at: NSPoint(x: x + width - resetSize.width, y: y - 1), withAttributes: secondaryAttrs)

        drawBar(
            rect: NSRect(x: x, y: y + 20, width: width, height: 9),
            ratio: metric.available ? metric.remainingRatio : 0,
            color: QuotaColors.color(for: metric))
    }

    private func drawBar(rect: NSRect, ratio: Double, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()

        let fillWidth = max(0, rect.width * CGFloat(min(1, max(0, ratio))))
        guard fillWidth >= 1 else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        color.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private enum QuotaStatusIcon {
    static func make(usage: UsageSnapshot?, tone: IconTone) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        if let usage {
            drawBar(rect: NSRect(x: 3, y: 5, width: 16, height: 5), ratio: usage.fiveHour.remainingRatio, color: QuotaColors.iconColor(for: usage.fiveHour))
            drawBar(rect: NSRect(x: 3, y: 13, width: 16, height: 5), ratio: usage.sevenDay.remainingRatio, color: QuotaColors.iconColor(for: usage.sevenDay))
        } else {
            drawStatusDot(tone)
        }

        image.unlockFocus()
        return image
    }

    private static func drawStatusDot(_ tone: IconTone) {
        let color: NSColor
        switch tone {
        case .loading: color = .systemBlue
        case .failed: color = .systemRed
        default: color = .secondaryLabelColor
        }

        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 16, height: 16)).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 10, height: 10)).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 10, height: 10))
        border.lineWidth = 1.4
        border.stroke()
    }

    private static func drawBar(rect: NSRect, ratio: Double, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        path.fill()

        let fillWidth = rect.width * CGFloat(min(1, max(0, ratio)))
        if fillWidth > 0 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            color.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSColor.labelColor.withAlphaComponent(0.24).setStroke()
        path.lineWidth = 0.7
        path.stroke()
    }
}

private enum QuotaColors {
    static func color(for metric: QuotaMetric) -> NSColor {
        switch metric.remainingPercent {
        case ..<15: return NSColor(calibratedRed: 0.82, green: 0.18, blue: 0.18, alpha: 1)
        case ..<35: return NSColor(calibratedRed: 0.86, green: 0.50, blue: 0.09, alpha: 1)
        default: return NSColor(calibratedRed: 0.16, green: 0.59, blue: 0.34, alpha: 1)
        }
    }

    static func iconColor(for metric: QuotaMetric) -> NSColor {
        switch metric.remainingPercent {
        case ..<15: return NSColor(calibratedRed: 0.91, green: 0.27, blue: 0.27, alpha: 1)
        case ..<35: return NSColor(calibratedRed: 0.93, green: 0.58, blue: 0.15, alpha: 1)
        default: return NSColor(calibratedRed: 0.24, green: 0.75, blue: 0.43, alpha: 1)
        }
    }
}

private enum DateFormatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct AppError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private struct Config: Codable {
    var refreshIntervalSeconds = 300
    var sourceMode = QuotaSourceMode.active

    mutating func normalize() {
        if ![60, 300, 600, 1800].contains(refreshIntervalSeconds) {
            refreshIntervalSeconds = 300
        }
    }
}

private enum QuotaSourceMode: String, Codable {
    case active
    case passive
    case auto
}

private struct ClaudeCredentials {
    let accessToken: String?
    let expiresAt: Date?
    let sourcePath: String
}

private struct ClaudeAppOAuthToken {
    let accessToken: String
    let organizationId: String
    let expiresAt: Date
}

private struct UsageSnapshot {
    let fiveHour: QuotaMetric
    let sevenDay: QuotaMetric
    let fetchedAt: Date
    let sourcePath: String
    fileprivate let rawContent: Data?

    init(
        fiveHour: QuotaMetric,
        sevenDay: QuotaMetric,
        fetchedAt: Date,
        sourcePath: String,
        rawContent: Data? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
        self.sourcePath = sourcePath
        self.rawContent = rawContent
    }

    func withoutRawContent() -> UsageSnapshot {
        UsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, fetchedAt: fetchedAt, sourcePath: sourcePath)
    }
}

private struct QuotaMetric {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    let available: Bool

    static func unavailable(_ label: String) -> QuotaMetric {
        QuotaMetric(label: label, usedPercent: 0, resetsAt: nil, available: false)
    }

    var remainingPercent: Double {
        available ? min(100, max(0, 100 - usedPercent)) : 0
    }

    var remainingRatio: Double {
        remainingPercent / 100
    }

    var remainingText: String {
        available ? AppDelegate.percent(remainingPercent) : "不可用"
    }
}

private enum IconTone {
    case idle
    case loading
    case normal
    case failed
}

private enum FetchStateKind {
    case idle
    case loading
    case loaded
    case failed
}

private struct FetchState {
    let kind: FetchStateKind
    let usage: UsageSnapshot?
    let message: String?
    let fetchedAt: Date?

    static let idle = FetchState(kind: .idle, usage: nil, message: nil, fetchedAt: nil)

    static func loading(_ previous: UsageSnapshot?) -> FetchState {
        FetchState(kind: .loading, usage: previous, message: nil, fetchedAt: nil)
    }

    static func loaded(_ usage: UsageSnapshot) -> FetchState {
        FetchState(kind: .loaded, usage: usage, message: nil, fetchedAt: nil)
    }

    static func failed(_ message: String, _ fetchedAt: Date, _ previous: UsageSnapshot?) -> FetchState {
        FetchState(kind: .failed, usage: previous, message: message, fetchedAt: fetchedAt)
    }
}
