import AppKit
import BatonKit
import UserNotifications

/// Looks at limits again when something may have changed them: at each known reset (plus the 90 seconds Claude waits),
/// right after the Mac wakes, and when Baton becomes active. When a window that was at its limit has room again by a
/// known reset and still has a minute later, it says so once, in the window and as a macOS notification if allowed.
@MainActor
final class LimitWatch {
    /// Which windows have room again, once they have stayed free for a minute.
    private var room = RoomAgainWatch()
    private var applyingPending = false
    private var timer: Timer?
    private var scheduledFor: Date?
    private var observers: [NSObjectProtocol] = []

    func start(_ model: AppModel) {
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak model] _ in
                Task { @MainActor in
                    model?.reload()
                    model?.syncNow()
                }
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
                Task { @MainActor in model?.reload() }
            })
    }

    /// After each reload: announces windows a known reset has freed and that stayed free for a minute, turns off
    /// the auto-continue entries a Continue left on in windows that have closed since, and schedules the next look.
    /// - Returns: the windows blocked at a limit now.
    func update(_ statuses: [ProfileStatus], model: AppModel, now: Date = Date()) -> Set<String> {
        let checked = room.update(statuses, now: now)
        for status in checked.announce { announce(status, model: model) }
        schedule([LimitSchedule.nextRefresh(statuses, now: now), room.nextCheck].compactMap { $0 }.min(), model: model)
        applyPending(model: model)
        model.handOverDue(statuses)
        return checked.blocked
    }

    /// Off the main thread: it reads and may write other windows' settings files.
    private func applyPending(model: AppModel) {
        guard !applyingPending, !model.isDemo else { return }
        applyingPending = true
        let manager = model.manager
        Task { [weak self, weak model] in
            let labels = await Task.detached { manager.applyPendingAutoResume() }.value
            self?.applyingPending = false
            for label in labels {
                model?.show(
                    notice: "Claude \(label) is closed now, so Baton turned off its Auto-continue when limits reset for a session you continued elsewhere.")
            }
        }
    }

    private func schedule(_ date: Date?, model: AppModel) {
        guard date != scheduledFor else { return }
        timer?.invalidate()
        timer = nil
        scheduledFor = date
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self, weak model] _ in
            Task { @MainActor in
                self?.scheduledFor = nil
                model?.reload()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func announce(_ status: ProfileStatus, model: AppModel) {
        let title = LimitSchedule.roomAgain(status)
        let body = LimitSchedule.roomAgainReason(status)
        model.show(notice: title + ". " + body)
        Self.notify(title: title, body: body, id: "room-again-\(status.id)")
    }

    /// A macOS notification, if allowed.
    static func notify(title: String, body: String, id: String) {
        // Only an installed app bundle may use notifications; `swift run` would stop here.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        // Asks for permission the first time; after that macOS answers with the choice made. Denied: the notice above stays.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
