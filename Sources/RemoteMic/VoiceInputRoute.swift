import Foundation

/// Temporarily gives a remote voice session ownership of the system default input.
/// It restores the previous device only while the default still belongs to that session.
final class VoiceInputRoute {
    static let buddyMicUID = "BuddyMic2ch_UID"

    private let defaults: UserDefaults
    private let current: () -> String?
    private let available: (String) -> Bool
    private let select: (String) -> Bool
    private let fallback: (String) -> String?
    private let log: (String) -> Void
    private var scheduledRestore: DispatchWorkItem?
    private var generation = 0
    private let stateKey = "local.g9n9n.voiceInputRoute"

    init(defaults: UserDefaults = .standard, current: @escaping () -> String?,
         available: @escaping (String) -> Bool, select: @escaping (String) -> Bool,
         fallback: @escaping (String) -> String?, log: @escaping (String) -> Void) {
        self.defaults = defaults
        self.current = current
        self.available = available
        self.select = select
        self.fallback = fallback
        self.log = log
    }

    @discardableResult
    func begin(virtualUID: String) -> Bool {
        cancelScheduledRestore()
        guard !virtualUID.isEmpty, available(virtualUID), let previous = current() else {
            log("phase=start result=unavailable")
            restore()
            return false
        }
        if previous == virtualUID {
            if defaults.dictionary(forKey: stateKey) == nil,
               let original = fallback(virtualUID), original != virtualUID {
                defaults.set(["prior": original, "selected": virtualUID], forKey: stateKey)
            }
            log("phase=start result=already_selected")
            return true
        }
        // Store both device IDs before making the change so relaunch can recover
        // if the process exits before the session ends.
        if let saved = defaults.dictionary(forKey: stateKey),
           saved["selected"] as? String != virtualUID {
            restore()
        }
        defaults.set(["prior": previous, "selected": virtualUID], forKey: stateKey)
        guard select(virtualUID) else {
            log("phase=start result=select_failed")
            restore()
            return false
        }
        log("phase=start result=switched")
        return true
    }

    func restore(after delay: TimeInterval) {
        cancelScheduledRestore()
        guard defaults.dictionary(forKey: stateKey) != nil else { return }
        let ticket = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.restore()
        }
        scheduledRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func restore() {
        cancelScheduledRestore()
        guard let saved = defaults.dictionary(forKey: stateKey),
              let previous = saved["prior"] as? String,
              let virtualUID = saved["selected"] as? String,
              let currentUID = current() else { return }
        guard currentUID == virtualUID else {
            defaults.removeObject(forKey: stateKey)
            log("phase=restore result=already_changed")
            return
        }
        let target = available(previous) ? previous : fallback(virtualUID)
        guard let target, target != virtualUID, select(target) else {
            log("phase=restore result=restore_failed")
            return
        }
        defaults.removeObject(forKey: stateKey)
        log("phase=restore result=restored")
    }

    private func cancelScheduledRestore() {
        generation &+= 1
        scheduledRestore?.cancel()
        scheduledRestore = nil
    }
}
