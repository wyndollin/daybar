import AppKit
import SwiftUI

private let timeFmt: DateFormatter = {
    let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
}()

// MARK: - Tray: just the calendar icon

struct TrayView: View {
    @ObservedObject var store: Store

    var body: some View {
        Image(systemName: "calendar").font(.system(size: 13))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .fixedSize()
    }
}

// MARK: - Panel: today's events (past ones dimmed, the current one highlighted), then reminders due

struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var composer: Composer
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 13, weight: .semibold)).tracking(-0.2)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
            switch store.access {
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("DayBar can't see your calendars.").font(.system(size: 12)).foregroundStyle(.secondary)
                    FooterButton(title: "Allow in System Settings…") { store.openPrivacySettings("Privacy_Calendars") }.padding(.leading, -6)
                }
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12))
            case .unknown:
                Text("Waiting for calendar access…").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12))
            case .granted:
                if store.events.isEmpty {
                    Text("Nothing on today.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12))
                } else {
                    VStack(spacing: 1) {
                        ForEach(store.events) { e in EventRow(event: e, now: store.now) { store.open(e) } }
                    }
                    .padding(EdgeInsets(top: 0, leading: 6, bottom: 8, trailing: 6))
                }
            }
            if !store.reminders.isEmpty {
                Hairline()
                Text("Reminders").font(.system(size: 13, weight: .semibold)).tracking(-0.2)
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
                VStack(spacing: 1) {
                    ForEach(store.reminders) { r in ReminderRow(reminder: r) { store.openReminders() } }
                }
                .padding(EdgeInsets(top: 0, leading: 6, bottom: 8, trailing: 6))
            } else if store.reminderAccess == .denied {
                Hairline()
                FooterButton(title: "Allow Reminders in System Settings…") { store.openPrivacySettings("Privacy_Reminders") }
                    .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            }
            Hairline()
            ComposerView(c: composer)
            Hairline()
            HStack {
                FooterButton(title: "Open Calendar") { store.openCalendar() }
                Spacer()
                FooterButton(title: "Quit", action: onQuit)
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
        }
        .frame(width: 300)
    }
}

private struct EventRow: View {
    let event: DayEvent
    let now: Date
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let current = event.isNow(now) && !event.allDay
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: event.color))
                    .frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.system(size: 12.5, weight: current ? .semibold : .regular))
                        .lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if event.meeting != nil {
                    Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 3)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(current ? Color(nsColor: event.color).opacity(0.18) : Color.primary.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .opacity(event.isPast(now) && !event.allDay ? 0.45 : 1)
        .help(event.meeting != nil ? "Join meeting" : "Show in Calendar")
    }

    private var subtitle: String {
        let time = event.allDay ? "All day"
            : "\(timeFmt.string(from: event.start)) – \(timeFmt.string(from: event.end))"
        return event.location.isEmpty || event.meeting != nil ? time : "\(time) · \(event.location)"
    }
}

private struct ReminderRow: View {
    let reminder: DayReminder
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Circle().strokeBorder(Color(nsColor: reminder.color), lineWidth: 1.5)
                    .frame(width: 13, height: 13).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(reminder.title).font(.system(size: 12.5)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open Reminders")
    }

    private var subtitle: String {
        let when = reminder.hasTime ? timeFmt.string(from: reminder.due) : "Today"
        return "\(when) · \(reminder.list)"
    }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
