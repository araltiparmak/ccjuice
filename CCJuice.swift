import Cocoa
import Security
import ServiceManagement
import UserNotifications

struct Bucket {
    let utilization: Double
    let resetsAt: Date?
    var remaining: Int { min(100, max(0, Int((100 - utilization).rounded()))) }
    // Defined via `remaining`, not rounded independently — the two must sum to 100
    // or toggling the display mode shows numbers that contradict each other.
    var used: Int { 100 - remaining }
}

// Built once: formatter construction is expensive and these are parsed on every poll.
private let iso8601WithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let iso8601Plain = ISO8601DateFormatter()

func parseISO(_ value: Any?) -> Date? {
    guard let s = value as? String else { return nil }
    return iso8601WithFraction.date(from: s) ?? iso8601Plain.date(from: s)
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
        // Lengths, never contents. This runs on payloads we did not expect, which
        // is precisely where a value worth keeping out of the log could turn up.
        return "string(\(str.count) chars)"
    case is NSNull:
        return "null"
    default:
        return "\(type(of: any))"
    }
}

/// An error response, split into the part that may be logged and the part that
/// may not.
struct APIError {
    /// The server's short, enum-like tag — "rate_limit_error" and the like. Safe
    /// to log, and capped in case a future one is not so short.
    let type: String

    /// The body verbatim, kept only for the local checks below. It is never
    /// logged, shown, or persisted: this is server-controlled text, and the
    /// unified log is readable by anything else running as this user.
    private let raw: String

    init(_ data: Data?) {
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let error = json?["error"] as? [String: Any]
        type = (error?["type"] as? String).map { String($0.prefix(64)) } ?? "no error type"
        raw = data.flatMap { String(data: $0.prefix(4096), encoding: .utf8) } ?? ""
    }

    /// The usage endpoint turns away an under-scoped token with a message naming
    /// the requirement; nothing else in the response separates that case from an
    /// ordinary expired token.
    var isScopeRejection: Bool { raw.localizedCaseInsensitiveContains("scope") }
}

/// The Claude Code OAuth credential. Read from the Keychain each time it is
/// needed and never cached in a property, written to disk, or logged.
struct Credential {
    let token: String
    let scopes: [String]

    enum Failure: Error {
        case denied
        case missing
        case malformed
        case keychain(OSStatus)

        var message: String {
            switch self {
            case .denied:
                return "Keychain access not granted — choose Always Allow when macOS asks"
            case .missing:
                return "No Claude Code credential in the Keychain — sign in to Claude Code first"
            case .malformed:
                return "Claude Code credential is not in the expected format"
            case .keychain(let status):
                return "Keychain error \(status)"
            }
        }
    }

    /// Reads through the Security framework — the only path that goes through
    /// macOS's own consent check, so the first read puts the standard Keychain
    /// dialog on screen and the user decides. The same secret can be had without
    /// that dialog by shelling out to `/usr/bin/security`, which already sits
    /// inside the item's access partition, but an app that quietly helps itself
    /// to another app's credential is indistinguishable from one that steals it.
    /// The prompt is the feature, not an obstacle to route around.
    static func read() -> Result<Credential, Failure> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return .failure(.missing)
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .failure(.denied)
        default:
            return .failure(.keychain(status))
        }
        guard let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return .failure(.malformed) }
        return .success(Credential(token: token, scopes: (oauth["scopes"] as? [String]) ?? []))
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
    /// Which side of the quota the numbers speak for. Warnings and colours always
    /// reason about what is left; this only changes what is written out.
    private enum ValueMode: String {
        case remaining, used
        func value(_ bucket: Bucket) -> Int { self == .used ? bucket.used : bucket.remaining }
        func text(_ bucket: Bucket) -> String { "\(value(bucket))% \(suffix)" }
        var suffix: String { self == .used ? "used" : "left" }
        var noun: String { self == .used ? "used" : "remaining" }
    }

    /// A hold on polling: until when, why, and whether the server imposed it.
    /// One value — persisted, replaced, and cleared as a unit — so the three
    /// facts can never drift apart.
    private struct Pause: Codable {
        let until: Date
        let reason: String
        // A rate-limit pause is the server's instruction and nothing local may
        // lift it. Every other pause is for a cause the user can fix — a re-login,
        // mostly — so an explicit refresh is let through.
        let isRateLimit: Bool

        static func load() -> Pause? {
            UserDefaults.standard.data(forKey: Key.pause)
                .flatMap { try? JSONDecoder().decode(Pause.self, from: $0) }
        }

        static func store(_ pause: Pause?) {
            UserDefaults.standard.set(
                pause.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.pause)
        }
    }

    // Every persisted key in one place: property initialisers cannot see instance
    // constants, so without this the same string gets written twice per setting.
    private enum Key {
        static let resetNotify = "notifyOnSessionReset"
        static let lowNotify = "notifyWhenLow"
        static let displayMode = "displayMode"
        static let valueMode = "valueMode"
        static let lowThreshold = "lowThreshold"
        static let pause = "pause"
    }

    private let resetNotificationID = "session-reset"
    private let thresholdChoices = [10, 20, 30, 50]

    private var lowThreshold = UserDefaults.standard.object(forKey: Key.lowThreshold) as? Int ?? 20
    // Warn at the chosen threshold, plus always at the critical 10%.
    private var lowThresholds: [Int] { lowThreshold == 10 ? [10] : [lowThreshold, 10] }

    private var statusItem: NSStatusItem!
    private var timer: Timer?

    // The one and only host this app talks to.
    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // Ephemeral: no on-disk cache, no cookie jar, no shared credential store, so a
    // response fetched with a bearer token is never written under ~/Library/Caches
    // and nothing about this session outlives the process.
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    // The usage payload is a few hundred bytes. Anything past this is not it, and
    // is refused rather than handed to the JSON parser.
    private let maxResponseBytes = 64 * 1024

    // The usage endpoint rate-limits per token, so requests are throttled: at most
    // one in flight, no sooner than `minimumInterval` after the last one, and after
    // a 429 nothing goes out until the pause expires.
    private let minimumInterval: TimeInterval = 60
    private var lastRequestAt: Date?
    private var isFetching = false
    // Survives a relaunch so restarting the app cannot probe into a live rate
    // limit — and cannot downgrade it into a bypassable pause, since the whole
    // pause (including `isRateLimit`) is stored together.
    private var activePause: Pause? = Pause.load() {
        didSet { Pause.store(activePause) }
    }
    private var backoffStep: TimeInterval = 0
    private let backoffSteps: [TimeInterval] = [120, 300, 900, 1800]
    private var tokenScopes: [String] = []

    private var session: Bucket?
    private var week: Bucket?
    private var opus: Bucket?
    private var lastRemaining: [String: Int] = [:]
    // (time, utilization) samples of the session bucket for the burn-rate projection
    private var sessionSamples: [(Date, Double)] = []

    private var resetNotifyEnabled = UserDefaults.standard.bool(forKey: Key.resetNotify)
    // Defaults to on, so an absent key is not the same as an explicit false.
    private var lowNotifyEnabled: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: Key.lowNotify) == nil ? true : d.bool(forKey: Key.lowNotify)
    }()
    private var displayMode = DisplayMode(
        rawValue: UserDefaults.standard.string(forKey: Key.displayMode) ?? "") ?? .both
    private var valueMode = ValueMode(
        rawValue: UserDefaults.standard.string(forKey: Key.valueMode) ?? "") ?? .remaining

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
    private let valueRemainingItem = NSMenuItem(title: "Show remaining", action: nil, keyEquivalent: "")
    private let valueUsedItem = NSMenuItem(title: "Show used", action: nil, keyEquivalent: "")
    private var thresholdItems: [NSMenuItem] = []

    // UserNotifications requires a real app bundle; guard so a bare binary doesn't crash.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    // POSIX locale, or a 24-hour format string can be rewritten by the user's region.
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Claude Code usage \(valueMode.noun)"
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
        displayMenu.addItem(NSMenuItem.separator())
        valueRemainingItem.action = #selector(setValueRemaining)
        valueRemainingItem.target = self
        valueUsedItem.action = #selector(setValueUsed)
        valueUsedItem.target = self
        displayMenu.addItem(valueRemainingItem)
        displayMenu.addItem(valueUsedItem)
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
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        syncMenuStates()

        if notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
        }

        // The timer does not fire while the Mac sleeps, so top up on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshAfterWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        refresh(force: false)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        // The poll has no deadline; let macOS coalesce the wakeup with others.
        timer?.tolerance = 30
    }

    func menuWillOpen(_ menu: NSMenu) {
        renderMenuLines()  // recompute countdowns
        // Opening the menu must not cost a request on its own; the timer keeps the
        // numbers fresh. Only top up if they have gone stale.
        refresh(force: false)
    }

    // MARK: - Data

    /// Menu item action: the user asking explicitly lifts a pause we imposed
    /// ourselves, but still has to wait out a 429.
    @objc private func refreshNow() {
        refresh(force: true)
    }

    /// Wake handler. Not forcing: waking the lid is not the user asking us to
    /// retry, and it must not walk past a backoff that is still running.
    @objc private func refreshAfterWake() {
        refresh(force: false)
    }

    private func refresh(force: Bool) {
        if isFetching { return }
        // A rate limit is the server's call and stands for everyone. Any other
        // pause is of our own making and an explicit refresh lifts it: the user
        // has most likely just fixed the cause and is asking us to re-check.
        if let activePause, Date() < activePause.until, !force || activePause.isRateLimit {
            showPaused(activePause)
            return
        }
        if !force, let lastRequestAt, Date().timeIntervalSince(lastRequestAt) < minimumInterval {
            return
        }
        isFetching = true
        lastRequestAt = Date()
        // The Keychain read can put a consent dialog on screen, and that blocks
        // whichever thread asked for the item until the user answers — never the
        // main thread, or the menu freezes behind its own prompt.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Credential.read()
            DispatchQueue.main.async { self?.send(result) }
        }
    }

    /// Sends the usage request with a freshly read credential, or reports why the
    /// credential could not be read.
    private func send(_ result: Result<Credential, Credential.Failure>) {
        let credential: Credential
        switch result {
        case .success(let value):
            credential = value
        case .failure(let failure):
            isFetching = false
            // Back off rather than retry on the next tick. If the user said no to
            // the Keychain dialog, a five-minute poll would reopen it forever —
            // and an app that nags until you click Allow has taken the choice away.
            // **Refresh** lifts this pause once they have decided otherwise.
            pause(failure.message)
            return
        }
        // Scope names only — the token itself never leaves this method. The usage
        // endpoint rejects tokens without `user:profile`, and that is worth seeing.
        tokenScopes = credential.scopes

        var req = URLRequest(url: Self.usageEndpoint)
        req.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        urlSession.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async { self?.handle(data: data, resp: resp, err: err) }
        }.resume()
    }

    private func handle(data: Data?, resp: URLResponse?, err: Error?) {
        isFetching = false
        if let err = err {
            // Transport errors (offline, DNS) deliberately skip the backoff ladder:
            // the request never reached the server, and they usually clear on their
            // own — the next timer tick simply tries again.
            show(error: err.localizedDescription)
            return
        }
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if let data, data.count > maxResponseBytes {
            pause("Response too large (HTTP \(status))")
            return
        }
        if status == 401 || status == 403 {
            // Only the server's short tag is logged. The body itself is inspected
            // here and then dropped: it goes nowhere near the system log.
            let apiError = APIError(data)
            NSLog("CCJuice HTTP %ld (%@) — token scopes: %@",
                  status, apiError.type, tokenScopes.joined(separator: " "))
            if status == 403, apiError.isScopeRejection {
                // The stored credential is valid but was minted without the scope
                // this endpoint needs — only a fresh sign-in changes that, not a
                // token refresh.
                pause("Token lacks the user:profile scope — sign in to Claude Code again")
            } else {
                pause("Not authorized (HTTP \(status)) — run Claude Code to refresh the token")
            }
            return
        }
        if status != 200 && status != 429 {
            NSLog("CCJuice HTTP %ld (%@)", status, APIError(data).type)
        }
        if status == 429 {
            // Honour Retry-After when the server sends one, otherwise back off in
            // steps so a rate limit is not made worse by retrying into it. Only the
            // delta-seconds form is parsed; the HTTP-date form comes out nil and
            // falls back to the ladder.
            let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After"))
                .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            // Escalate the step on every 429, then wait for whichever is longer:
            // our own step or what the server asked for.
            let until = Date().addingTimeInterval(max(retryAfter ?? 0, escalateBackoff()))
            NSLog("CCJuice rate limited until %@", "\(until)")
            pause("Usage API rate limited", until: until, rateLimit: true)
            return
        }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            pause("Could not parse response (HTTP \(status))")
            return
        }
        let session = parseBucket(json["five_hour"])
        let week = parseBucket(json["seven_day"])
        let opus = parseBucket(json["seven_day_opus"])
        guard session != nil || week != nil else {
            NSLog("CCJuice unexpected response (HTTP %ld): %@", status, describeStructure(json))
            pause("Unexpected response (HTTP \(status))")
            return
        }
        // Nothing is logged on success: the percentages are the user's own usage
        // data, the menu already shows them, and the unified log is readable by
        // anything else running as this user.
        backoffStep = 0
        activePause = nil
        self.session = session
        self.week = week
        self.opus = opus
        recordSessionSample()
        checkLowWarnings()
        renderTitle()
        renderMenuLines()
        updatedItem.title = "Updated: \(timeFormatter.string(from: Date()))"
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
        let value = valueMode.value
        let text: String
        switch displayMode {
        // "Lowest" always means the tightest quota, i.e. the least remaining —
        // in used mode that is the largest number, not the smallest.
        case .lowest:
            if let lowest = parts.min(by: { $0.1.remaining < $1.1.remaining }) {
                text = "\(lowest.0)\(value(lowest.1))%"
            } else {
                text = "–"
            }
        case .session:
            text = session.map { "S\(value($0))%" } ?? "–"
        case .week:
            text = week.map { "W\(value($0))%" } ?? "–"
        case .both:
            let visible = parts.filter { $0.0 != "O" }
            text = visible.isEmpty ? "–" : visible.map { "\($0.0)\(value($0.1))%" }.joined(separator: " ")
        }

        let minRemaining = parts.map(\.1.remaining).min() ?? 100
        let color: NSColor =
            minRemaining <= 10 ? .systemRed : minRemaining <= lowThreshold ? .systemOrange : .labelColor
        setTitle(text, color: color)
        // The bare percentages cannot say which way they are counting, so the
        // tooltip carries that.
        statusItem.button?.toolTip = "Claude Code usage \(valueMode.noun)"
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
        var s = "\(label): \(valueMode.text(b))"
        if let r = b.resetsAt {
            s += " — resets in \(countdown(to: r)) (\(resetFormatter.string(from: r)))"
        }
        return s
    }

    /// Stop calling the endpoint until `until`, and say why. None of these failures
    /// say anything about the plan quota, so the last known percentages stay up.
    private func pause(_ reason: String, until: Date, rateLimit: Bool = false) {
        let p = Pause(until: until, reason: reason, isRateLimit: rateLimit)
        activePause = p
        showPaused(p)
    }

    /// Escalating pause for failures the server gave no retry hint for.
    private func pause(_ reason: String) {
        pause(reason, until: Date().addingTimeInterval(escalateBackoff()))
    }

    /// Advance one rung up the backoff ladder and return the new wait, saturating
    /// at the longest step. Reset to the bottom by a successful poll.
    private func escalateBackoff() -> TimeInterval {
        backoffStep = backoffSteps.first(where: { $0 > backoffStep }) ?? backoffSteps.last ?? 0
        return backoffStep
    }

    private func showPaused(_ p: Pause) {
        show(error: "\(p.reason) — retrying in \(countdown(to: p.until))")
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
            updatedItem.title = "Update failed \(timeFormatter.string(from: Date())) — \(error)"
        }
    }

    private func syncMenuStates() {
        resetNotifyItem.state = resetNotifyEnabled ? .on : .off
        lowNotifyItem.state = lowNotifyEnabled ? .on : .off
        modeBothItem.state = displayMode == .both ? .on : .off
        modeSessionItem.state = displayMode == .session ? .on : .off
        modeWeekItem.state = displayMode == .week ? .on : .off
        modeLowestItem.state = displayMode == .lowest ? .on : .off
        valueRemainingItem.state = valueMode == .remaining ? .on : .off
        valueUsedItem.state = valueMode == .used ? .on : .off
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
        UserDefaults.standard.set(lowThreshold, forKey: Key.lowThreshold)
        syncMenuStates()
        renderTitle()
    }

    @objc private func setModeBoth() { setMode(.both) }
    @objc private func setModeSession() { setMode(.session) }
    @objc private func setModeWeek() { setMode(.week) }
    @objc private func setModeLowest() { setMode(.lowest) }

    private func setMode(_ mode: DisplayMode) {
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Key.displayMode)
        syncMenuStates()
        renderTitle()
    }

    @objc private func setValueRemaining() { setValueMode(.remaining) }
    @objc private func setValueUsed() { setValueMode(.used) }

    private func setValueMode(_ mode: ValueMode) {
        valueMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Key.valueMode)
        syncMenuStates()
        renderTitle()
        renderMenuLines()
        // A reset notification queued under the old wording would still fire with it.
        updateResetNotificationSchedule()
    }

    @objc private func toggleResetNotify() {
        guard ensureNotificationsUsable() else { return }
        resetNotifyEnabled.toggle()
        UserDefaults.standard.set(resetNotifyEnabled, forKey: Key.resetNotify)
        syncMenuStates()
        if resetNotifyEnabled { requestNotificationAuthorization() }
        updateResetNotificationSchedule()
    }

    @objc private func toggleLowNotify() {
        guard ensureNotificationsUsable() else { return }
        lowNotifyEnabled.toggle()
        UserDefaults.standard.set(lowNotifyEnabled, forKey: Key.lowNotify)
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
            // Notify once, on the poll that crosses a threshold downwards.
            guard lowThresholds.contains(where: { previous > $0 && b.remaining <= $0 })
            else { continue }
            let name = label == "S" ? "Session" : label == "W" ? "Week" : "Week (Opus)"
            var body = "\(name): \(valueMode.text(b))"
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
        content.body = valueMode == .used
            ? "Session limit has reset — usage is back to 0% used."
            : "Session limit has reset — usage is back to 100%."
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
