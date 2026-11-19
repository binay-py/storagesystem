// Decides what still needs backing up, runs the uploads, and remembers which
// Photos assets are done. Shared by the app screen, background tasks, the
// Photos library watcher and the Shortcuts action.

import Foundation
import Photos
import UIKit
import UserNotifications

@MainActor
final class BackupEngine: ObservableObject {
    static let shared = BackupEngine()

    enum Trigger { case manual, auto, background, shortcut }

    // live state
    @Published private(set) var running = false
    @Published private(set) var status = "Up to date"
    @Published private(set) var progress: Double = 0           // current item
    @Published private(set) var passTotal = 0                  // items in this run
    @Published private(set) var passDone = 0
    @Published private(set) var currentAssetID: String?
    @Published private(set) var doneCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var lastMessage: String?
    @Published private(set) var configured = false
    @Published private(set) var uploadedBytes: Int64

    // settings
    @Published var autoBackup: Bool { didSet { save("autoBackup", autoBackup); if autoBackup { BackgroundJobs.schedule() } } }
    @Published var wifiOnly: Bool { didSet { save("wifiOnly", wifiOnly) } }
    @Published var includeVideos: Bool { didSet { save("includeVideos", includeVideos); refreshCounts() } }
    @Published var pauseOnLowPower: Bool { didSet { save("pauseOnLowPower", pauseOnLowPower) } }
    @Published var notifications: Bool {
        didSet {
            save("notifications", notifications)
            if notifications { Task { await Self.askNotificationPermission() } }
            updateBadge()
        }
    }

    var lastRun: Date? { UserDefaults.standard.object(forKey: "lastRun") as? Date }
    var remaining: Int { max(0, totalCount - doneCount) }

    private var doneIDs: Set<String>
    private var current: Task<Void, Never>?
    private var watcher: LibraryWatcher?
    private var pendingAuto: Task<Void, Never>?

    private static var doneFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("done-assets.json")
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: ["wifiOnly": true, "autoBackup": true, "includeVideos": true,
                              "pauseOnLowPower": true, "notifications": true])
        autoBackup = d.bool(forKey: "autoBackup")
        wifiOnly = d.bool(forKey: "wifiOnly")
        includeVideos = d.bool(forKey: "includeVideos")
        pauseOnLowPower = d.bool(forKey: "pauseOnLowPower")
        notifications = d.bool(forKey: "notifications")
        uploadedBytes = (d.object(forKey: "uploadedBytes") as? NSNumber)?.int64Value ?? 0
        let data = try? Data(contentsOf: Self.doneFile)
        doneIDs = Set((data.flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? [])
        configured = Keychain.get("secret") != nil && Keychain.get("server") != nil
    }

    private func save(_ key: String, _ value: Bool) { UserDefaults.standard.set(value, forKey: key) }

    private func saveDone() {
        guard let data = try? JSONEncoder().encode(Array(doneIDs)) else { return }
        // readable in the background after first unlock, like the Keychain item
        try? data.write(to: Self.doneFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: setup

    static func normalize(server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        return s
    }

    /// Checks the key against the server and returns how many files that chest holds.
    /// A wrong key still "works" (it is just another, empty chest), so the setup
    /// screen asks again when this comes back 0.
    func check(server: String, secret: String) async throws -> Int {
        let keys = try SandukCrypto.derive(secret: secret)
        let api = SandukAPI(base: Self.normalize(server: server), token: keys.authToken,
                            session: SandukAPI.makeSession(wifiOnly: false))
        return try await api.hashes().count
    }

    func save(server: String, secret: String) {
        Keychain.set(Self.normalize(server: server), for: "server")
        Keychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: "secret")
        configured = true
    }

    func forget() {
        cancel()
        Keychain.delete("secret")
        Keychain.delete("server")
        ChestWebView.clearWebData()
        configured = false
    }

    /// Treat everything currently on the phone as done, so only new photos upload.
    func markAllExistingDone() {
        for a in fetchAll() { doneIDs.insert(a.localIdentifier) }
        saveDone()
        refreshCounts()
    }

    func resetDone() {
        doneIDs.removeAll()
        saveDone()
        refreshCounts()
    }

    // MARK: library

    private func fetchAll() -> [PHAsset] {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)] // newest first
        o.predicate = includeVideos
            ? NSPredicate(format: "mediaType == %d || mediaType == %d",
                          PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let r = PHAsset.fetchAssets(with: o)
        var out: [PHAsset] = []
        out.reserveCapacity(r.count)
        r.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    func refreshCounts() {
        guard Self.photosAllowed else { return }
        let all = fetchAll()
        totalCount = all.count
        doneCount = all.reduce(0) { $0 + (doneIDs.contains($1.localIdentifier) ? 1 : 0) }
        updateBadge()
    }

    static var photosAllowed: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    /// Start watching Photos: a new picture taken while the app is open is
    /// backed up a few seconds later.
    func startWatching() {
        guard watcher == nil, Self.photosAllowed else { return }
        let w = LibraryWatcher()
        PHPhotoLibrary.shared().register(w)
        watcher = w
    }

    fileprivate func libraryChanged() {
        refreshCounts()
        guard autoBackup, configured, remaining > 0,
              UIApplication.shared.applicationState == .active else { return }
        pendingAuto?.cancel()
        pendingAuto = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000) // let a burst of shots settle
            guard !Task.isCancelled else { return }
            await run(trigger: .auto)
        }
    }

    // MARK: notifications + badge

    static func askNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    private func updateBadge() {
        let n = (notifications && configured) ? remaining : 0
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(n) }
    }

    private func notify(_ body: String) {
        guard notifications else { return }
        let c = UNMutableNotificationContent()
        c.title = "Sanduk"
        c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "sanduk-backup", content: c, trigger: nil))
    }

    // MARK: running

    /// Posted when new items reached the chest, so the Chest tab can refresh.
    static let chestChanged = Notification.Name("SandukChestChanged")
    static func announceChestChanged() {
        NotificationCenter.default.post(name: chestChanged, object: nil)
    }

    func cancel() { current?.cancel() }

    /// Runs one backup pass. If one is already going, waits for it instead.
    /// `deadline`: stop starting new items after this (for short background windows).
    func run(trigger: Trigger = .manual, deadline: Date? = nil) async {
        if let current { await current.value; return }
        if trigger != .manual {
            if !autoBackup && trigger != .shortcut { return }
            if pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled {
                lastMessage = "Paused: Low Power Mode is on"; return
            }
        }
        let t = Task { await self.pass(trigger: trigger, deadline: deadline) }
        current = t
        await t.value
        current = nil
    }

    private func pass(trigger: Trigger, deadline: Date?) async {
        guard let server = Keychain.get("server"), let secret = Keychain.get("secret") else {
            lastMessage = "Not set up"; return
        }
        guard Self.photosAllowed else { lastMessage = "No access to Photos"; return }

        running = true
        progress = 0
        passDone = 0
        passTotal = 0
        // a little extra time if the app is closed mid-upload
        let bgID = UIApplication.shared.beginBackgroundTask(withName: "sanduk-backup") {
            Task { @MainActor in BackupEngine.shared.cancel() }
        }

        var ok = 0, skipped = 0, failed = 0
        var stopReason: String?
        do {
            let keys = try SandukCrypto.derive(secret: secret)
            let api = SandukAPI(base: server, token: keys.authToken,
                                session: SandukAPI.makeSession(wifiOnly: wifiOnly))
            let uploader = Uploader(api: api, key: keys.encKey)

            status = "Checking your chest…"
            var known = try await api.hashes()
            let pending = fetchAll().filter { !doneIDs.contains($0.localIdentifier) }
            passTotal = pending.count

            for asset in pending {
                if Task.isCancelled { stopReason = "Paused, continues next time"; break }
                if let deadline, Date() > deadline { stopReason = "Out of time, continues next time"; break }
                status = asset.mediaType == .video ? "Uploading video" : "Uploading photo"
                currentAssetID = asset.localIdentifier
                progress = 0
                do {
                    let (outcome, hashes, bytes) = try await uploader.backup(asset: asset, known: known) { p in
                        Task { @MainActor in BackupEngine.shared.progress = p }
                    }
                    known.formUnion(hashes)
                    doneIDs.insert(asset.localIdentifier)
                    doneCount += 1
                    passDone += 1
                    if outcome == .uploaded {
                        ok += 1
                        uploadedBytes += bytes
                        UserDefaults.standard.set(NSNumber(value: uploadedBytes), forKey: "uploadedBytes")
                    } else { skipped += 1 }
                    if (ok + skipped) % 10 == 0 { saveDone(); updateBadge() }
                    // let the Chest tab show new photos while the backup is still going
                    if outcome == .uploaded, ok == 1 || ok % 5 == 0 { Self.announceChestChanged() }
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        stopReason = "Paused, continues next time"; break
                    }
                    if let h = error as? SandukAPI.HTTPError, h.status == 401 || h.status == 403 {
                        stopReason = "The server refused the key"; break
                    }
                    if error is URLError {
                        stopReason = wifiOnly ? "Waiting for Wi-Fi" : "Offline"; break
                    }
                    failed += 1 // this one item; try the rest, and it again next run
                    passDone += 1
                }
            }
        } catch {
            stopReason = error.localizedDescription
        }

        running = false
        currentAssetID = nil
        if ok > 0 { Self.announceChestChanged() }
        progress = 0
        UserDefaults.standard.set(Date(), forKey: "lastRun")
        saveDone()
        refreshCounts()
        status = remaining == 0 ? "Up to date" : "\(remaining) waiting"

        var bits: [String] = []
        if ok > 0 { bits.append("\(ok) backed up") }
        if skipped > 0 { bits.append("\(skipped) were already in the chest") }
        if failed > 0 { bits.append("\(failed) failed, will retry") }
        if let stopReason { bits.append(stopReason) }
        lastMessage = bits.isEmpty ? "Everything is backed up" : bits.joined(separator: " · ")

        // tell you about work done while you weren't looking
        if ok > 0, trigger == .background || trigger == .shortcut
            || UIApplication.shared.applicationState != .active {
            notify(ok == 1 ? "1 new item backed up to your chest."
                           : "\(ok) new items backed up to your chest.")
        }
        UIApplication.shared.endBackgroundTask(bgID)
    }
}

/// Photos tells us about library changes on a background queue.
private final class LibraryWatcher: NSObject, PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in BackupEngine.shared.libraryChanged() }
    }
}
