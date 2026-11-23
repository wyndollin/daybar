import AppKit
import Combine
import EventKit

/// One of today's events, copied out of EventKit so views never touch the store.
struct DayEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: NSColor
    let location: String
    let meeting: URL?
    let calendarItemID: String

    func isPast(_ now: Date) -> Bool { end <= now }
    func isNow(_ now: Date) -> Bool { start <= now && now < end }
}

/// An unfinished reminder due today, copied out of EventKit.
struct DayReminder: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date
    let hasTime: Bool
    let list: String
    let color: NSColor
}

enum Access { case unknown, granted, denied }

/// A calendar (or Reminders list) DayBar can write to, for the picker on the confirm card.
struct CalendarOption: Identifiable, Equatable {
    let id: String          // EKCalendar.calendarIdentifier
    let title: String
    let account: String     // "iCloud", "you@gmail.com", "On My Mac", …
    let color: NSColor
}

/// Reads today's events from Apple Calendar and the reminders due from Apple Reminders (every account
/// linked to them) and keeps them fresh: on changes, at midnight, on wake, and a 30 s tick so past
/// events dim and the current one highlights on time.
final class Store: ObservableObject {
    @Published private(set) var events: [DayEvent] = []
    @Published private(set) var reminders: [DayReminder] = []
    @Published private(set) var access: Access = .unknown
    @Published private(set) var reminderAccess: Access = .unknown
    @Published private(set) var now = Date()

    private let ek = EKEventStore()
    private var timer: Timer?

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in self?.reload() }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.now = Date() }
        timer?.tolerance = 5
        requestAccess()
    }

    /// Calendars first, then Reminders, so the two macOS prompts come one after the other.
    func requestAccess() {
        ek.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.access = granted ? .granted : .denied
                self?.reload()
                self?.ek.requestFullAccessToReminders { granted, _ in
                    DispatchQueue.main.async {
                        self?.reminderAccess = granted ? .granted : .denied
                        self?.reload()
                    }
                }
            }
        }
    }

    func reload() {
        now = Date()
        reloadReminders()
        guard access == .granted else { events = []; return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let pred = ek.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = ek.events(matching: pred)
            .filter { $0.status != .canceled && !declined($0) }
            .map { e in
                DayEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                         title: (e.title?.isEmpty == false ? e.title! : "Untitled"),
                         start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                         color: e.calendar.color ?? .systemBlue,
                         location: e.location ?? "",
                         meeting: meetingURL(e),
                         calendarItemID: e.calendarItemIdentifier)
            }
            .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
    }

    /// Unfinished reminders due today (not earlier days); earliest first.
    private func reloadReminders() {
        guard reminderAccess == .granted else { reminders = []; return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: today)!
        let pred = ek.predicateForIncompleteReminders(withDueDateStarting: today, ending: end, calendars: nil)
        ek.fetchReminders(matching: pred) { [weak self] found in
            let list: [DayReminder] = (found ?? []).compactMap { r in
                guard let comps = r.dueDateComponents, let due = cal.date(from: comps),
                      cal.isDate(due, inSameDayAs: today) else { return nil }
                return DayReminder(id: r.calendarItemIdentifier,
                                   title: (r.title?.isEmpty == false ? r.title! : "Untitled"),
                                   due: due, hasTime: comps.hour != nil,
                                   list: r.calendar.title, color: r.calendar.color ?? .systemOrange)
            }
            .sorted { $0.due < $1.due }
            DispatchQueue.main.async { self?.reminders = list }
        }
    }

    private func declined(_ e: EKEvent) -> Bool {
        e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// A video link from the event's URL, location or notes (Zoom, Meet, Teams, Webex, FaceTime).
    private func meetingURL(_ e: EKEvent) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com"]
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for m in det.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let u = m.url, let h = u.host?.lowercased(), hosts.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { return u }
        }
        return nil
    }

    /// The meeting link if there is one, else the event in Calendar.
    func open(_ e: DayEvent) {
        if let u = e.meeting { NSWorkspace.shared.open(u); return }
        let id = e.calendarItemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? e.calendarItemID
        if let u = URL(string: "ical://ekevent/\(id)?method=show&options=more"), NSWorkspace.shared.open(u) { return }
        openCalendar()
    }

    // MARK: adding

    /// Calendars (events) or lists (reminders) that accept new items, grouped by account, account then title order.
    func calendars(for kind: Draft.Kind) -> [CalendarOption] {
        guard (kind == .event ? access : reminderAccess) == .granted else { return [] }
        return ek.calendars(for: kind == .event ? .event : .reminder)
            .filter { $0.allowsContentModifications }
            .map { CalendarOption(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "Other",
                                  color: $0.color ?? (kind == .event ? .systemBlue : .systemOrange)) }
            .sorted { ($0.account.localizedLowercase, $0.title.localizedLowercase) < ($1.account.localizedLowercase, $1.title.localizedLowercase) }
    }

    private func lastUsedKey(_ kind: Draft.Kind) -> String { kind == .event ? "lastCalendar.event" : "lastCalendar.reminder" }

    /// Where a new item goes unless you pick another: the one you used last, else the system default.
    func defaultCalendar(for kind: Draft.Kind) -> CalendarOption? {
        let all = calendars(for: kind)
        if let last = UserDefaults.standard.string(forKey: lastUsedKey(kind)), let c = all.first(where: { $0.id == last }) { return c }
        let sys = kind == .event ? ek.defaultCalendarForNewEvents : ek.defaultCalendarForNewReminders()
        return all.first { $0.id == sys?.calendarIdentifier } ?? all.first
    }

    private func target(for d: Draft) -> EKCalendar? {
        if let id = d.calendarID, let c = ek.calendar(withIdentifier: id), c.allowsContentModifications { return c }
        return d.kind == .event ? ek.defaultCalendarForNewEvents : ek.defaultCalendarForNewReminders()
    }

    enum AddError: LocalizedError {
        case noAccess(String), noDefault(String)
        var errorDescription: String? {
            switch self {
            case .noAccess(let what): return "DayBar isn't allowed to write to \(what)."
            case .noDefault(let what): return "No default \(what) list is set."
            }
        }
    }

    func add(_ d: Draft) throws {
        let cal = Calendar.current
        switch d.kind {
        case .event:
            guard access == .granted else { throw AddError.noAccess("Calendar") }
            guard let target = target(for: d) else { throw AddError.noDefault("calendar") }
            let e = EKEvent(eventStore: ek)
            e.title = d.title
            e.calendar = target
            let start = d.start ?? Date()
            if d.hasTime {
                e.startDate = start
                e.endDate = d.end ?? start.addingTimeInterval(3600)
            } else {
                e.isAllDay = true
                e.startDate = cal.startOfDay(for: start)
                // `until` is the last day, inclusive ("5 to 9 July" = 5 days).
                let lastDay = max(cal.startOfDay(for: d.until ?? start), e.startDate)
                e.endDate = cal.date(byAdding: .day, value: 1, to: lastDay)!
            }
            try ek.save(e, span: .thisEvent, commit: true)
        case .reminder:
            guard reminderAccess == .granted else { throw AddError.noAccess("Reminders") }
            guard let target = target(for: d) else { throw AddError.noDefault("Reminders") }
            let r = EKReminder(eventStore: ek)
            r.title = d.title
            r.calendar = target
            if let due = d.start {
                var comps = cal.dateComponents(d.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: due)
                comps.timeZone = d.hasTime ? TimeZone.current : nil
                r.dueDateComponents = comps
                // A notification at the due time (or 09:00 on the day for date-only ones).
                let alarmAt = d.hasTime ? due : cal.date(bySettingHour: 9, minute: 0, second: 0, of: due)!
                if alarmAt > Date() { r.addAlarm(EKAlarm(absoluteDate: alarmAt)) }
            }
            if d.urgent { r.priority = 1 }   // "High" priority, shown as !!! in Reminders
            try ek.save(r, commit: true)
        }
        if let id = d.calendarID { UserDefaults.standard.set(id, forKey: lastUsedKey(d.kind)) }
        reload()
    }

    func openCalendar() {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openReminders() {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// `pane` is "Privacy_Calendars" or "Privacy_Reminders".
    func openPrivacySettings(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(u)
        }
    }
}
