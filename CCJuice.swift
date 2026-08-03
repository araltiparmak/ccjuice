import Cocoa
import Security
import ServiceManagement
import UserNotifications

struct Bucket {
    let utilization: Double
    let resetsAt: Date?
    var remaining: Int { max(0, Int((100 - utilization).rounded())) }
}

func parseISO(_ value: Any?) -> Date? {
    guard let s = value as? String else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: s) { return d }
    return ISO8601DateFormatter().date(from: s)
}

func parseBucket(_ any: Any?) -> Bucket? {
    guard let dict = any as? [String: Any],
          let utilization = (dict["utilization"] as? NSNumber)?.doubleValue
    else { return nil }
    return Bucket(utilization: utilization, resetsAt: parseISO(dict["resets_at"]))
}

// Structure of an unexpected payload for local diagnostics: keys and types only,
// long strings elided so no token-like value ever lands in the log.
func describeStructure(_ any: Any, depth: Int = 0) -> String {
    if depth > 3 { return "…" }
    switch any {
    case let dict as [String: Any]:
        let inner = dict.map { "\($0.key): \(describeStructure($0.value, depth: depth + 1))" }
            .sorted().joined(separator: ", ")
        return "{\(inner)}"
    case let array as [Any]:
        let first = array.first.map { describeStructure($0, depth: depth + 1) } ?? ""
        return "[\(array.count) × \(first)]"
    case let num as NSNumber:
        return "\(num)"
    case let str as String:
        return str.count > 40 ? "string(\(str.count) chars)" : "\"\(str)\""
    case is NSNull:
        return "null"
    default:
        return "\(type(of: any))"
    }
}

func countdown(to date: Date) -> String {
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "now" }
    let d = secs / 86400
    let h = (secs % 86400) / 3600
    let m = (secs % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private enum DisplayMode: String { case both, session, week, lowest }

    private let resetNotifyKey = "notifyOnSessionReset"
    private let lowNotifyKey = "notifyWhenLow"
    private let displayModeKey = "displayMode"
    private let resetNotificationID = "session-reset"
    private let lowThresholdKey = "lowThreshold"
    private let thresholdChoices = [10, 20, 30, 50]

    private var lowThreshold = UserDefaults.standard.object(forKey: "lowThreshold") as? Int ?? 20
    // Warn at the chosen threshold, plus always at the critical 10%.
    private var lowThresholds: [Int] { lowThreshold == 10 ? [10] : [lowThreshold, 10] }

    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private var session: Bucket?
    private var week: Bucket?
    private var opus: Bucket?
    private var lastRemaining: [String: Int] = [:]
    // (time, utilization) samples of the session bucket for the burn-rate projection
    private var sessionSamples: [(Date, Double)] = []

    private var resetNotifyEnabled = UserDefaults.standard.bool(forKey: "notifyOnSessionReset")
    private var lowNotifyEnabled: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: "notifyWhenLow") == nil ? true : d.bool(forKey: "notifyWhenLow")
    }()
    private var displayMode = DisplayMode(
        rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .both

    private let sessionItem = NSMenuItem(title: "Session: –", action: nil, keyEquivalent: "")
    private let weekItem = NSMenuItem(title: "Week: –", action: nil, keyEquivalent: "")
    private let opusItem = NSMenuItem(title: "Week (Opus): –", action: nil, keyEquivalent: "")
    private let paceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "Not updated yet", action: nil, keyEquivalent: "")
    private let resetNotifyItem = NSMenuItem(title: "Notify when session resets", action: nil, keyEquivalent: "")
    private let lowNotifyItem = NSMenuItem(title: "Notify when usage is low", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: nil, keyEquivalent: "")
    private let modeBothItem = NSMenuItem(title: "Session and week", action: nil, keyEquivalent: "")
    private let modeSessionItem = NSMenuItem(title: "Session only", action: nil, keyEquivalent: "")
    private let modeWeekItem = NSMenuItem(title: "Week only", action: nil, keyEquivalent: "")
    private let modeLowestItem = NSMenuItem(title: "Lowest only", action: nil, keyEquivalent: "")
    private var thresholdItems: [NSMenuItem] = []

    // UserNotifications requires a real app bundle; guard so a bare binary doesn't crash.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Claude Code usage remaining"
        statusItem.button?.title = "CC …"

        let menu = NSMenu()
        menu.delegate = self
        let header = NSMenuItem(title: "Claude Code Usage", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(sessionItem)
        menu.addItem(weekItem)
        opusItem.isHidden = true
        menu.addItem(opusItem)
        paceItem.isHidden = true
        menu.addItem(paceItem)
        menu.addItem(NSMenuItem.separator())

        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        modeBothItem.action = #selector(setModeBoth)
        modeBothItem.target = self
        modeSessionItem.action = #selector(setModeSession)
        modeSessionItem.target = self
        modeWeekItem.action = #selector(setModeWeek)
        modeWeekItem.target = self
        modeLowestItem.action = #selector(setModeLowest)
        modeLowestItem.target = self
        displayMenu.addItem(modeBothItem)
        displayMenu.addItem(modeSessionItem)
        displayMenu.addItem(modeWeekItem)
        displayMenu.addItem(modeLowestItem)
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        resetNotifyItem.action = #selector(toggleResetNotify)
        resetNotifyItem.target = self
        menu.addItem(resetNotifyItem)
        lowNotifyItem.action = #selector(toggleLowNotify)
        lowNotifyItem.target = self
        menu.addItem(lowNotifyItem)

        let thresholdParent = NSMenuItem(title: "Warning threshold", action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu()
        for value in thresholdChoices {
            let item = NSMenuItem(title: "\(value)%", action: #selector(setThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            thresholdMenu.addItem(item)
            thresholdItems.append(item)
        }
        thresholdParent.submenu = thresholdMenu
        menu.addItem(thresholdParent)
        if #available(macOS 13.0, *) {
            loginItem.action = #selector(toggleLoginItem)
            loginItem.target = self
        } else {
            loginItem.isHidden = true
        }
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(updatedItem)
        let openUsage = NSMenuItem(title: "Open claude.ai Usage…", action: #selector(openUsagePage), keyEquivalent: "")
        openUsage.target = self
        menu.addItem(openUsage)
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        syncMenuStates()

        if notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
        }

        // The timer does not fire while the Mac sleeps; refresh immediately on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshNow),
            name: NSWorkspace.didWakeNotification, object: nil)

        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        renderMenuLines()  // recompute countdowns
        refreshNow()
    }

    // MARK: - Data

    @objc func refreshNow() {
        guard let token = readAccessToken() else {
            show(error: "Could not read token from Keychain")
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async { self?.handle(data: data, resp: resp, err: err) }
        }.resume()
    }

    private func readAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        return token
    }

    private func handle(data: Data?, resp: URLResponse?, err: Error?) {
        if let err = err {
            show(error: err.localizedDescription)
            return
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            show(error: "Token expired — run Claude Code once to refresh it")
            return
        }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            show(error: "Could not parse response (HTTP \(status))")
            return
        }
        let session = parseBucket(json["five_hour"])
        let week = parseBucket(json["seven_day"])
        let opus = parseBucket(json["seven_day_opus"])
        guard session != nil || week != nil else {
            NSLog("CCJuice unexpected response (HTTP %ld): %@", status, describeStructure(json))
            show(error: "Unexpected response (HTTP \(status)): \(json.keys.sorted().joined(separator: ", "))")
            return
        }
        NSLog("CCJuice updated: session=%@ week=%@ opus=%@",
              session.map { "\($0.remaining)%" } ?? "-",
              week.map { "\($0.remaining)%" } ?? "-",
              opus.map { "\($0.remaining)%" } ?? "-")
        self.session = session
        self.week = week
        self.opus = opus
        recordSessionSample()
        checkLowWarnings()
        renderTitle()
        renderMenuLines()
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        updatedItem.title = "Updated: \(tf.string(from: Date()))"
        updateResetNotificationSchedule()
    }

    // MARK: - Rendering

    private var labeledBuckets: [(String, Bucket)] {
        var parts: [(String, Bucket)] = []
        if let s = session { parts.append(("S", s)) }
        if let w = week { parts.append(("W", w)) }
        if let o = opus { parts.append(("O", o)) }
        return parts
    }

    private func renderTitle() {
        let parts = labeledBuckets
        let text: String
        switch displayMode {
        case .lowest:
            if let lowest = parts.min(by: { $0.1.remaining < $1.1.remaining }) {
                text = "\(lowest.0)\(lowest.1.remaining)%"
            } else {
                text = "–"
            }
        case .session:
            text = session.map { "S\($0.remaining)%" } ?? "–"
        case .week:
            text = week.map { "W\($0.remaining)%" } ?? "–"
        case .both:
            let visible = parts.filter { $0.0 != "O" }
            text = visible.isEmpty ? "–" : visible.map { "\($0.0)\($0.1.remaining)%" }.joined(separator: " ")
        }

        let minRemaining = parts.map(\.1.remaining).min() ?? 100
        let color: NSColor =
            minRemaining <= 10 ? .systemRed : minRemaining <= lowThreshold ? .systemOrange : .labelColor
        setTitle(text, color: color)
    }

    private func setTitle(_ text: String, color: NSColor) {
        guard let button = statusItem.button else { return }
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            ])
    }

    private func renderMenuLines() {
        sessionItem.title = line(label: "Session (5h)", bucket: session)
        weekItem.title = line(label: "Week", bucket: week)
        opusItem.isHidden = (opus == nil)
        if opus != nil {
            opusItem.title = line(label: "Week (Opus)", bucket: opus)
        }
        if let empty = projectedSessionEmpty() {
            paceItem.title = "At this pace, session empty in ~\(countdown(to: empty))"
            paceItem.isHidden = false
        } else {
            paceItem.isHidden = true
        }
    }

    // MARK: - Burn-rate projection

    private func recordSessionSample() {
        guard let s = session else { return }
        // A utilization drop means the 5h window reset; old samples are meaningless.
        if let last = sessionSamples.last, s.utilization < last.1 - 1 {
            sessionSamples.removeAll()
        }
        if let last = sessionSamples.last, Date().timeIntervalSince(last.0) < 60 { return }
        sessionSamples.append((Date(), s.utilization))
        let cutoff = Date().addingTimeInterval(-90 * 60)
        sessionSamples.removeAll { $0.0 < cutoff }
    }

    private func projectedSessionEmpty() -> Date? {
        guard let s = session,
              let oldest = sessionSamples.first, let latest = sessionSamples.last,
              sessionSamples.count >= 2
        else { return nil }
        let elapsed = latest.0.timeIntervalSince(oldest.0)
        guard elapsed >= 300 else { return nil }  // need a meaningful window
        let ratePerSecond = (latest.1 - oldest.1) / elapsed
        guard ratePerSecond > 0.0001 else { return nil }
        let empty = Date().addingTimeInterval((100 - s.utilization) / ratePerSecond)
        // Only worth showing when the limit would run out before the window resets.
        if let resets = s.resetsAt, empty >= resets { return nil }
        return empty
    }

    private func line(label: String, bucket: Bucket?) -> String {
        guard let b = bucket else { return "\(label): no data" }
        var s = "\(label): \(b.remaining)% left"
        if let r = b.resetsAt {
            s += " — resets in \(countdown(to: r)) (\(resetFormatter.string(from: r)))"
        }
        return s
    }

    private func show(error: String) {
        NSLog("CCJuice error: %@", error)
        // Keep the last known percentages when we already have data; a transient
        // failure should not wipe the display.
        if labeledBuckets.isEmpty {
            setTitle("CC ⚠︎", color: .labelColor)
            sessionItem.title = "Error: \(error)"
            weekItem.title = "Week: –"
            opusItem.isHidden = true
        } else {
            let tf = DateFormatter()
            tf.dateFormat = "HH:mm"
            updatedItem.title = "Update failed \(tf.string(from: Date())) — \(error)"
        }
    }

    private func syncMenuStates() {
        resetNotifyItem.state = resetNotifyEnabled ? .on : .off
        lowNotifyItem.state = lowNotifyEnabled ? .on : .off
        modeBothItem.state = displayMode == .both ? .on : .off
        modeSessionItem.state = displayMode == .session ? .on : .off
        modeWeekItem.state = displayMode == .week ? .on : .off
        modeLowestItem.state = displayMode == .lowest ? .on : .off
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        for item in thresholdItems {
            item.state = item.tag == lowThreshold ? .on : .off
        }
    }

    // MARK: - Menu actions

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        lowThreshold = sender.tag
        UserDefaults.standard.set(lowThreshold, forKey: lowThresholdKey)
        syncMenuStates()
        renderTitle()
    }

    @objc private func setModeBoth() { setMode(.both) }
    @objc private func setModeSession() { setMode(.session) }
    @objc private func setModeWeek() { setMode(.week) }
    @objc private func setModeLowest() { setMode(.lowest) }

    private func setMode(_ mode: DisplayMode) {
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: displayModeKey)
        syncMenuStates()
        renderTitle()
    }

    @objc private func toggleResetNotify() {
        guard ensureNotificationsUsable() else { return }
        resetNotifyEnabled.toggle()
        UserDefaults.standard.set(resetNotifyEnabled, forKey: resetNotifyKey)
        syncMenuStates()
        if resetNotifyEnabled { requestNotificationAuthorization() }
        updateResetNotificationSchedule()
    }

    @objc private func toggleLowNotify() {
        guard ensureNotificationsUsable() else { return }
        lowNotifyEnabled.toggle()
        UserDefaults.standard.set(lowNotifyEnabled, forKey: lowNotifyKey)
        syncMenuStates()
        if lowNotifyEnabled { requestNotificationAuthorization() }
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            show(error: "Login item: \(error.localizedDescription)")
        }
        syncMenuStates()
    }

    // MARK: - Notifications

    private func ensureNotificationsUsable() -> Bool {
        if !notificationsAvailable {
            show(error: "Notifications need the .app bundle — launch via open CCJuice.app")
            return false
        }
        return true
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkLowWarnings() {
        defer {
            for (label, b) in labeledBuckets { lastRemaining[label] = b.remaining }
        }
        guard lowNotifyEnabled, notificationsAvailable else { return }
        for (label, b) in labeledBuckets {
            guard let previous = lastRemaining[label] else { continue }
            let crossed = lowThresholds.filter { previous > $0 && b.remaining <= $0 }
            guard crossed.min() != nil else { continue }
            let name = label == "S" ? "Session" : label == "W" ? "Week" : "Week (Opus)"
            var body = "\(name): \(b.remaining)% left"
            if let r = b.resetsAt { body += " — resets in \(countdown(to: r))" }
            sendNotification(title: "Claude usage running low", body: body)
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func updateResetNotificationSchedule() {
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [resetNotificationID])
        guard resetNotifyEnabled, let resetsAt = session?.resetsAt, resetsAt > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Claude Usage"
        content.body = "Session limit has reset — usage is back to 100%."
        content.sound = .default
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: resetsAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: resetNotificationID, content: content, trigger: trigger))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
