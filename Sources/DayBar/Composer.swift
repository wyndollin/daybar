import AppKit
import SwiftUI

/// The quick-add field: type → ↩ → it thinks → "Does this look right?" → ↩ adds, esc goes back to editing.
@MainActor
final class Composer: ObservableObject {
    enum Phase: Equatable {
        case editing
        case thinking
        case confirm(Draft)
        case done(String)
        case failed(String)
    }

    @Published var text = ""
    @Published private(set) var phase: Phase = .editing
    @Published var fieldFocused = false
    /// Bumped to ask the view to focus the text field.
    @Published private(set) var focusTick = 0
    /// Calendars / lists the current draft can go to (for the picker on the confirm card).
    @Published private(set) var options: [CalendarOption] = []

    private let store: Store
    private var task: Task<Void, Never>?

    init(store: Store) { self.store = store }

    /// While true the panel stays open even if the mouse leaves it.
    var isActive: Bool { fieldFocused || !text.isEmpty || phase != .editing }

    func focus() { focusTick &+= 1 }

    /// `--demo-confirm`: the confirm card for a typed request, for screenshots.
    func showDemoConfirm() {
        let cal = Calendar.current
        var friday = cal.nextDate(after: Date(), matching: DateComponents(weekday: 6), matchingPolicy: .nextTime)!
        friday = cal.date(bySettingHour: 10, minute: 30, second: 0, of: friday)!
        text = "dentist friday 10:30 for 1h"
        options = [CalendarOption(id: "personal", title: "Personal", account: "iCloud", color: .systemBlue),
                   CalendarOption(id: "work", title: "Work", account: "iCloud", color: .systemPurple)]
        phase = .confirm(Draft(kind: .event, title: "Dentist", start: friday, hasTime: true, durationMinutes: 60,
                               urgent: false, calendarID: "personal", destination: "Personal"))
    }

    /// Return / Escape from the panel. Returns false when the key wasn't ours (e.g. esc on an empty field).
    func handle(keyCode: UInt16) -> Bool {
        let isReturn = keyCode == 36 || keyCode == 76
        let isEsc = keyCode == 53
        switch phase {
        case .editing:
            if isReturn { submit(); return true }
            if isEsc, !text.isEmpty { withAnimation(.snappy) { text = "" }; return true }
            return false
        case .thinking:
            if isEsc { task?.cancel(); backToEditing(); return true }
            return isReturn
        case .confirm(let d):
            if isReturn { save(d); return true }
            if isEsc { backToEditing(); return true }
            if keyCode == 48, options.count > 1 {                     // ⇥ next calendar
                let i = options.firstIndex { $0.id == d.calendarID } ?? -1
                choose(options[(i + 1) % options.count])
                return true
            }
            return false
        case .failed:
            if isReturn || isEsc { backToEditing(); return true }
            return false
        case .done:
            if isReturn || isEsc { withAnimation(.snappy) { phase = .editing }; focus(); return true }
            return false
        }
    }

    func submit() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, phase == .editing else { return }
        withAnimation(.snappy) { phase = .thinking }
        task = Task { [weak self] in
            let started = Date()
            do {
                var d = try await Parser.parse(input)
                guard let self, !Task.isCancelled else { return }
                self.options = self.store.calendars(for: d.kind)
                if let c = self.store.defaultCalendar(for: d.kind) { d.calendarID = c.id; d.destination = c.title }
                else { d.destination = d.kind == .event ? "Calendar" : "Reminders" }
                // Let the loader be seen for a beat so the change doesn't flicker.
                let wait = 0.35 - Date().timeIntervalSince(started)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, self.phase == .thinking else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { self.phase = .confirm(d) }
            } catch {
                guard let self, !Task.isCancelled, self.phase == .thinking else { return }
                withAnimation(.snappy) { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// Pick the calendar / list on the confirm card.
    func choose(_ c: CalendarOption) {
        guard case .confirm(var d) = phase else { return }
        d.calendarID = c.id
        d.destination = c.title
        withAnimation(.snappy(duration: 0.2)) { phase = .confirm(d) }
    }

    func save(_ d: Draft) {
        do {
            try store.add(d)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                text = ""
                phase = .done("Added to \(d.destination)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, case .done = self.phase else { return }
                withAnimation(.snappy) { self.phase = .editing }
            }
        } catch {
            withAnimation(.snappy) { phase = .failed(error.localizedDescription) }
        }
    }

    func backToEditing() {
        withAnimation(.snappy) { phase = .editing }
        focus()
    }

    /// Called when the panel closes: drop finished states, keep an unsent draft.
    func panelClosed() {
        switch phase {
        case .done, .failed: phase = .editing
        case .thinking: task?.cancel(); phase = .editing
        default: break
        }
    }
}

// MARK: - View

struct ComposerView: View {
    @ObservedObject var c: Composer
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        content
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            .onChange(of: focused) { _, f in c.fieldFocused = f }
            .onChange(of: c.focusTick) { _, _ in DispatchQueue.main.async { focused = true } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            field
            switch c.phase {
            case .confirm(let d):
                ConfirmCard(draft: d, options: c.options, choose: c.choose)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)),
                                            removal: .opacity))
                HStack(spacing: 10) {
                    // Three hints leave room for the short question only; nothing here may wrap.
                    Text(c.options.count > 1 ? "Look right?" : "Does this look right?")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    Spacer()
                    if c.options.count > 1 { KeyHint(key: "⇥", label: "Calendar") }
                    KeyHint(key: "esc", label: "Edit")
                    KeyHint(key: "↩", label: "Add")
                }
                .padding(.horizontal, 2)
                .transition(.opacity)
            case .failed(let msg):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(msg).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    KeyHint(key: "esc", label: "Edit")
                }
                .font(.system(size: 11))
                .padding(.horizontal, 2)
                .transition(.opacity)
            default:
                EmptyView()
            }
        }
    }

    private var editing: Bool { c.phase == .editing }
    private var thinking: Bool { c.phase == .thinking }

    private var field: some View {
        HStack(spacing: 7) {
            leadingIcon
            if case .done(let msg) = c.phase {
                Text(msg).font(.system(size: 12.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                TextField("", text: $c.text, prompt: Text("Add a reminder or event…").foregroundStyle(.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .disabled(!editing)
                    .opacity(thinking ? 0.55 : 1)
                    .onSubmit { c.submit() }
            }
            trailing
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 34)
        .crispGlass(Capsule(), tint: Color.white.opacity(focused ? 0.10 : (hover ? 0.06 : 0.03)))
        .overlay(thinking ? Shimmer().clipShape(Capsule()) : nil)
        .contentShape(Capsule())
        .onTapGesture { if editing { focused = true } }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    @ViewBuilder private var leadingIcon: some View {
        switch c.phase {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
                .symbolEffect(.bounce, value: c.phase)
                .transition(.scale.combined(with: .opacity))
        case .thinking:
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if thinking {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                .transition(.opacity)
        } else if editing && !c.text.trimmingCharacters(in: .whitespaces).isEmpty {
            Button { c.submit() } label: {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .crispGlass(Circle())
            }
            .buttonStyle(.plain)
            .help("Add (↩)")
            .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
        }
    }
}

private let timeFmt: DateFormatter = {
    let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
}()

/// An icon and its text 4 pt apart, the icon a touch smaller, for the confirm card's detail lines.
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 9.5, weight: .semibold)); configuration.title }
    }
}

private struct ConfirmCard: View {
    let draft: Draft
    let options: [CalendarOption]
    let choose: (CalendarOption) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.16))
                Image(systemName: draft.kind == .event ? "calendar" : "checklist")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !draft.location.isEmpty {
                    Label(draft.location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .labelStyle(TightLabel())
                }
                if draft.repeats != .never {
                    Label(draft.repeats.label(from: draft.start, days: draft.repeatDays), systemImage: "repeat")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .labelStyle(TightLabel())
                }
                CalendarChip(draft: draft, options: options, choose: choose)
            }
            Spacer(minLength: 4)
            if draft.urgent {
                Text("Urgent")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.14)))
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .crispGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var tint: Color { draft.kind == .event ? .blue : (draft.urgent ? .red : .orange) }

    private var subtitle: String {
        let kind = draft.kind == .event ? "Event" : "Reminder"
        guard let start = draft.start else { return "\(kind) · no date" }
        let cal = Calendar.current
        var when = dayName(start)
        if draft.hasTime {
            when += ", \(timeFmt.string(from: start))"
            if draft.kind == .event, let end = draft.end {
                when += cal.isDate(end, inSameDayAs: start) ? " – \(timeFmt.string(from: end))"
                                                            : " – \(dayName(end)), \(timeFmt.string(from: end))"
            }
        } else if draft.kind == .event {
            if let last = draft.until, !cal.isDate(last, inSameDayAs: start) {
                let days = (cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: last)).day ?? 0) + 1
                when += " – \(dayName(last)) · \(days) days"
            } else {
                when += " · all day"
            }
        }
        return when
    }

    private func dayName(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        // Show the year when it isn't this one, so "5 Jul 2027" can't be mistaken for this July.
        if cal.component(.year, from: d) != cal.component(.year, from: Date()) {
            return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// The calendar / list the draft goes to; click to pick another (grouped by account: iCloud, Gmail, …).
private struct CalendarChip: View {
    let draft: Draft
    let options: [CalendarOption]
    let choose: (CalendarOption) -> Void
    @State private var hover = false

    private var current: CalendarOption? { options.first { $0.id == draft.calendarID } }
    private var accounts: [String] { options.reduce(into: [String]()) { if !$0.contains($1.account) { $0.append($1.account) } } }

    var body: some View {
        if options.count > 1 {
            Menu {
                ForEach(accounts, id: \.self) { account in
                    Section(account) {
                        ForEach(options.filter { $0.account == account }) { o in
                            Button { choose(o) } label: {
                                Label { Text(o.title) } icon: { Image(nsImage: dot(o.color)) }
                            }
                            .disabled(o.id == draft.calendarID)
                        }
                    }
                }
            } label: { chip(chevron: true) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a calendar (⇥)")
        } else {
            chip(chevron: false)
        }
    }

    private func chip(chevron: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color(nsColor: current?.color ?? .systemBlue)).frame(width: 7, height: 7)
            Text(draft.destination).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if let account = current?.account, accounts.count > 1 {
                Text(account).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(hover && chevron ? 0.12 : 0.07)))
        .contentShape(Capsule())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }

    /// A non-template coloured dot so menu items keep their calendar colour.
    private func dot(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true
        }
        img.isTemplate = false
        return img
    }
}

private struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 17)
                .crispGlass(Capsule())
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

extension View {
    /// Liquid Glass cut cleanly to its shape: the glass's own glow/shadow is clipped off so the edge doesn't
    /// fade out past the shape, plus a thin light rim for a crisp outline.
    func crispGlass<S: InsettableShape>(_ shape: S, tint: Color = .clear) -> some View {
        self
            .glassEffect(.regular.tint(tint), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5).allowsHitTesting(false))
    }
}

/// A soft light sweep across the field while the model is thinking.
private struct Shimmer: View {
    @State private var x: CGFloat = -1
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, Color.white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.45)
                .offset(x: x * g.size.width)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { x = 1.2 }
                }
        }
        .allowsHitTesting(false)
    }
}
