import Foundation
import FoundationModels

/// What the user asked for, ready to show for confirmation and then save.
struct Draft: Equatable {
    enum Kind: Equatable { case reminder, event }
    var kind: Kind
    var title: String
    /// nil = a reminder with no due date.
    var start: Date?
    /// false = a date without a time (all-day event / date-only reminder).
    var hasTime: Bool
    var durationMinutes: Int
    var urgent: Bool
    /// An explicit end for events spanning a range ("from 5 July to 9 July"). For all-day events this is
    /// the last day (inclusive); for timed ones the end time. nil = start + duration / a single day.
    var until: Date? = nil
    /// The calendar or list it will land in (EventKit identifier + title), filled in by the Store.
    var calendarID: String? = nil
    var destination: String = ""

    var end: Date? {
        if let until { return until }
        return start.map { $0.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
    }
}

enum ParseError: LocalizedError {
    case modelUnavailable(String)
    case empty
    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let why): return why
        case .empty: return "Couldn't find anything to add."
        }
    }
}

// MARK: - What the on-device model fills in

@Generable enum ModelKind { case reminder, event }

@Generable struct ModelParse {
    @Guide(description: "'event' for meetings, appointments, calendar events or anything with a duration; otherwise 'reminder'")
    var kind: ModelKind
    @Guide(description: "Short task title, spelling corrected, first letter capitalised, WITHOUT time words, WITHOUT 'remind me', 'put a reminder', 'event', 'urgent'. E.g. 'Call mom'")
    var title: String
    @Guide(description: """
    The WHEN part rewritten in canonical form, using ONLY these tokens separated by spaces:
    'in N minutes' | 'in N hours' | 'in N days' | 'in N weeks' | 'in N months' | 'today' | 'tomorrow' |
    'monday'..'sunday' | 'YYYY-MM-DD' | 'HH:MM' (24-hour clock).
    Fix typos and slang, numbers as digits. Examples: 'tmrw at 3pm' -> 'tomorrow 15:00'; 'in 2hrs' -> 'in 2 hours';
    'in two days from now' -> 'in 2 days'; 'next fri 1pm' -> 'friday 13:00'; 'half an hour' -> 'in 30 minutes';
    'tonight' -> 'today 20:00'; 'tomorrow morning' -> 'tomorrow 09:00'. Empty string if no time is given.
    """)
    var when: String
    @Guide(description: """
    Only when a RANGE is given ('from X to Y', 'X until Y', 'X - Y', 'through'): the END of the range, in the same
    canonical form as 'when'. Examples: 'from monday to friday' -> 'friday'; 'tomorrow 10am to 2pm' -> 'tomorrow 14:00'.
    Empty string if there is no range.
    """)
    var until: String
    @Guide(description: "Event length in minutes if stated ('for 2h' = 120, 'half an hour' = 30), otherwise 0")
    var durationMinutes: Int
    @Guide(description: "true only if the user says it is urgent, important, asap, high priority or similar")
    var urgent: Bool
}

enum Parser {
    private static let timeWords = ["today", "tonight", "tomorrow", "tmrw", "tmr", "tomorow", "morning", "afternoon", "evening",
                                    "noon", "midnight", "week", "month", "monday", "tuesday", "wednesday", "thursday", "friday",
                                    "saturday", "sunday", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "hour", "min", "day",
                                    "event", "meeting", "calendar", "appointment"] + monthNames.map { String($0.prefix(3)) }
    private static let urgentWords = ["urgent", "urgently", "asap", "important", "!!!", "priority", "urgnt", "urgen"]

    static func parse(_ raw: String, now: Date = Date()) async throws -> Draft {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "!" }).map(String.init)
        let urgentHint = words.contains { w in urgentWords.contains { w.hasPrefix($0) } }

        // No time, no digits, nothing event-like: a plain reminder in the user's own words.
        // (Tiny inputs like "buy mlk" make the model invent things, so we don't ask it.)
        let mentionsTime = lower.contains(where: \.isNumber) || words.contains { w in timeWords.contains { w.hasPrefix($0) } }
        if !mentionsTime {
            let title = cleanTitle(text)
            guard !title.isEmpty else { throw ParseError.empty }
            return Draft(kind: .reminder, title: title, start: nil, hasTime: false, durationMinutes: 0, urgent: urgentHint)
        }

        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: break
        case .unavailable(.appleIntelligenceNotEnabled):
            throw ParseError.modelUnavailable("Turn on Apple Intelligence in System Settings.")
        case .unavailable(.modelNotReady):
            throw ParseError.modelUnavailable("Apple Intelligence is still downloading. Try again in a bit.")
        case .unavailable:
            throw ParseError.modelUnavailable("Apple Intelligence isn't available on this Mac.")
        }

        let today = now.formatted(.iso8601.year().month().day())
        let session = LanguageModelSession(instructions: """
            You extract scheduling info from a short, possibly misspelled request typed by the user.
            Today is \(now.formatted(.dateTime.weekday(.wide))) \(today).
            """)
        let p = try await session.respond(to: text, generating: ModelParse.self,
                                          options: GenerationOptions(sampling: .greedy)).content

        // The model guesses; what the user literally typed wins.
        let saysReminder = words.contains { $0.hasPrefix("remind") || $0.hasPrefix("rememb") || $0.hasPrefix("remid") || $0 == "todo" }
        let saysEvent = words.contains { $0 == "event" || $0.hasPrefix("calend") || $0.hasPrefix("meeting") || $0.hasPrefix("meting") || $0.hasPrefix("appointment") }
        let urgent = p.urgent || urgentHint
        let kind: Draft.Kind = saysReminder && !saysEvent ? .reminder
            : saysEvent ? .event
            : urgent ? .reminder
            : (p.kind == .event ? .event : .reminder)

        var title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = cleanTitle(text) }
        title = title.prefix(1).uppercased() + title.dropFirst()

        // Only keep a clock time if the user typed one (digits or a time-of-day word); the model likes to invent 11:00.
        var whenText = p.when
        let typedClock = lower.range(of: #"\d{1,2}[:.]\d{2}|\d\s*(am|pm|a\.m|p\.m|h)\b|\b(at|@)\s*\d|\bin\s+(an?|\d+)\s*(m|h)"#,
                                     options: .regularExpression) != nil
            || ["tonight", "morning", "noon", "midday", "afternoon", "evening", "midnight"].contains { lower.contains($0) }
        if !typedClock {
            whenText = whenText.split(separator: " ").filter { !$0.contains(":") }.joined(separator: " ")
        }
        var when = resolve(whenText, now: now)
        var untilWhen = p.until.isEmpty ? nil : resolve(typedClock ? p.until : p.until.split(separator: " ").filter { !$0.contains(":") }.joined(separator: " "), now: now)

        // Dates the user spelled out ("5th of July 2027", "July 5", "2027-07-05", "5-9 July") are read here, not
        // by the model, which tends to drop them and leave the event on today.
        let typed = explicitDates(in: lower, now: now)
        if let first = typed.first {
            when = when.map { w in w.hasTime ? When(date: onDay(first, clockOf: w.date), hasTime: true) : When(date: first, hasTime: false) }
                ?? When(date: first, hasTime: false)
            if typed.count >= 2 {
                let last = typed[1]
                untilWhen = untilWhen.map { u in u.hasTime ? When(date: onDay(last, clockOf: u.date), hasTime: true) : When(date: last, hasTime: false) }
                    ?? When(date: last, hasTime: false)
            } else if let u = untilWhen, !u.hasTime || Calendar.current.isDateInToday(u.date) {
                // The model's end day was only a guess around "today"; keep just its clock on the typed day.
                untilWhen = u.hasTime ? When(date: onDay(first, clockOf: u.date), hasTime: true) : nil
            }
        }

        // Same for durations: only if the user said how long.
        let typedDuration = lower.range(of: #"\bfor\b|hour|\bhr|\bmin|\d\s*h\b|half"#, options: .regularExpression) != nil
        let duration = typedDuration && p.durationMinutes > 0 ? p.durationMinutes : 60

        switch kind {
        case .event:
            // No time given at all: the next full hour.
            let start = when?.date ?? Calendar.current.nextDate(after: now, matching: DateComponents(minute: 0),
                                                                 matchingPolicy: .nextTime)!
            let hasTime = when?.hasTime ?? true
            var until: Date?
            if let u = untilWhen {
                let cal = Calendar.current
                if hasTime {
                    // "10:00 to 14:00": an end clock; a bare end day keeps the start's clock on that day.
                    let end = u.hasTime ? u.date : onDay(u.date, clockOf: start.addingTimeInterval(TimeInterval(duration * 60)))
                    if end > start { until = end }
                } else if cal.startOfDay(for: u.date) > cal.startOfDay(for: start) {
                    until = cal.startOfDay(for: u.date)
                }
            }
            return Draft(kind: .event, title: title, start: start, hasTime: hasTime,
                         durationMinutes: duration, urgent: false, until: until)
        case .reminder:
            return Draft(kind: .reminder, title: title, start: when?.date, hasTime: when?.hasTime ?? false,
                         durationMinutes: 0, urgent: urgent)
        }
    }

    /// "Put a reminder to buy milk" -> "Buy milk".
    static func cleanTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["put a reminder to ", "put a reminder for ", "put a reminder ", "add a reminder to ", "add a reminder ",
                        "make a reminder to ", "set a reminder to ", "reminder to ", "reminder: ", "reminder ",
                        "remind me to ", "remind me ", "remember to ", "todo: ", "todo ", "to do "]
        for p in prefixes where t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)); break }
        let drop = Set(urgentWords + ["(urgent)", "-", "!"])
        t = t.split(separator: " ").filter { !drop.contains($0.lowercased()) }.joined(separator: " ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!-:"))
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    // MARK: - Spelled-out dates (plain code, no model)

    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august",
                             "september", "october", "november", "december"]

    private static func onDay(_ day: Date, clockOf t: Date) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: cal.component(.hour, from: t), minute: cal.component(.minute, from: t), second: 0, of: day)!
    }

    /// Calendar dates written out in the text, in order (start of day). Handles "5th of July 2027", "5 July",
    /// "July 5th, 2027", "jul 5", "2027-07-05", and day ranges sharing a month: "5-9 July", "5th to 9th of July 2027",
    /// "July 5 to 9". A date without a year is the next one that isn't in the past.
    static func explicitDates(in text: String, now: Date = Date()) -> [Date] {
        let cal = Calendar.current
        let month = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b\.?"#
        let day = #"(\d{1,2})(?:st|nd|rd|th)?"#
        let year = #"(?:,?\s+(\d{4}))?"#
        let range = #"\s*(?:-|–|to|until|till|through|thru)\s*"#
        // Each pattern: which capture groups hold day1, day2 (range), month, year.
        let patterns: [(String, d1: Int, d2: Int?, m: Int, y: Int)] = [
            (#"\b\#(day)\#(range)\#(day)\s+(?:of\s+)?\#(month)\#(year)"#, 1, 2, 3, 4),   // 5-9 July 2027
            (#"\b\#(month)\s+\#(day)\#(range)\#(day)\b\#(year)"#, 2, 3, 1, 4),            // July 5 to 9, 2027
            (#"\b\#(day)\s+(?:of\s+)?\#(month)\#(year)"#, 1, nil, 2, 3),                 // 5th of July 2027
            (#"\b\#(month)\s+\#(day)\b\#(year)"#, 2, nil, 1, 3),                         // July 5th, 2027
            (#"\b(\d{4})-(\d{2})-(\d{2})\b"#, 3, nil, 2, 1),                            // 2027-07-05
        ]
        var found: [(at: Int, date: Date)] = []
        var taken = IndexSet()
        let ns = text as NSString
        for (pattern, d1, d2, m, y) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = match.range
                guard !taken.intersects(integersIn: r.location..<(r.location + r.length)) else { continue }
                func g(_ i: Int) -> String? {
                    let gr = match.range(at: i); return gr.location == NSNotFound ? nil : ns.substring(with: gr)
                }
                guard let mText = g(m) else { continue }
                let mNum = Int(mText) ?? (monthNames.firstIndex { $0.hasPrefix(String(mText.lowercased().prefix(3))) }.map { $0 + 1 } ?? 0)
                let yNum = g(y).flatMap { Int($0) }
                var days = [g(d1)].compactMap { $0.flatMap { Int($0) } }
                if let d2, let v = g(d2).flatMap({ Int($0) }) { days.append(v) }
                var dates: [Date] = []
                for dNum in days {
                    guard (1...12).contains(mNum), (1...31).contains(dNum) else { dates = []; break }
                    if let yNum {
                        guard let d = cal.date(from: DateComponents(year: yNum, month: mNum, day: dNum)),
                              cal.component(.day, from: d) == dNum else { dates = []; break }
                        dates.append(d)
                    } else {
                        guard let d = cal.nextDate(after: cal.startOfDay(for: now).addingTimeInterval(-1),
                                                   matching: DateComponents(month: mNum, day: dNum), matchingPolicy: .strict) else { dates = []; break }
                        dates.append(d)
                    }
                }
                // "Dec 30 - Jan 2" style wrap isn't matched here; a yearless range end before its start rolls a year.
                if dates.count == 2, yNum == nil, dates[1] < dates[0] { dates[1] = cal.date(byAdding: .year, value: 1, to: dates[1])! }
                guard !dates.isEmpty else { continue }
                taken.insert(integersIn: r.location..<(r.location + r.length))
                found += dates.map { (r.location, $0) }
            }
        }
        return found.sorted { $0.at < $1.at }.map(\.date)
    }

    // MARK: - Canonical "when" -> Date (plain code, no model)

    struct When: Equatable { var date: Date; var hasTime: Bool }

    static func resolve(_ s: String, now: Date = Date()) -> When? {
        let cal = Calendar.current
        let toks = s.lowercased().replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var offset: Date?
        var day: Date?
        var clock: (h: Int, m: Int)?
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"; iso.locale = Locale(identifier: "en_US_POSIX")

        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t == "in", i + 2 < toks.count, let n = Int(toks[i + 1]), let u = unit(toks[i + 2]) {
                offset = cal.date(byAdding: u, value: n, to: offset ?? now); i += 3; continue
            }
            if t == "in", i + 1 < toks.count, let (n, u) = glued(toks[i + 1]) {          // "in 2h", "in 45min"
                offset = cal.date(byAdding: u, value: n, to: offset ?? now); i += 2; continue
            }
            switch t {
            case "today": day = cal.startOfDay(for: now)
            case "tonight": day = cal.startOfDay(for: now); if clock == nil { clock = (20, 0) }
            case "tomorrow", "tmrw", "tomorow": day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
            case "morning": if clock == nil { clock = (9, 0) }
            case "noon", "midday": clock = (12, 0)
            case "afternoon": if clock == nil { clock = (15, 0) }
            case "evening": if clock == nil { clock = (19, 0) }
            default:
                if let wd = weekdays.firstIndex(where: { $0.hasPrefix(t) && t.count >= 3 }) {
                    day = cal.nextDate(after: now, matching: DateComponents(weekday: wd + 1), matchingPolicy: .nextTime)
                } else if let d = iso.date(from: t) {
                    day = d
                } else {
                    let next = i + 1 < toks.count ? toks[i + 1] : ""
                    if let (c, usedNext) = parseClock(t, next: next) { clock = c; if usedNext { i += 1 } }
                }
            }
            i += 1
        }

        func at(_ c: (h: Int, m: Int), on d: Date) -> Date { cal.date(bySettingHour: c.h, minute: c.m, second: 0, of: d)! }

        if let o = offset {
            var d = o
            if let day = day, day != cal.startOfDay(for: now) { d = cal.date(bySettingHour: cal.component(.hour, from: o), minute: cal.component(.minute, from: o), second: 0, of: day)! }
            if let c = clock { d = at(c, on: d) }
            let secs = cal.component(.second, from: d)
            return When(date: d.addingTimeInterval(TimeInterval(-secs)), hasTime: true)
        }
        if let day = day {
            return clock.map { When(date: at($0, on: day), hasTime: true) } ?? When(date: day, hasTime: false)
        }
        if let c = clock {
            var d = at(c, on: now)
            if d <= now { d = cal.date(byAdding: .day, value: 1, to: d)! }   // "at 9" when it's already 10 -> tomorrow
            return When(date: d, hasTime: true)
        }
        return nil
    }

    private static func unit(_ u: String) -> Calendar.Component? {
        if u.hasPrefix("min") || u == "m" { return .minute }
        if u.hasPrefix("h") { return .hour }
        if u.hasPrefix("d") { return .day }
        if u.hasPrefix("w") { return .weekOfYear }
        if u.hasPrefix("mo") { return .month }
        return nil
    }

    private static func glued(_ t: String) -> (Int, Calendar.Component)? {
        let digits = t.prefix(while: \.isNumber)
        guard let n = Int(digits), digits.count < t.count, let u = unit(String(t.dropFirst(digits.count))) else { return nil }
        return (n, u)
    }

    /// "15:00", "9:30", "3pm", "3:30pm", "3 pm", "15h". Returns the clock and whether `next` ("pm") was used.
    private static func parseClock(_ t: String, next: String) -> ((h: Int, m: Int), Bool)? {
        var s = t, usedNext = false
        if next == "am" || next == "pm" || next == "a.m." || next == "p.m." { s += next.replacingOccurrences(of: ".", with: ""); usedNext = true }
        guard let re = try? NSRegularExpression(pattern: #"^(\d{1,2})(?:[:.](\d{2}))?(am|pm|h)?$"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
        guard var h = Int(g(1) ?? "") else { return nil }
        let min = Int(g(2) ?? "") ?? 0
        let suffix = g(3)
        guard g(2) != nil || suffix != nil else { return nil }       // a bare "3" is too ambiguous
        if suffix == "pm" && h < 12 { h += 12 }
        if suffix == "am" && h == 12 { h = 0 }
        guard (0...23).contains(h), (0...59).contains(min) else { return nil }
        return ((h, min), usedNext)
    }
}
