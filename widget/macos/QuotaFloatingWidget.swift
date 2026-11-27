import Cocoa
import CoreGraphics
import Foundation
import WebKit

// MARK: - Constants & Paths

let SHADOW_MARGIN: CGFloat = 10
let MINI_VIS_WIDTH: CGFloat = 220
let POPOVER_VIS_WIDTH: CGFloat = 332

let POLL_OK_SEC: TimeInterval = 30.0
let POLL_RETRY_SEC: TimeInterval = 5.0
let POLL_INIT_RETRY_SEC: TimeInterval = 2.0
let TRACK_FAST_SEC: TimeInterval = 0.033
let TRACK_IDLE_SEC: TimeInterval = 0.120
let TRACK_FAST_HOLD_SEC: TimeInterval = 0.65
let TICK_SEC: TimeInterval = 30.0
let LIFECYCLE_SEC: TimeInterval = 1.0
let APP_GONE_GRACE_SEC: TimeInterval = 3.0

struct WidgetPaths {
    let appData: URL
    let pluginDirName: String
    let sidecarBase: URL
    let runtimeFile: URL
    let sidecarTokenFile: URL
    let sidecarLog: URL
    let prefsFile: URL
    let widgetLog: URL
    let lockFile: URL

    init(pluginDirName: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.appData = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        self.pluginDirName = pluginDirName
        self.sidecarBase = appData
            .appendingPathComponent("sidecar_data", isDirectory: true)
            .appendingPathComponent(pluginDirName, isDirectory: true)
            .appendingPathComponent("quota_panel", isDirectory: true)
        let dataDir = sidecarBase.appendingPathComponent("data", isDirectory: true)
        self.runtimeFile = dataDir.appendingPathComponent("runtime.json")
        self.sidecarTokenFile = dataDir.appendingPathComponent("sidecar_token.json")
        self.sidecarLog = sidecarBase.appendingPathComponent("logs/sidecar.log")
        self.prefsFile = dataDir.appendingPathComponent("widget_prefs.json")
        self.widgetLog = dataDir.appendingPathComponent("widget.log")
        self.lockFile = dataDir.appendingPathComponent("widget.lock")
    }
}

struct WidgetPrefs: Codable {
    var mode: String = "used"             // "used" | "remaining"
    var dock: String = "docked"           // "docked" | "float"
    var theme: String = "system"          // "system" | "light" | "dark"
    var float_pos: [Int]? = nil           // [x, y] in AppKit global coords
    var auto_exit_with_app: Bool = true
}

func loadPrefs(from url: URL) -> WidgetPrefs {
    var prefs = WidgetPrefs()
    guard let data = try? Data(contentsOf: url),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return prefs
    }
    if let mode = raw["mode"] as? String, mode == "used" || mode == "remaining" {
        prefs.mode = mode
    }
    if let dock = raw["dock"] as? String, dock == "docked" || dock == "float" {
        prefs.dock = dock
    }
    if let theme = raw["theme"] as? String, theme == "system" || theme == "light" || theme == "dark" {
        prefs.theme = theme
    }
    if let fp = raw["float_pos"] as? [NSNumber], fp.count == 2 {
        prefs.float_pos = [fp[0].intValue, fp[1].intValue]
    }
    if let autoExit = raw["auto_exit_with_app"] as? Bool {
        prefs.auto_exit_with_app = autoExit
    }
    return prefs
}

func savePrefs(_ prefs: WidgetPrefs, to url: URL) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(prefs)
        try data.write(to: url, options: .atomic)
    } catch {
        // Ignore preference write errors
    }
}

func logEvent(_ message: String, to logURL: URL) {
    do {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(fmt.string(from: Date())) \(message)"
        var lines: [String] = []
        if let existing = try? String(contentsOf: logURL, encoding: .utf8) {
            lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while lines.last == "" { lines.removeLast() }
        }
        lines.append(line)
        if lines.count > 80 {
            lines = Array(lines.suffix(80))
        }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: logURL, atomically: true, encoding: .utf8)
    } catch {
        // Ignore logging errors
    }
}

func detectMacOSTheme() -> String {
    if let match = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
        return match == .darkAqua ? "dark" : "light"
    }
    if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle"),
       style.lowercased().contains("dark") {
        return "dark"
    }
    return "light"
}

func resolveTheme(_ pref: String) -> String {
    if pref == "light" || pref == "dark" {
        return pref
    }
    return detectMacOSTheme()
}

// MARK: - Single Instance File Lock (flock)

final class SingleInstanceLock {
    private var fd: Int32 = -1

    func acquire(at url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        if descriptor < 0 {
            return true // Proceed if lock file unexpectedly cannot be opened
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }
        ftruncate(descriptor, 0)
        let pidStr = "\(getpid())\n"
        _ = pidStr.withCString { ptr in
            write(descriptor, ptr, strlen(ptr))
        }
        self.fd = descriptor
        return true
    }

    func release() {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    deinit {
        release()
    }
}

// MARK: - Formatting Helpers

func fmtPct(_ value: Any?) -> String {
    guard let num = (value as? NSNumber)?.doubleValue else { return "--" }
    if abs(num - num.rounded()) < 0.05 {
        return "\(Int(num.rounded()))%"
    }
    return String(format: "%.1f%%", num)
}

// MARK: - Sidecar HTTP Client

final class SidecarQuotaClient: @unchecked Sendable {
    private let paths: WidgetPaths
    private let session: URLSession
    private let lock = NSLock()
    private var convCacheTime: TimeInterval = 0
    private var convCacheId: String = ""
    private var fetchingQuota = false
    private var fetchingAccounts = false

    private let idRegex = try! NSRegularExpression(pattern: "^[0-9a-f-]{8,}$", options: [.caseInsensitive])
    private let logPortRegex = try! NSRegularExpression(pattern: "\\[sidecar\\]\\s+listening\\s+on\\s+127\\.0\\.0\\.1:(\\d+)")

    init(paths: WidgetPaths) {
        self.paths = paths
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:] // Bypass system HTTP proxies for 127.0.0.1
        cfg.timeoutIntervalForRequest = 6.0
        cfg.timeoutIntervalForResource = 12.0
        self.session = URLSession(configuration: cfg)
    }

    private func readTokenFile(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = obj["token"] as? String, !tok.isEmpty else {
            return ""
        }
        return tok
    }

    private func readSidecarToken() -> String {
        var candidates: [URL] = [paths.sidecarTokenFile]
        let sidecarRoot = paths.appData.appendingPathComponent("sidecar_data", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(at: sidecarRoot, includingPropertiesForKeys: nil) {
            for dir in items {
                let candidate = dir.appendingPathComponent("quota_panel/data/sidecar_token.json")
                if !candidates.contains(candidate) {
                    candidates.append(candidate)
                }
            }
        }
        for url in candidates {
            let tok = readTokenFile(url)
            if !tok.isEmpty { return tok }
        }
        return ""
    }

    private func extractLastPort(fromLog url: URL) -> Int? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n")
        for line in lines.reversed() {
            let str = String(line)
            let range = NSRange(str.startIndex..<str.endIndex, in: str)
            if let match = logPortRegex.firstMatch(in: str, range: range),
               let portRange = Range(match.range(at: 1), in: str),
               let port = Int(str[portRange]) {
                return port
            }
        }
        return nil
    }

    func discoverEndpoints() -> [(port: Int, token: String)] {
        var endpoints: [(Int, String)] = []
        var seen = Set<Int>()
        let fallbackTok = readSidecarToken()

        func addCandidate(_ portVal: Any?, _ tok: String) {
            guard let num = portVal as? NSNumber else { return }
            let port = num.intValue
            if port > 0 && port < 65536 && !seen.contains(port) {
                seen.insert(port)
                endpoints.append((port, tok.isEmpty ? fallbackTok : tok))
            }
        }

        let primaryTok = {
            let t = readTokenFile(paths.sidecarTokenFile)
            return t.isEmpty ? fallbackTok : t
        }()

        if let data = try? Data(contentsOf: paths.runtimeFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            addCandidate(obj["port"], primaryTok)
        }

        if let port = extractLastPort(fromLog: paths.sidecarLog) {
            addCandidate(port, primaryTok)
        }

        let sidecarRoot = paths.appData.appendingPathComponent("sidecar_data", isDirectory: true)
        if let dirs = try? FileManager.default.contentsOfDirectory(at: sidecarRoot, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let rtURL = dir.appendingPathComponent("quota_panel/data/runtime.json")
                let tokURL = dir.appendingPathComponent("quota_panel/data/sidecar_token.json")
                if let data = try? Data(contentsOf: rtURL),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    addCandidate(obj["port"], readTokenFile(tokURL))
                }
            }
            if endpoints.isEmpty {
                for dir in dirs {
                    let logURL = dir.appendingPathComponent("quota_panel/logs/sidecar.log")
                    let tokURL = dir.appendingPathComponent("quota_panel/data/sidecar_token.json")
                    if let port = extractLastPort(fromLog: logURL) {
                        addCandidate(port, readTokenFile(tokURL))
                    }
                }
            }
        }

        return endpoints
    }

    func discoverPorts() -> [Int] {
        return discoverEndpoints().map { $0.port }
    }

    func findLatestConversationId() -> String {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let cachedAt = convCacheTime
        let cachedId = convCacheId
        lock.unlock()
        if now - cachedAt < 3.0 && !cachedId.isEmpty {
            return cachedId
        }

        let brainDir = paths.appData.appendingPathComponent("brain", isDirectory: true)
        var bestId = ""
        var bestMtime: TimeInterval = -1
        if let entries = try? FileManager.default.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for entry in entries {
                let name = entry.lastPathComponent
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                if idRegex.firstMatch(in: name, range: range) == nil { continue }
                let tr = entry.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: tr.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    let mt = modDate.timeIntervalSince1970
                    if mt > bestMtime {
                        bestMtime = mt
                        bestId = name
                    }
                }
            }
        }

        lock.lock()
        convCacheTime = now
        convCacheId = bestId
        lock.unlock()
        return bestId
    }

    private func requestJSONSync(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeout: TimeInterval = 6.0
    ) -> (payload: [String: Any]?, error: String?, port: Int?) {
        let endpoints = discoverEndpoints()
        if endpoints.isEmpty {
            return (nil, "未检测到 Sidecar 端口，请确认 Antigravity 已启动", nil)
        }

        let isWrite = method.uppercased() != "GET"
        let bodyData: Data? = isWrite ? (try? JSONSerialization.data(withJSONObject: body ?? [:])) : nil

        var lastErr: String?
        var lastPort: Int?
        let total = endpoints.count

        for (idx, ep) in endpoints.enumerated() {
            guard let url = URL(string: "http://127.0.0.1:\(ep.port)\(path)") else { continue }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            req.httpMethod = method.uppercased()
            if isWrite {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let tok = ep.token.isEmpty ? readSidecarToken() : ep.token
                if !tok.isEmpty {
                    req.setValue(tok, forHTTPHeaderField: "X-Sidecar-Token")
                }
                req.httpBody = bodyData
            }

            let sema = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultResp: HTTPURLResponse?
            var resultErr: Error?

            let task = session.dataTask(with: req) { data, resp, err in
                resultData = data
                resultResp = resp as? HTTPURLResponse
                resultErr = err
                sema.signal()
            }
            task.resume()
            _ = sema.wait(timeout: .now() + timeout + 1.0)

            if let err = resultErr {
                lastErr = err.localizedDescription
                lastPort = ep.port
                continue
            }

            let status = resultResp?.statusCode ?? 0
            if status >= 400 {
                var errMsg = "HTTP \(status)"
                if let d = resultData,
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let msg = obj["error"] as? String, !msg.isEmpty {
                    errMsg = msg
                }
                if [401, 404, 405, 502, 503].contains(status) && idx + 1 < total {
                    lastErr = errMsg
                    lastPort = ep.port
                    continue
                }
                return (nil, errMsg, ep.port)
            }

            if let d = resultData, !d.isEmpty {
                if let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    return (obj, obj["error"] as? String, ep.port)
                }
                lastErr = "Invalid JSON response"
                lastPort = ep.port
            } else {
                return ([:], nil, ep.port)
            }
        }

        return (nil, lastErr ?? "无法连接到本地 Sidecar 服务", lastPort)
    }

    func fetchQuotaSync(force: Bool = false) -> (payload: [String: Any]?, error: String?, port: Int?) {
        let convId = findLatestConversationId()
        var queryItems: [String] = []
        if !convId.isEmpty {
            let esc = convId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? convId
            queryItems.append("conversationId=\(esc)")
        }
        if force {
            queryItems.append("force=1")
        }
        let path = queryItems.isEmpty ? "/api/quota" : "/api/quota?\(queryItems.joined(separator: "&"))"
        return requestJSONSync(path: path, method: "GET", timeout: 5.0)
    }

    func fetchAccountsSync() -> (payload: [String: Any]?, error: String?, port: Int?) {
        let convId = findLatestConversationId()
        let esc = convId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? convId
        let path = convId.isEmpty ? "/api/accounts" : "/api/accounts?conversationId=\(esc)"
        return requestJSONSync(path: path, method: "GET", timeout: 5.0)
    }

    func requestFetchQuota(force: Bool = false, completion: @escaping @MainActor @Sendable ([String: Any]?, String?) -> Void) {
        lock.lock()
        if fetchingQuota && !force {
            lock.unlock()
            return
        }
        fetchingQuota = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let res = self.fetchQuotaSync(force: force)
            self.lock.lock()
            self.fetchingQuota = false
            self.lock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(res.payload, res.error)
                }
            }
        }
    }

    func requestFetchAccounts(completion: @escaping @MainActor @Sendable ([String: Any]?, String?) -> Void) {
        lock.lock()
        if fetchingAccounts {
            lock.unlock()
            return
        }
        fetchingAccounts = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let res = self.fetchAccountsSync()
            self.lock.lock()
            self.fetchingAccounts = false
            self.lock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(res.payload, res.error)
                }
            }
        }
    }

    func requestAccountAction(
        action: String,
        path: String,
        body: [String: Any]? = nil,
        completion: @escaping @MainActor @Sendable (String, Bool, [String: Any]?, String?) -> Void
    ) {
        var payloadBody = body ?? [:]
        let convId = findLatestConversationId()
        if !convId.isEmpty && payloadBody["conversationId"] == nil {
            payloadBody["conversationId"] = convId
        }
        logEvent("account_action_start action=\(action)", to: paths.widgetLog)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let res = self.requestJSONSync(path: path, method: "POST", body: payloadBody, timeout: 12.0)
            let ok = res.payload != nil && res.error == nil && ((res.payload?["ok"] as? Bool) != false)
            let safeErr = (res.error ?? "").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(120)
            logEvent("account_action_done action=\(action) ok=\(ok) port=\(res.port.map(String.init) ?? "none") err=\(safeErr.isEmpty ? "none" : String(safeErr))", to: self.paths.widgetLog)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(action, ok, res.payload, res.error)
                }
            }
        }
    }
}

// MARK: - macOS Window Tracker (CoreGraphics + NSWorkspace)

struct TrackedWindow {
    let windowId: Int
    let pid: Int32
    let cgRect: CGRect
    let ownerName: String
    let title: String
}

final class MacOSWindowTracker {
    let ownPid: Int32 = getpid()

    private let ignoredOverlayOwners: Set<String> = [
        "window server",
        "control center",
        "控制中心",
        "notification center",
        "通知中心",
        "systemuiserver",
        "spotlight",
        "聚焦",
    ]

    func primaryScreenHeight() -> CGFloat {
        if let primary = NSScreen.screens.first(where: { abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5 }) {
            return primary.frame.height
        }
        return NSScreen.screens.first?.frame.height ?? 1080
    }

    func cgToAppKit(_ cgRect: CGRect) -> NSRect {
        let primaryH = primaryScreenHeight()
        let nsY = primaryH - cgRect.origin.y - cgRect.height
        return NSRect(x: cgRect.origin.x, y: nsY, width: cgRect.width, height: cgRect.height)
    }

    func appKitToCG(_ nsRect: NSRect) -> CGRect {
        let primaryH = primaryScreenHeight()
        let cgY = primaryH - nsRect.origin.y - nsRect.height
        return CGRect(x: nsRect.origin.x, y: cgY, width: nsRect.width, height: nsRect.height)
    }

    func screen(for nsRect: NSRect) -> NSScreen? {
        let center = NSPoint(x: nsRect.midX, y: nsRect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        if let intersecting = NSScreen.screens.first(where: { $0.frame.intersects(nsRect) }) {
            return intersecting
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    func isParentAlive(_ parentPid: Int32) -> Bool {
        if parentPid <= 1 { return false }
        if getppid() == 1 { return false }
        return kill(parentPid, 0) == 0 || errno == EPERM
    }

    func isAntigravityProcessRunning() -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            if app.isTerminated { continue }
            let bundleId = (app.bundleIdentifier ?? "").lowercased()
            let name = (app.localizedName ?? "").lowercased()
            let exe = (app.executableURL?.lastPathComponent ?? "").lowercased()
            if bundleId.contains("antigravity") || name == "antigravity" || exe == "antigravity" {
                return true
            }
        }
        return false
    }

    func frontmostPid() -> Int32 {
        return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }

    private func isAntigravityWindow(owner: String, title: String, pid: Int32) -> Bool {
        let ownerLow = owner.lowercased()
        let titleLow = title.lowercased()
        if ownerLow.contains("antigravity") && !ownerLow.contains("helper") {
            return true
        }
        if titleLow.contains("antigravity") {
            if let app = NSRunningApplication(processIdentifier: pid),
               let bundle = app.bundleIdentifier?.lowercased(),
               bundle.contains("antigravity") {
                return true
            }
            if ownerLow == "electron" || ownerLow.contains("antigravity") {
                return true
            }
        }
        return false
    }

    func inspectAntigravityAndOcclusion(cardVisibleCGRect: CGRect?) -> (window: TrackedWindow?, occluded: Bool, totalWindows: Int) {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return (nil, false, 0)
        }

        var agyIndex: Int?
        var agyWin: TrackedWindow?
        var parsedBeforeAgy: [(pid: Int32, rect: CGRect)] = []

        for (idx, info) in list.enumerated() {
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if pid == ownPid { continue }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer < 0 || layer >= 20 { continue } // Ignore Dock (20), Menubar (24), StatusIndicator

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            if alpha <= 0.01 { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            if rect.width < 24 || rect.height < 24 { continue }

            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let wid = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0

            if layer == 0 && rect.width >= 600 && rect.height >= 400 && isAntigravityWindow(owner: owner, title: title, pid: pid) {
                agyIndex = idx
                agyWin = TrackedWindow(windowId: wid, pid: pid, cgRect: rect, ownerName: owner, title: title)
                break
            }

            let ownerLow = owner.lowercased()
            if ignoredOverlayOwners.contains(ownerLow) {
                continue
            }

            parsedBeforeAgy.append((pid: pid, rect: rect))
        }

        guard let target = agyWin, agyIndex != nil else {
            return (nil, false, list.count)
        }

        var occluded = false
        if let cardRect = cardVisibleCGRect {
            for item in parsedBeforeAgy {
                if item.rect.intersects(cardRect) {
                    occluded = true
                    break
                }
            }
        }

        return (target, occluded, list.count)
    }

    func findAntigravityWindow() -> TrackedWindow? {
        return inspectAntigravityAndOcclusion(cardVisibleCGRect: nil).window
    }
}

// MARK: - Native Floating Panel & WebView

final class FloatingPanel: NSPanel {
    private let allowKey: Bool

    init(contentRect: NSRect, allowKey: Bool) {
        self.allowKey = allowKey
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isMovableByWindowBackground = false
        self.acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { return allowKey }
    override var canBecomeMain: Bool { return false }
}

final class ClickableWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }
}

final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

final class MenuActionProxy: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }
    @objc func invoke(_ sender: Any?) {
        handler()
    }
}

// MARK: - Tray Icon Drawing

func buildStatusBarImage() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let img = NSImage(size: size, flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        // Rounded dark badge
        let badgeRect = NSRect(x: 1, y: 1, width: 16, height: 16)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 4.0, yRadius: 4.0)
        NSColor(srgbRed: 0.118, green: 0.161, blue: 0.231, alpha: 1.0).setFill()
        badgePath.fill()

        // Track arc
        let center = NSPoint(x: 9, y: 9)
        let trackArc = NSBezierPath()
        trackArc.appendArc(withCenter: center, radius: 5.0, startAngle: -45, endAngle: 225, clockwise: false)
        trackArc.lineWidth = 1.8
        trackArc.lineCapStyle = .round
        NSColor(srgbRed: 0.278, green: 0.333, blue: 0.412, alpha: 1.0).setStroke()
        trackArc.stroke()

        // Active sky-blue arc
        let activeArc = NSBezierPath()
        activeArc.appendArc(withCenter: center, radius: 5.0, startAngle: 90, endAngle: 225, clockwise: false)
        activeArc.lineWidth = 1.8
        activeArc.lineCapStyle = .round
        NSColor(srgbRed: 0.220, green: 0.741, blue: 0.973, alpha: 1.0).setStroke()
        activeArc.stroke()

        // Center green bars
        NSColor(srgbRed: 0.133, green: 0.773, blue: 0.369, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: NSRect(x: 5.8, y: 4.2, width: 1.5, height: 3.6), xRadius: 0.6, yRadius: 0.6).fill()
        NSBezierPath(roundedRect: NSRect(x: 8.2, y: 4.2, width: 1.5, height: 5.8), xRadius: 0.6, yRadius: 0.6).fill()
        NSBezierPath(roundedRect: NSRect(x: 10.6, y: 4.2, width: 1.5, height: 4.7), xRadius: 0.6, yRadius: 0.6).fill()

        return true
    }
    img.isTemplate = false
    return img
}

// MARK: - Main Controller

@MainActor
final class QuotaWidgetController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSMenuDelegate {
    private let paths: WidgetPaths
    private let htmlURL: URL
    private let enableTray: Bool
    private let client: SidecarQuotaClient
    private let tracker = MacOSWindowTracker()

    private var prefs: WidgetPrefs
    private var payload: [String: Any]?
    private var accountsData: [String: Any]?
    private var errorMsg: String?
    private var actionBanner: (kind: String, text: String)?
    private var busyAction: String?

    private var expanded = false
    private var manualHidden = false
    private var activeTab = "quota"
    private var popoverRaisedByUser = false
    private var popoverHasActiveInteraction = false

    private let isSidecar: Bool
    private let parentPid: Int32
    private var seenAntigravity = false
    private var missingSince: TimeInterval?
    private var everConnected = false

    private var miniSize = NSSize(width: MINI_VIS_WIDTH + SHADOW_MARGIN * 2, height: 150)
    private var popoverSize = NSSize(width: POPOVER_VIS_WIDTH + SHADOW_MARGIN * 2, height: 340)
    private var miniReady = false
    private var popoverReady = false

    private var dragStartOrigin: NSPoint?
    private var lastAgyCGRect: CGRect?
    private var fastTrackUntil: TimeInterval = 0
    private var currentTrackInterval: TimeInterval = TRACK_IDLE_SEC

    private let miniPanel: FloatingPanel
    private let popoverPanel: FloatingPanel
    private let miniWebView: ClickableWebView
    private let popoverWebView: ClickableWebView

    private var statusItem: NSStatusItem?
    private var statusMenu = NSMenu()
    private var contextMenu = NSMenu()
    private var menuProxies: [MenuActionProxy] = []

    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var trackTimer: Timer?
    private var lifecycleTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(paths: WidgetPaths, htmlURL: URL, enableTray: Bool) {
        self.paths = paths
        self.htmlURL = htmlURL
        self.enableTray = enableTray
        self.client = SidecarQuotaClient(paths: paths)
        self.prefs = loadPrefs(from: paths.prefsFile)
        let lsAddr = ProcessInfo.processInfo.environment["ANTIGRAVITY_LS_ADDRESS"] ?? ""
        let detachedFlag = CommandLine.arguments.contains("--detached")
        let ppid = getppid()
        self.isSidecar = !lsAddr.isEmpty && !detachedFlag && ppid > 1
        self.parentPid = self.isSidecar ? ppid : 0

        self.miniPanel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: MINI_VIS_WIDTH + SHADOW_MARGIN * 2, height: 150),
            allowKey: false
        )
        self.popoverPanel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: POPOVER_VIS_WIDTH + SHADOW_MARGIN * 2, height: 340),
            allowKey: true
        )

        let miniCfg = WKWebViewConfiguration()
        let popCfg = WKWebViewConfiguration()
        self.miniWebView = ClickableWebView(frame: .zero, configuration: miniCfg)
        self.popoverWebView = ClickableWebView(frame: .zero, configuration: popCfg)

        super.init()

        let handler = WeakScriptHandler(target: self)
        miniCfg.userContentController.add(handler, name: "bridge")
        popCfg.userContentController.add(handler, name: "bridge")

        configureWebView(miniWebView, in: miniPanel, viewName: "mini")
        configureWebView(popoverWebView, in: popoverPanel, viewName: "popover")

        if enableTray {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = buildStatusBarImage()
            item.button?.toolTip = "Antigravity 模型用量浮窗"
            statusMenu.delegate = self
            item.menu = statusMenu
            self.statusItem = item
        }
    }

    private func configureWebView(_ webView: ClickableWebView, in panel: FloatingPanel, viewName: String) {
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.frame = panel.contentView?.bounds ?? .zero
        panel.contentView?.addSubview(webView)

        var comps = URLComponents(url: htmlURL, resolvingAgainstBaseURL: true)!
        comps.queryItems = [URLQueryItem(name: "view", value: viewName)]
        if let url = comps.url {
            webView.loadFileURL(url, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }
    }

    func start() {
        let win = tracker.findAntigravityWindow()
        if win != nil {
            seenAntigravity = true
        }
        logEvent(
            "started pid=\(getpid()) ppid=\(parentPid) sidecar=\(isSidecar) " +
            "agy_wid=\(win?.windowId ?? 0) dock=\(prefs.dock)",
            to: paths.widgetLog
        )

        setupObservers()
        startTimers()

        if prefs.dock == "float" {
            placeFloatInitial()
            miniPanel.orderFrontRegardless()
        } else {
            updateDockPosition()
        }

        pollAll()
    }

    private func setupObservers() {
        let wsnc = NSWorkspace.shared.notificationCenter
        let triggerDockSync: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.fastTrackUntil = ProcessInfo.processInfo.systemUptime + TRACK_FAST_HOLD_SEC
                self.ensureTrackTimerInterval(TRACK_FAST_SEC)
                if self.prefs.dock == "docked" {
                    self.updateDockPosition()
                }
            }
        }

        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            observers.append(wsnc.addObserver(forName: name, object: nil, queue: .main, using: triggerDockSync))
        }

        observers.append(wsnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.checkAppLifecycle()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.prefs.dock == "docked" {
                    self.updateDockPosition()
                } else {
                    self.placeFloatInitial()
                    if self.expanded { self.positionPopover() }
                }
            }
        })

        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pushStateToWebViews(passiveTimestampsOnly: false)
            }
        })
    }

    private func startTimers() {
        schedulePollTimer(interval: POLL_OK_SEC)

        tickTimer = Timer.scheduledTimer(withTimeInterval: TICK_SEC, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.onUITick()
            }
        }

        lifecycleTimer = Timer.scheduledTimer(withTimeInterval: LIFECYCLE_SEC, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAppLifecycle()
            }
        }

        if prefs.dock == "docked" {
            ensureTrackTimerInterval(TRACK_IDLE_SEC)
        }
    }

    private func schedulePollTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollAll()
            }
        }
    }

    private func ensureTrackTimerInterval(_ interval: TimeInterval) {
        if trackTimer != nil && abs(currentTrackInterval - interval) < 0.002 {
            return
        }
        currentTrackInterval = interval
        trackTimer?.invalidate()
        trackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateDockPosition()
            }
        }
    }

    private func pollAll() {
        client.requestFetchQuota(force: false) { [weak self] payload, err in
            self?.onQuotaFetched(payload: payload, error: err)
        }
        client.requestFetchAccounts { [weak self] accounts, _ in
            self?.onAccountsFetched(accountsData: accounts)
        }
    }

    private func refreshAll() {
        client.requestFetchQuota(force: true) { [weak self] payload, err in
            self?.onQuotaFetched(payload: payload, error: err)
        }
        client.requestFetchAccounts { [weak self] accounts, _ in
            self?.onAccountsFetched(accountsData: accounts)
        }
    }

    private func onQuotaFetched(payload: [String: Any]?, error: String?) {
        if let payload = payload {
            self.payload = payload
            self.errorMsg = error
            schedulePollTimer(interval: POLL_OK_SEC)
            if !everConnected {
                everConnected = true
                let cur = payload["current"] as? [String: Any]
                let curId = (cur?["modelId"] as? String) ?? "unknown"
                let grpCnt = (payload["groups"] as? [Any])?.count ?? 0
                logEvent("connected model=\(curId) groups=\(grpCnt)", to: paths.widgetLog)
            }
        } else {
            self.errorMsg = error ?? "连接失败"
            schedulePollTimer(interval: everConnected ? POLL_RETRY_SEC : POLL_INIT_RETRY_SEC)
        }

        renderPassiveUpdate()
        if prefs.dock == "docked" {
            updateDockPosition()
        }
    }

    private func onAccountsFetched(accountsData: [String: Any]?) {
        guard let accountsData = accountsData else { return }
        self.accountsData = accountsData
        renderPassiveUpdate()
    }

    private func isUserInteractingWithPopover() -> Bool {
        if !(expanded && popoverPanel.isVisible) { return false }
        if popoverHasActiveInteraction || busyAction != nil { return true }
        let mouseLoc = NSEvent.mouseLocation
        if NSEvent.pressedMouseButtons != 0 && popoverPanel.frame.contains(mouseLoc) {
            return true
        }
        return false
    }

    private func onUITick() {
        if expanded && popoverPanel.isVisible && activeTab == "accounts" {
            pushStateToWebViews(passiveTimestampsOnly: true)
            updateTrayTooltip()
            return
        }
        renderPassiveUpdate()
    }

    private func renderPassiveUpdate() {
        if isUserInteractingWithPopover() {
            pushStateToWebViews(passiveTimestampsOnly: true)
            updateTrayTooltip()
            return
        }
        pushStateToWebViews(passiveTimestampsOnly: false)
        updateTrayTooltip()
    }

    private func buildStateDictionary(passiveTimestampsOnly: Bool) -> [String: Any] {
        let screen = tracker.screen(for: miniPanel.frame) ?? NSScreen.main ?? NSScreen.screens.first
        let maxAvailH = Int((screen?.visibleFrame.height ?? 720) - 120)
        var dict: [String: Any] = [
            "theme": resolveTheme(prefs.theme),
            "mode": prefs.mode,
            "dock": prefs.dock,
            "expanded": expanded,
            "activeTab": activeTab,
            "passiveTimestampsOnly": passiveTimestampsOnly,
            "maxScrollHeight": max(220, min(460, maxAvailH)),
        ]
        dict["payload"] = payload ?? NSNull()
        dict["accountsData"] = accountsData ?? NSNull()
        dict["errorMsg"] = errorMsg ?? NSNull()
        if let banner = actionBanner {
            dict["actionBanner"] = ["kind": banner.kind, "text": banner.text]
        } else {
            dict["actionBanner"] = NSNull()
        }
        dict["busyAction"] = busyAction ?? NSNull()
        return dict
    }

    private func pushStateToWebViews(passiveTimestampsOnly: Bool) {
        let stateDict = buildStateDictionary(passiveTimestampsOnly: passiveTimestampsOnly)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: stateDict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return
        }
        let js = "window.__WIDGET_API__ && window.__WIDGET_API__.setState(\(jsonStr));"
        if miniReady {
            miniWebView.evaluateJavaScript(js, completionHandler: nil)
        }
        if popoverReady {
            popoverWebView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - WKNavigationDelegate & WKScriptMessageHandler

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === miniWebView {
            miniReady = true
        } else if webView === popoverWebView {
            popoverReady = true
        }
        pushStateToWebViews(passiveTimestampsOnly: false)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            let view = body["view"] as? String ?? ""
            if view == "mini" { miniReady = true }
            if view == "popover" { popoverReady = true }
            pushStateToWebViews(passiveTimestampsOnly: false)

        case "resize":
            let view = body["view"] as? String ?? ""
            let w = CGFloat((body["width"] as? NSNumber)?.doubleValue ?? 0)
            let h = CGFloat((body["height"] as? NSNumber)?.doubleValue ?? 0)
            if w > 0 && h > 0 {
                onWebViewResize(view: view, width: w, height: h)
            }

        case "toggleExpand":
            toggleExpand()

        case "toggleDock":
            toggleDockMode()

        case "toggleMode":
            toggleDisplayMode()

        case "refresh":
            refreshAll()

        case "close":
            collapse()

        case "selectTab":
            if let tab = body["tab"] as? String, tab == "quota" || tab == "accounts" {
                activeTab = tab
                if tab == "accounts" {
                    client.requestFetchAccounts { [weak self] accs, _ in
                        self?.onAccountsFetched(accountsData: accs)
                    }
                }
                if expanded && miniPanel.isVisible {
                    positionPopover()
                }
            }

        case "dragStart":
            if prefs.dock == "float" {
                dragStartOrigin = miniPanel.frame.origin
            }

        case "dragMove":
            if prefs.dock == "float", let start = dragStartOrigin {
                let dx = CGFloat((body["dx"] as? NSNumber)?.doubleValue ?? 0)
                let dy = CGFloat((body["dy"] as? NSNumber)?.doubleValue ?? 0)
                let nextOrigin = NSPoint(x: start.x + dx, y: start.y - dy)
                miniPanel.setFrameOrigin(nextOrigin)
                if expanded && popoverPanel.isVisible {
                    positionPopover()
                }
            }

        case "dragEnd":
            if prefs.dock == "float" {
                let clamped = clampPanelOrigin(miniPanel.frame.origin, panelSize: miniPanel.frame.size)
                miniPanel.setFrameOrigin(clamped)
                prefs.float_pos = [Int(round(clamped.x)), Int(round(clamped.y))]
                savePrefs(prefs, to: paths.prefsFile)
                dragStartOrigin = nil
                if expanded && popoverPanel.isVisible {
                    positionPopover()
                }
            }

        case "contextMenu":
            showContextMenu()

        case "captureAccount":
            captureCurrentAccount()

        case "importAgySwitch":
            importAgySwitch()

        case "switchAccount":
            if let aid = body["id"] as? String, !aid.isEmpty {
                triggerAccountSwitch(accountId: aid)
            }

        case "interactionState":
            popoverHasActiveInteraction = (body["active"] as? Bool) ?? false

        default:
            break
        }
    }

    private func onWebViewResize(view: String, width: CGFloat, height: CGFloat) {
        if view == "mini" {
            let newSize = NSSize(width: width, height: height)
            if abs(miniSize.width - newSize.width) > 0.5 || abs(miniSize.height - newSize.height) > 0.5 {
                let oldFrame = miniPanel.frame
                miniSize = newSize
                let newOrigin = NSPoint(x: oldFrame.origin.x, y: oldFrame.origin.y + (oldFrame.height - newSize.height))
                miniPanel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
                if prefs.dock == "docked" {
                    updateDockPosition()
                } else if expanded && popoverPanel.isVisible {
                    positionPopover()
                }
            }
        } else if view == "popover" {
            let newSize = NSSize(width: width, height: height)
            if abs(popoverSize.width - newSize.width) > 0.5 || abs(popoverSize.height - newSize.height) > 0.5 {
                popoverSize = newSize
                popoverPanel.setContentSize(newSize)
                if expanded && miniPanel.isVisible {
                    positionPopover()
                }
            }
        }
    }

    // MARK: - Actions & State Transitions

    func toggleExpand() {
        if expanded {
            collapse()
        } else {
            expanded = true
            popoverRaisedByUser = true
            pushStateToWebViews(passiveTimestampsOnly: false)
            positionPopover()
            if prefs.dock == "float" {
                miniPanel.orderFrontRegardless()
                popoverPanel.order(.above, relativeTo: miniPanel.windowNumber)
                popoverPanel.makeKey()
            } else {
                updateDockPosition()
                if popoverPanel.isVisible {
                    popoverPanel.makeKey()
                }
            }
        }
    }

    func collapse() {
        expanded = false
        popoverRaisedByUser = false
        popoverHasActiveInteraction = false
        popoverPanel.orderOut(nil)
        pushStateToWebViews(passiveTimestampsOnly: false)
        if prefs.dock == "docked" {
            updateDockPosition()
        }
    }

    func toggleDisplayMode() {
        prefs.mode = prefs.mode == "used" ? "remaining" : "used"
        savePrefs(prefs, to: paths.prefsFile)
        renderPassiveUpdate()
    }

    func setDisplayMode(_ mode: String) {
        if prefs.mode != mode {
            prefs.mode = mode
            savePrefs(prefs, to: paths.prefsFile)
            renderPassiveUpdate()
        }
    }

    func toggleDockMode() {
        setDockMode(prefs.dock == "docked" ? "float" : "docked")
    }

    func setDockMode(_ dock: String) {
        prefs.dock = dock
        savePrefs(prefs, to: paths.prefsFile)
        manualHidden = false
        if dock == "float" {
            trackTimer?.invalidate()
            trackTimer = nil
            pushStateToWebViews(passiveTimestampsOnly: false)
            placeFloatInitial()
            miniPanel.orderFrontRegardless()
            if expanded {
                positionPopover()
                popoverPanel.order(.above, relativeTo: miniPanel.windowNumber)
            }
        } else {
            pushStateToWebViews(passiveTimestampsOnly: false)
            ensureTrackTimerInterval(TRACK_IDLE_SEC)
            updateDockPosition()
        }
    }

    func setThemePref(_ themePref: String) {
        prefs.theme = themePref
        savePrefs(prefs, to: paths.prefsFile)
        pushStateToWebViews(passiveTimestampsOnly: false)
    }

    func toggleAutoExit() {
        prefs.auto_exit_with_app.toggle()
        savePrefs(prefs, to: paths.prefsFile)
    }

    func toggleVisible() {
        if miniPanel.isVisible {
            manualHidden = true
            miniPanel.orderOut(nil)
            popoverPanel.orderOut(nil)
        } else {
            manualHidden = false
            if prefs.dock == "docked" {
                updateDockPosition()
            } else {
                miniPanel.orderFrontRegardless()
                if expanded {
                    positionPopover()
                    popoverPanel.order(.above, relativeTo: miniPanel.windowNumber)
                }
            }
        }
    }

    private func captureCurrentAccount() {
        busyAction = "capture"
        actionBanner = ("info", "正在保存当前登录凭据快照...")
        pushStateToWebViews(passiveTimestampsOnly: false)
        client.requestAccountAction(action: "capture", path: "/api/accounts/capture") { [weak self] action, ok, payload, err in
            self?.onAccountActionDone(action: action, ok: ok, payload: payload, err: err)
        }
    }

    private func importAgySwitch() {
        busyAction = "import_agy"
        actionBanner = ("info", "正在从 agy-switch 本地库导入账号...")
        pushStateToWebViews(passiveTimestampsOnly: false)
        client.requestAccountAction(action: "import_agy", path: "/api/accounts/import-agy-switch") { [weak self] action, ok, payload, err in
            self?.onAccountActionDone(action: action, ok: ok, payload: payload, err: err)
        }
    }

    private func triggerAccountSwitch(accountId: String) {
        busyAction = "switch"
        actionBanner = ("info", "正在启动后台切换，Antigravity 即将重启...")
        pushStateToWebViews(passiveTimestampsOnly: false)
        client.requestAccountAction(action: "switch", path: "/api/accounts/switch", body: ["id": accountId]) { [weak self] action, ok, payload, err in
            self?.onAccountActionDone(action: action, ok: ok, payload: payload, err: err)
        }
    }

    private func onAccountActionDone(action: String, ok: Bool, payload: [String: Any]?, err: String?) {
        busyAction = nil
        if let accState = payload?["accountsState"] as? [String: Any] {
            accountsData = accState
        }

        if !ok {
            actionBanner = ("error", err ?? "操作失败")
            pushStateToWebViews(passiveTimestampsOnly: false)
            return
        }

        if action == "capture" {
            let acc = (payload?["account"] as? [String: Any]) ?? [:]
            let email = (acc["email"] as? String) ?? ""
            let created = (payload?["created"] as? Bool) ?? false
            actionBanner = ("success", created ? "已保存账号快照: \(email)" : "已更新账号凭据: \(email)")
        } else if action == "import_agy" {
            let imp = (payload?["imported"] as? NSNumber)?.intValue ?? 0
            let upd = (payload?["updated"] as? NSNumber)?.intValue ?? 0
            let skp = (payload?["skipped"] as? NSNumber)?.intValue ?? 0
            let skpText = skp > 0 ? "，跳过 \(skp)" : ""
            actionBanner = ("success", "导入完成：新增 \(imp)，更新 \(upd)\(skpText)")
        } else if action == "switch" {
            let msg = (payload?["message"] as? String) ?? "已启动后台切换，Antigravity 即将重启..."
            actionBanner = ("info", msg)
        }

        pushStateToWebViews(passiveTimestampsOnly: false)
    }

    private func confirmAndSwitchFromMenu(_ acc: [String: Any]) {
        guard let targetId = acc["id"] as? String, !targetId.isEmpty else { return }
        let email = (acc["email"] as? String) ?? ""
        let remark = (acc["remark"] as? String) ?? ""
        let label = !remark.isEmpty ? "\(remark) (\(email))" : email

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "确认切换账号并重启？"
        alert.informativeText = "即将切换到：\(label)\n\n切换将关闭并重启 Antigravity（同步更新 agy CLI），进行中的任务不会迁移。"
        alert.addButton(withTitle: "确认重启切换")
        alert.addButton(withTitle: "取消")
        alert.window.level = .floating

        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            triggerAccountSwitch(accountId: targetId)
        }
    }

    // MARK: - Positioning & Docking

    private func clampPanelOrigin(_ origin: NSPoint, panelSize: NSSize) -> NSPoint {
        let visW = panelSize.width - SHADOW_MARGIN * 2
        let visH = panelSize.height - SHADOW_MARGIN * 2
        let probe = NSRect(origin: origin, size: panelSize)
        let scr = tracker.screen(for: probe) ?? NSScreen.main ?? NSScreen.screens.first
        let avail = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)

        let minX = avail.minX - SHADOW_MARGIN
        let maxX = avail.maxX - visW - SHADOW_MARGIN
        let minY = avail.minY - SHADOW_MARGIN
        let maxY = avail.maxY - visH - SHADOW_MARGIN

        let cx = max(minX, min(origin.x, maxX))
        let cy = max(minY, min(origin.y, maxY))
        return NSPoint(x: cx, y: cy)
    }

    private func placeFloatInitial() {
        let visW = miniSize.width - SHADOW_MARGIN * 2
        let visH = miniSize.height - SHADOW_MARGIN * 2
        let primary = NSScreen.main ?? NSScreen.screens.first
        let avail = primary?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)

        var origin: NSPoint
        if let fp = prefs.float_pos, fp.count == 2 {
            origin = NSPoint(x: CGFloat(fp[0]), y: CGFloat(fp[1]))
        } else {
            // Bottom-left area
            origin = NSPoint(
                x: avail.minX + 18 - SHADOW_MARGIN,
                y: avail.minY + 48 - SHADOW_MARGIN
            )
        }
        origin = clampPanelOrigin(origin, panelSize: NSSize(width: visW + SHADOW_MARGIN * 2, height: visH + SHADOW_MARGIN * 2))
        miniPanel.setFrame(NSRect(origin: origin, size: miniSize), display: true)
    }

    private func positionPopover() {
        let miniFrame = miniPanel.frame
        let scr = tracker.screen(for: miniFrame) ?? NSScreen.main ?? NSScreen.screens.first
        let avail = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)

        let popVisW = popoverSize.width - SHADOW_MARGIN * 2
        let popVisH = popoverSize.height - SHADOW_MARGIN * 2
        let miniVisLeft = miniFrame.minX + SHADOW_MARGIN
        let miniVisRight = miniFrame.maxX - SHADOW_MARGIN
        let miniVisBottom = miniFrame.minY + SHADOW_MARGIN

        var popVisLeft = miniVisRight + 8
        if popVisLeft + popVisW > avail.maxX {
            popVisLeft = miniVisLeft - 8 - popVisW
        }
        popVisLeft = max(avail.minX, min(popVisLeft, avail.maxX - popVisW))

        var popVisBottom = miniVisBottom
        popVisBottom = max(avail.minY, min(popVisBottom, avail.maxY - popVisH))

        let origin = NSPoint(x: popVisLeft - SHADOW_MARGIN, y: popVisBottom - SHADOW_MARGIN)
        popoverPanel.setFrame(NSRect(origin: origin, size: popoverSize), display: true)
    }

    func updateDockPosition() {
        if prefs.dock != "docked" { return }
        if manualHidden {
            miniPanel.orderOut(nil)
            popoverPanel.orderOut(nil)
            return
        }

        // First find Antigravity window without occlusion rect to compute exact anchor rect
        guard let agyWin = tracker.findAntigravityWindow() else {
            lastAgyCGRect = nil
            ensureTrackTimerInterval(TRACK_IDLE_SEC)

            if seenAntigravity {
                miniPanel.orderOut(nil)
                popoverPanel.orderOut(nil)
                return
            }

            let primary = NSScreen.main ?? NSScreen.screens.first
            let avail = primary?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
            let visW = miniSize.width - SHADOW_MARGIN * 2
            let visH = miniSize.height - SHADOW_MARGIN * 2
            var origin = NSPoint(x: avail.minX + 10 - SHADOW_MARGIN, y: avail.minY + 48 - SHADOW_MARGIN)
            origin = clampPanelOrigin(origin, panelSize: NSSize(width: visW + SHADOW_MARGIN * 2, height: visH + SHADOW_MARGIN * 2))
            if miniPanel.frame.origin != origin || miniPanel.frame.size != miniSize {
                miniPanel.setFrame(NSRect(origin: origin, size: miniSize), display: true)
            }
            if !miniPanel.isVisible {
                miniPanel.orderFrontRegardless()
            }
            if expanded {
                positionPopover()
                if !popoverPanel.isVisible {
                    popoverPanel.order(.above, relativeTo: miniPanel.windowNumber)
                }
            }
            return
        }

        seenAntigravity = true
        let now = ProcessInfo.processInfo.systemUptime
        if let prevRect = lastAgyCGRect, prevRect != agyWin.cgRect {
            fastTrackUntil = now + TRACK_FAST_HOLD_SEC
        }
        lastAgyCGRect = agyWin.cgRect
        ensureTrackTimerInterval(now < fastTrackUntil ? TRACK_FAST_SEC : TRACK_IDLE_SEC)

        let agyNsRect = tracker.cgToAppKit(agyWin.cgRect)
        let scr = tracker.screen(for: agyNsRect) ?? NSScreen.main ?? NSScreen.screens.first
        let avail = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)

        let visW = miniSize.width - SHADOW_MARGIN * 2
        let visH = miniSize.height - SHADOW_MARGIN * 2
        var targetVisX = agyNsRect.minX + 10
        var targetVisY = agyNsRect.minY + 46

        targetVisX = max(avail.minX, min(targetVisX, avail.maxX - visW))
        targetVisY = max(avail.minY, min(targetVisY, avail.maxY - visH))

        let targetOrigin = NSPoint(x: targetVisX - SHADOW_MARGIN, y: targetVisY - SHADOW_MARGIN)
        let cardVisCGRect = tracker.appKitToCG(NSRect(x: targetVisX, y: targetVisY, width: visW, height: visH))

        let fgPid = tracker.frontmostPid()
        if popoverRaisedByUser && fgPid != 0 && fgPid != tracker.ownPid && fgPid != agyWin.pid {
            let mouseLoc = NSEvent.mouseLocation
            if !(popoverPanel.frame.contains(mouseLoc) || popoverHasActiveInteraction || busyAction != nil) {
                popoverRaisedByUser = false
            }
        }

        let raiseForPopover = expanded && (
            popoverRaisedByUser ||
            fgPid == tracker.ownPid ||
            popoverHasActiveInteraction ||
            busyAction != nil
        )

        let inspection = tracker.inspectAntigravityAndOcclusion(cardVisibleCGRect: cardVisCGRect)
        if inspection.occluded && !raiseForPopover {
            miniPanel.orderOut(nil)
            popoverPanel.orderOut(nil)
            return
        }

        if miniPanel.frame.origin != targetOrigin || miniPanel.frame.size != miniSize {
            miniPanel.setFrame(NSRect(origin: targetOrigin, size: miniSize), display: true)
        }
        if !miniPanel.isVisible {
            miniPanel.orderFrontRegardless()
        }
        if expanded {
            positionPopover()
            if !popoverPanel.isVisible {
                popoverPanel.order(.above, relativeTo: miniPanel.windowNumber)
            }
        }
    }

    // MARK: - Lifecycle

    func checkAppLifecycle() {
        if isSidecar && parentPid > 0 && !tracker.isParentAlive(parentPid) {
            logEvent("auto_exit reason=parent_ls_exited", to: paths.widgetLog)
            quitApp()
            return
        }

        if !prefs.auto_exit_with_app {
            return
        }

        // Important: check runningApplications (NOT OnScreenOnly windows) so minimizing or switching Spaces never triggers exit!
        if tracker.isAntigravityProcessRunning() {
            seenAntigravity = true
            missingSince = nil
        } else if seenAntigravity {
            let now = ProcessInfo.processInfo.systemUptime
            if missingSince == nil {
                missingSince = now
            } else if let start = missingSince, now - start >= APP_GONE_GRACE_SEC {
                logEvent("auto_exit reason=antigravity_exited", to: paths.widgetLog)
                quitApp()
            }
        }
    }

    func quitApp() {
        pollTimer?.invalidate()
        tickTimer?.invalidate()
        trackTimer?.invalidate()
        lifecycleTimer?.invalidate()
        for obs in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            NotificationCenter.default.removeObserver(obs)
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        observers.removeAll()
        popoverPanel.orderOut(nil)
        miniPanel.orderOut(nil)
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        NSApp.terminate(nil)
    }

    // MARK: - Tray & Context Menu

    private func updateTrayTooltip() {
        guard let btn = statusItem?.button else { return }
        let cur = payload?["current"] as? [String: Any]
        let liveAcc = (accountsData?["liveAccount"] as? [String: Any]) ?? (payload?["account"] as? [String: Any])
        let liveEmail = (liveAcc?["email"] as? String) ?? ""

        guard let cur = cur else {
            btn.toolTip = liveEmail.isEmpty ? "Antigravity 模型用量浮窗" : "Antigravity 模型用量浮窗\n\(liveEmail)"
            return
        }

        let label = (cur["label"] as? String) ?? "当前模型"
        let fh = cur["fiveHour"] as? [String: Any]
        let wk = cur["weekly"] as? [String: Any]
        let isUsed = prefs.mode == "used"
        let key = isUsed ? "usedPercent" : "remainingPercent"
        let prefix = isUsed ? "已用" : "剩余"
        let fhTxt = fh != nil ? "5h \(prefix) \(fmtPct(fh?[key]))" : "5h 仅周限额"
        let wkTxt = wk != nil ? "1周 \(prefix) \(fmtPct(wk?[key]))" : ""
        let head = liveEmail.isEmpty ? label : "\(liveEmail) · \(label)"
        let tail = [fhTxt, wkTxt].filter { !$0.isEmpty }.joined(separator: " | ")
        btn.toolTip = "\(head)\n\(tail)"
    }

    private func addItem(
        to menu: NSMenu,
        title: String,
        checked: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        let proxy = MenuActionProxy(action)
        menuProxies.append(proxy)
        let item = NSMenuItem(title: title, action: #selector(MenuActionProxy.invoke(_:)), keyEquivalent: "")
        item.target = proxy
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menuProxies.removeAll()

        addItem(to: menu, title: miniPanel.isVisible ? "隐藏浮窗" : "显示浮窗") { [weak self] in
            self?.toggleVisible()
        }
        addItem(to: menu, title: expanded ? "收起全部模型" : "展开全部模型") { [weak self] in
            self?.toggleExpand()
        }

        // Accounts submenu
        let acctItem = NSMenuItem(title: "账号切换", action: nil, keyEquivalent: "")
        let acctMenu = NSMenu(title: "账号切换")
        let accData = accountsData ?? [:]
        let liveAcc = (accData["liveAccount"] as? [String: Any]) ?? (payload?["account"] as? [String: Any])
        let liveEmail = (liveAcc?["email"] as? String) ?? ""

        let hdr = NSMenuItem(title: "当前: \(liveEmail.isEmpty ? "未检测到在线账号" : liveEmail)", action: nil, keyEquivalent: "")
        hdr.isEnabled = false
        acctMenu.addItem(hdr)

        addItem(to: acctMenu, title: "保存当前账号快照") { [weak self] in
            self?.captureCurrentAccount()
        }

        let agyCnt = (accData["agySwitchCount"] as? NSNumber)?.intValue ?? 0
        let impTitle = agyCnt > 0 ? "从 agy-switch 导入 (\(agyCnt))" : "从 agy-switch 导入"
        addItem(to: acctMenu, title: impTitle) { [weak self] in
            self?.importAgySwitch()
        }

        let accounts = (accData["accounts"] as? [[String: Any]]) ?? []
        let switchLocked = (accData["switchLocked"] as? Bool) ?? false
        if !accounts.isEmpty {
            acctMenu.addItem(.separator())
            for acc in accounts {
                let remark = (acc["remark"] as? String) ?? ""
                let email = (acc["email"] as? String) ?? "未知账号"
                var title = remark.isEmpty ? email : remark
                if let tier = acc["tier"] as? String, !tier.isEmpty {
                    title += " [\(tier)]"
                }
                let isCurrent = (acc["isCurrent"] as? Bool) ?? false
                let hasCred = (acc["hasCredential"] as? Bool) ?? false
                if isCurrent {
                    title += " (当前)"
                }
                let enabled = !(isCurrent || !hasCred || switchLocked)
                let snap = acc
                addItem(to: acctMenu, title: title, checked: isCurrent, enabled: enabled) { [weak self] in
                    self?.confirmAndSwitchFromMenu(snap)
                }
            }
        }
        acctItem.submenu = acctMenu
        menu.addItem(acctItem)

        menu.addItem(.separator())

        addItem(to: menu, title: "吸附到 Antigravity 左下角", checked: prefs.dock == "docked") { [weak self] in
            self?.setDockMode("docked")
        }
        addItem(to: menu, title: "自由悬浮置顶", checked: prefs.dock == "float") { [weak self] in
            self?.setDockMode("float")
        }

        menu.addItem(.separator())

        addItem(to: menu, title: "已用视角", checked: prefs.mode == "used") { [weak self] in
            self?.setDisplayMode("used")
        }
        addItem(to: menu, title: "剩余视角", checked: prefs.mode == "remaining") { [weak self] in
            self?.setDisplayMode("remaining")
        }

        let themeItem = NSMenuItem(title: "外观主题", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "外观主题")
        for (label, key) in [("跟随系统", "system"), ("浅色", "light"), ("深色", "dark")] {
            addItem(to: themeMenu, title: label, checked: prefs.theme == key) { [weak self] in
                self?.setThemePref(key)
            }
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        menu.addItem(.separator())

        addItem(to: menu, title: "随 Antigravity 关闭自动退出", checked: prefs.auto_exit_with_app) { [weak self] in
            self?.toggleAutoExit()
        }
        addItem(to: menu, title: "立即刷新") { [weak self] in
            self?.refreshAll()
        }
        addItem(to: menu, title: "退出") { [weak self] in
            self?.quitApp()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu {
            populateMenu(statusMenu)
        }
    }

    private func showContextMenu() {
        populateMenu(contextMenu)
        contextMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Self-Test Runner

@MainActor
final class SelfTestRunner: NSObject, WKNavigationDelegate {
    private let paths: WidgetPaths
    private let htmlURL: URL
    private let client: SidecarQuotaClient
    private let tracker = MacOSWindowTracker()

    private var miniWebView: ClickableWebView!
    private var popoverWebView: ClickableWebView!
    private var miniFinished = false
    private var popFinished = false
    private var payload: [String: Any]!
    private var accountsFixture: [String: Any]!
    private var discoveredPorts: [Int] = []
    private var usedPort: Int?

    init(paths: WidgetPaths, htmlURL: URL) {
        self.paths = paths
        self.htmlURL = htmlURL
        self.client = SidecarQuotaClient(paths: paths)
        super.init()
    }

    func run() -> Int32 {
        discoveredPorts = client.discoverPorts()
        let quotaRes = client.fetchQuotaSync(force: false)
        usedPort = quotaRes.port
        guard let p = quotaRes.payload,
              let groups = p["groups"] as? [Any], !groups.isEmpty else {
            printJSON([
                "ok": false,
                "ports": discoveredPorts,
                "error": quotaRes.error ?? "No quota groups returned",
            ])
            return 1
        }
        self.payload = p

        let accRes = client.fetchAccountsSync()
        if let acc = accRes.payload,
           let list = acc["accounts"] as? [Any], !list.isEmpty {
            self.accountsFixture = acc
        } else {
            self.accountsFixture = [
                "schemaVersion": 1,
                "liveAccount": ["email": "test@example.com", "tier": "Google AI Pro", "isSaved": true],
                "agySwitchDetected": true,
                "agySwitchCount": 2,
                "accounts": [
                    [
                        "id": "self-test-1",
                        "email": "test@example.com",
                        "remark": "主力账号",
                        "tier": "Google AI Pro",
                        "isCurrent": true,
                        "hasCredential": true,
                    ],
                    [
                        "id": "self-test-2",
                        "email": "backup@example.com",
                        "remark": "备用账号",
                        "tier": "Free",
                        "isCurrent": false,
                        "hasCredential": true,
                    ],
                ],
            ]
        }

        let miniCfg = WKWebViewConfiguration()
        let popCfg = WKWebViewConfiguration()
        miniWebView = ClickableWebView(frame: NSRect(x: 0, y: 0, width: 260, height: 220), configuration: miniCfg)
        popoverWebView = ClickableWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 600), configuration: popCfg)
        miniWebView.navigationDelegate = self
        popoverWebView.navigationDelegate = self

        var miniComps = URLComponents(url: htmlURL, resolvingAgainstBaseURL: true)!
        miniComps.queryItems = [URLQueryItem(name: "view", value: "mini")]
        miniWebView.loadFileURL(miniComps.url!, allowingReadAccessTo: htmlURL.deletingLastPathComponent())

        var popComps = URLComponents(url: htmlURL, resolvingAgainstBaseURL: true)!
        popComps.queryItems = [URLQueryItem(name: "view", value: "popover")]
        popoverWebView.loadFileURL(popComps.url!, allowingReadAccessTo: htmlURL.deletingLastPathComponent())

        let deadline = Date().addingTimeInterval(8.0)
        while (!miniFinished || !popFinished) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        if !miniFinished || !popFinished {
            printJSON(["ok": false, "error": "WKWebView did not finish loading widget.html"])
            return 1
        }

        var renders: [[String: Any]] = []
        for theme in ["light", "dark"] {
            for mode in ["used", "remaining"] {
                let dock = mode == "used" ? "docked" : "float"
                guard let miniSize = evalSetState(miniWebView, state: [
                    "theme": theme,
                    "mode": mode,
                    "dock": dock,
                    "expanded": true,
                    "payload": payload!,
                    "accountsData": accountsFixture!,
                ]),
                let popQuotaSize = evalSetState(popoverWebView, state: [
                    "theme": theme,
                    "mode": mode,
                    "dock": dock,
                    "expanded": true,
                    "activeTab": "quota",
                    "payload": payload!,
                    "accountsData": accountsFixture!,
                ]),
                let popAccSize = evalSetState(popoverWebView, state: [
                    "theme": theme,
                    "mode": mode,
                    "dock": dock,
                    "expanded": true,
                    "activeTab": "accounts",
                    "payload": payload!,
                    "accountsData": accountsFixture!,
                ]) else {
                    printJSON(["ok": false, "error": "WKWebView setState failed for \(theme)/\(mode)"])
                    return 1
                }
                renders.append([
                    "theme": theme,
                    "mode": mode,
                    "dock": dock,
                    "miniSize": miniSize,
                    "popoverSize": popQuotaSize,
                    "popoverAccountsSize": popAccSize,
                ])
            }
        }

        let agyWin = tracker.findAntigravityWindow()
        var agyInfo: Any = NSNull()
        if let w = agyWin {
            let nsRect = tracker.cgToAppKit(w.cgRect)
            agyInfo = [
                "windowId": w.windowId,
                "pid": w.pid,
                "ownerName": w.ownerName,
                "cgRect": [Int(w.cgRect.origin.x), Int(w.cgRect.origin.y), Int(w.cgRect.width), Int(w.cgRect.height)],
                "nsRect": [Int(nsRect.origin.x), Int(nsRect.origin.y), Int(nsRect.width), Int(nsRect.height)],
            ]
        }

        let cur = (payload["current"] as? [String: Any]) ?? [:]
        let trayImg = buildStatusBarImage()
        let report: [String: Any] = [
            "ok": true,
            "platform": "darwin",
            "discoveredPorts": discoveredPorts,
            "connectedPort": usedPort as Any,
            "antigravityRunning": tracker.isAntigravityProcessRunning(),
            "antigravityWindow": agyInfo,
            "trayIconValid": trayImg.size.width > 0 && trayImg.size.height > 0,
            "currentModel": [
                "modelId": cur["modelId"] ?? NSNull(),
                "label": cur["label"] ?? NSNull(),
                "source": cur["source"] ?? NSNull(),
            ],
            "groupCount": (payload["groups"] as? [Any])?.count ?? 0,
            "renders": renders,
        ]
        printJSON(report)
        return 0
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === miniWebView { miniFinished = true }
        if webView === popoverWebView { popFinished = true }
    }

    private func evalSetState(_ webView: WKWebView, state: [String: Any]) -> [Int]? {
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        let script = """
        (() => {
          if (!window.__WIDGET_API__) return null;
          window.__WIDGET_API__.setState(\(json));
          const el = document.querySelector('.mini-surface:not(.hidden), .popover-surface:not(.hidden)');
          if (!el) return null;
          return [Math.ceil(el.offsetWidth) + 20, Math.ceil(el.offsetHeight) + 20];
        })();
        """
        var done = false
        var dims: [Int]?
        webView.evaluateJavaScript(script) { res, _ in
            if let arr = res as? [NSNumber], arr.count == 2 {
                let w = arr[0].intValue
                let h = arr[1].intValue
                if w > 0 && h > 0 { dims = [w, h] }
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(2.0)
        while !done && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return dims
    }

    private func printJSON(_ obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}

// MARK: - CLI Entry Point

func parseArg(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

@MainActor
func runMain() -> Int32 {
    let args = Set(CommandLine.arguments)
    let pluginDirName = parseArg("--plugin-dir") ?? "quota-monitor"
    let paths = WidgetPaths(pluginDirName: pluginDirName)

    let htmlPath: String
    if let explicit = parseArg("--html") {
        htmlPath = explicit
    } else {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let sibling = exeDir.appendingPathComponent("widget.html")
        if FileManager.default.fileExists(atPath: sibling.path) {
            htmlPath = sibling.path
        } else {
            htmlPath = paths.appData
                .deletingLastPathComponent()
                .appendingPathComponent("config/plugins/\(pluginDirName)/widget/macos/widget.html").path
        }
    }

    let htmlURL = URL(fileURLWithPath: htmlPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: htmlURL.path) else {
        fputs("[quota_floating] widget.html not found at \(htmlURL.path)\n", stderr)
        return 1
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    if args.contains("--self-test") {
        let runner = SelfTestRunner(paths: paths, htmlURL: htmlURL)
        return runner.run()
    }

    let instanceLock = SingleInstanceLock()
    var acquired = instanceLock.acquire(at: paths.lockFile)
    if !acquired {
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.3)
            if instanceLock.acquire(at: paths.lockFile) {
                acquired = true
                break
            }
        }
    }
    if !acquired {
        logEvent("skipped reason=already_running", to: paths.widgetLog)
        return 0
    }

    let controller = QuotaWidgetController(paths: paths, htmlURL: htmlURL, enableTray: true)
    controller.start()
    app.run()
    instanceLock.release()
    return 0
}

exit(MainActor.assumeIsolated { runMain() })
