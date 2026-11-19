import BackgroundTasks
import SwiftUI

@main
struct SandukBackupApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var engine = BackupEngine.shared

    init() {
        BackgroundJobs.register() // must happen before launch finishes
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(engine)
        }
        .onChange(of: phase) { _, p in
            if p == .background { BackgroundJobs.schedule() }
        }
    }
}

/// Two kinds of background time iOS hands out:
///  - processing: long (minutes), usually overnight while charging on Wi-Fi. Does the bulk.
///  - app refresh: ~30 s, a few times a day. Enough for a handful of new photos.
/// iOS decides when they run, based on how often you open the app and battery.
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
        task.expirationHandler = {
            Task { @MainActor in BackupEngine.shared.cancel() }
        }
        Task { @MainActor in
            await BackupEngine.shared.run(deadline: deadline)
            task.setTaskCompleted(success: true)
        }
    }
}
