import BackgroundTasks
import SwiftUI

@main
struct SandukBackupApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var phase
    @StateObject private var engine = BackupEngine.shared

    init() {
        BackgroundJobs.register() // must happen before launch finishes
        BackgroundUploads.shared.wake() // collect uploads that finished while we were away
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(engine)
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .background:
                BackgroundJobs.schedule()
            case .active:
                // opening the app is a good moment: back up whatever is new
                engine.startWatching()
                engine.refreshCounts()
                BackgroundUploads.shared.reconcile() // restart uploads iOS dropped (e.g. after a force-quit)
                Task { await engine.run(trigger: .auto) }
            default:
                break
            }
        }
    }
}

/// Two kinds of background time iOS hands out:
///  - processing: long (minutes), usually overnight while charging on Wi-Fi. Does the bulk.
///  - app refresh: ~30 s, a few times a day. Enough for a handful of new photos.
/// iOS decides when they run, based on how often you open the app and battery.
/// True exactly once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

enum BackgroundJobs {
    static var processingID: String { (Bundle.main.bundleIdentifier ?? "sanduk") + ".backup" }
    static var refreshID: String { (Bundle.main.bundleIdentifier ?? "sanduk") + ".refresh" }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            handle(task, deadline: nil)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            handle(task, deadline: Date().addingTimeInterval(22))
        }
    }

    static func schedule() {
        let p = BGProcessingTaskRequest(identifier: processingID)
        p.requiresExternalPower = true
        p.requiresNetworkConnectivity = true
        p.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(p)

        let r = BGAppRefreshTaskRequest(identifier: refreshID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    private static func handle(_ task: BGTask, deadline: Date?) {
        schedule() // queue the next one first
        let done = Once()
        task.expirationHandler = {
            // out of time: stop and report right away, or iOS kills the app and
            // schedules it less often
            Task { @MainActor in BackupEngine.shared.cancel() }
            if done.claim() { task.setTaskCompleted(success: false) }
        }
        Task { @MainActor in
            await BackupEngine.shared.run(trigger: .background, deadline: deadline)
            if done.claim() { task.setTaskCompleted(success: true) }
        }
    }
}
