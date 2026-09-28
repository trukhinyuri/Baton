import AppKit
import BatonKit
import UserNotifications

/// Looks at limits again when something may have changed them: at each known reset (plus the 90 seconds Claude waits),
/// right after the Mac wakes, and when Baton becomes active. When a window that was at its limit has room again by a
/// known reset, it says so once, in the window and as a macOS notification if allowed.
@MainActor
final class LimitWatch {
    private var blocked: Set<String>?
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

    /// After each reload: announces windows a known reset has freed and schedules the next look.
    /// - Returns: the windows blocked at a limit now.
    func update(_ statuses: [ProfileStatus], model: AppModel, now: Date = Date()) -> Set<String> {
        let blockedNow = LimitSchedule.blocked(statuses, now: now)
        if let before = blocked {
            for status in LimitSchedule.freed(blockedBefore: before, statuses, now: now) { announce(status, model: model) }
        }
        blocked = blockedNow
        schedule(LimitSchedule.nextRefresh(statuses, now: now), model: model)
        return blockedNow
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
        model.show(notice: title + ".")
        // Only an installed app bundle may use notifications; `swift run` would stop here.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        let id = "room-again-\(status.id)"
        // Asks for permission the first time; after that macOS answers with the choice made. Denied: the notice above stays.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = "Its usage limit has reset."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
