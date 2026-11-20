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
    @Published private(set) var backgroundQueued = BackgroundUploads.shared.count  // handed to iOS, uploading
    private var finishedInBackground = 0

    // settings
    @Published var autoBackup: Bool { didSet { save("autoBackup", autoBackup); if autoBackup { BackgroundJobs.schedule() } } }
    @Published var wifiOnly: Bool { didSet { save("wifiOnly", wifiOnly) } }
    @Published var includeVideos: Bool { didSet { save("includeVideos", includeVideos); refreshCounts() } }
    @Published var pauseOnLowPower: Bool { didSet { save("pauseOnLowPower", pauseOnLowPower) } }
    @Published var searchLabels: Bool { didSet { save("searchLabels", searchLabels) } }
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

    /// What we know about each backed-up asset: the content hashes of its files in
    /// the chest, its size on the phone, and whether its search labels were sent.
    /// "Free up space" only offers assets whose hashes the server still has.
    struct LedgerEntry: Codable {
        var h: [String]
        var s: Int64
        var l: Bool?
        var m: Double? // the photo's modificationDate when it was backed up
    }
    private func entry(_ asset: PHAsset?, _ hashes: [String], _ bytes: Int64) -> LedgerEntry {
        LedgerEntry(h: hashes, s: bytes, l: nil, m: asset?.modificationDate?.timeIntervalSince1970)
    }
    private var ledger: [String: LedgerEntry]
    private static var ledgerFile: URL { doneFile.deletingLastPathComponent().appendingPathComponent("asset-ledger.json") }
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
                              "pauseOnLowPower": true, "notifications": true, "searchLabels": true])
        searchLabels = d.bool(forKey: "searchLabels")
        autoBackup = d.bool(forKey: "autoBackup")
        wifiOnly = d.bool(forKey: "wifiOnly")
        includeVideos = d.bool(forKey: "includeVideos")
        pauseOnLowPower = d.bool(forKey: "pauseOnLowPower")
        notifications = d.bool(forKey: "notifications")
        uploadedBytes = (d.object(forKey: "uploadedBytes") as? NSNumber)?.int64Value ?? 0
        let data = try? Data(contentsOf: Self.doneFile)
        doneIDs = Set((data.flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? [])
        let ledgerData = try? Data(contentsOf: Self.ledgerFile)
        ledger = (ledgerData.flatMap { try? JSONDecoder().decode([String: LedgerEntry].self, from: $0) }) ?? [:]
        configured = Keychain.get("secret") != nil && Keychain.get("server") != nil
    }

    private func save(_ key: String, _ value: Bool) { UserDefaults.standard.set(value, forKey: key) }

    private func saveDone() {
        guard let data = try? JSONEncoder().encode(Array(doneIDs)) else { return }
        // readable in the background after first unlock, like the Keychain item
        try? data.write(to: Self.doneFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if let l = try? JSONEncoder().encode(ledger) {
            try? l.write(to: Self.ledgerFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
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
        BackgroundUploads.shared.reset()
        backgroundQueued = 0
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
        ledger.removeAll()
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

    // MARK: indexing (after the uploads)

    /// 1. Make the whole chest searchable: every photo or video without labels has
    ///    its small encrypted preview fetched, decrypted here, read by Vision, and
    ///    the labels sent back encrypted. Works for files from any device.
    /// 2. Photos backed up before the ledger existed: learn their hashes so "Free up
    ///    space" can offer them. Read-only, never uploads anything.
    /// Returns a stop reason, or nil when it finished or there was nothing to do.
    private func index(uploader: Uploader, api: SandukAPI, keys: SandukCrypto.Keys,
                       known: inout Set<String>, deadline: Date?, ok: inout Int) async -> String? {
        if searchLabels, let stop = await labelChest(api: api, keys: keys, deadline: deadline) { return stop }
        return nil
    }

    /// "Free up space" → Check older backups. Reads each older original once to
    /// learn whether the chest has it, which is heavy (big videos, iCloud), so it
    /// only runs when you ask. Read-only, never uploads.
    func checkOlderBackups() async {
        guard current == nil, let server = Keychain.get("server"), let secret = Keychain.get("secret"),
              let keys = try? SandukCrypto.derive(secret: secret) else { return }
        let api = SandukAPI(base: server, token: keys.authToken, session: SandukAPI.makeSession(wifiOnly: false))
        let uploader = Uploader(api: api, key: keys.encKey)
        let t = Task(priority: .utility) {
            guard let known = try? await api.hashes() else { self.lastMessage = "Offline"; return }
            let unchecked = self.fetchAll().filter {
                self.doneIDs.contains($0.localIdentifier) && self.ledger[$0.localIdentifier] == nil
            }
            guard !unchecked.isEmpty else { return }
            self.running = true
            self.status = "Checking older backups"
            self.passDone = 0
            self.passTotal = unchecked.count
            for asset in unchecked {
                if Task.isCancelled { break }
                self.currentAssetID = asset.localIdentifier
                do {
                    let found = try await uploader.verify(asset: asset, known: known)
                    // not in the chest: remember that, never offer it for removal
                    self.ledger[asset.localIdentifier] = self.entry(asset, found?.hashes ?? [], found?.bytes ?? 0)
                } catch {
                    if Task.isCancelled || error is CancellationError { break }
                }
                self.passDone += 1
                if self.passDone % 20 == 0 { self.saveDone() }
            }
            self.saveDone()
            self.running = false
            self.currentAssetID = nil
        }
        current = t
        await t.value
        current = nil
        running = false
    }

    private func labelChest(api: SandukAPI, keys: SandukCrypto.Keys, deadline: Date?) async -> String? {
        let offline = wifiOnly ? "Waiting for Wi-Fi" : "Offline"
        var todo: [(id: String, video: Bool)] = []
        do {
            var cursor: String?
            var pages = 0
            repeat {
                let page = try await api.listFiles(cursor: cursor)
                for f in page.files {
                    guard let id = f["id"] as? String, (f["labels_enc"] as? String) == nil,
                          (f["has_thumb"] as? NSNumber)?.intValue == 1 else { continue }
                    todo.append((id, (f["mime"] as? String ?? "").hasPrefix("video/")))
                }
                cursor = page.next
                pages += 1
            } while cursor != nil && pages < 200
        } catch {
            return offline
        }
        guard !todo.isEmpty else { return nil }

        status = "Making photos searchable"
        currentAssetID = nil
        passDone = 0
        passTotal = todo.count
        var batch: [[String: String]] = []
        func flush() async -> Bool {
            guard !batch.isEmpty else { return true }
            do { try await api.postLabels(batch) } catch { return false }
            batch.removeAll()
            Self.announceChestChanged()
            return true
        }
        for item in todo {
            if Task.isCancelled { _ = await flush(); return "Paused, continues next time" }
            if let deadline, Date() > deadline { _ = await flush(); return "Out of time, continues next time" }
            var description: Labeler.Description?
            do {
                let t = try await api.thumb(fileId: item.id)
                if let plain = try? SandukCrypto.open(t.ciphertext, key: keys.encKey, iv: t.iv) {
                    let isVideo = item.video
                    description = await Task.detached(priority: .background) {
                        await Labeler.describe(imageData: plain, isVideo: isVideo)
                    }.value
                    try? await Task.sleep(nanoseconds: 150_000_000) // keep the phone responsive
                }
            } catch {
                if error is URLError { _ = await flush(); return offline }
                // a missing preview gets an empty set (so it isn't fetched every run);
                // anything else (server busy) is tried again next time
                if let h = error as? SandukAPI.HTTPError, h.status != 404 { passDone += 1; continue }
            }
            let d = description ?? Labeler.Description(labels: item.video ? ["video"] : [], text: "")
            let iv = SandukCrypto.randomIV()
            if let ct = try? SandukCrypto.seal(Labeler.payload(d), key: keys.encKey, iv: iv) {
                batch.append(["id": item.id, "enc": ct.base64EncodedString(), "iv": iv.base64EncodedString()])
            }
            passDone += 1
            progress = 1
            if batch.count >= 25, !(await flush()) { return offline }
        }
        return await flush() ? nil : offline
    }

    /// BackgroundUploads finished (or gave up on) one asset, possibly while the
    /// app was in the background or had been relaunched just for this.
    func backgroundItemFinished(assetID: String, hashes: [String], bytes: Int64, ok: Bool) {
        backgroundQueued = BackgroundUploads.shared.count
        if ok {
            doneIDs.insert(assetID)
            if !hashes.isEmpty {
                let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
                ledger[assetID] = entry(asset, hashes, bytes)
            }
            uploadedBytes += bytes
            finishedInBackground += 1
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { BackupEngine.shared.flushBackgroundResults() }
    }

    private var flushScheduled = false

    /// Write what finished in the background once, refresh counts once.
    func flushBackgroundResults() {
        flushScheduled = false
        backgroundQueued = BackgroundUploads.shared.count
        UserDefaults.standard.set(NSNumber(value: uploadedBytes), forKey: "uploadedBytes")
        saveDone()
        Self.announceChestChanged()
        if Self.photosAllowed { refreshCounts() }
        if backgroundQueued == 0 {
            if finishedInBackground > 0, UIApplication.shared.applicationState != .active {
                notify(finishedInBackground == 1 ? "1 new item backed up to your chest."
                                                 : "\(finishedInBackground) new items backed up to your chest.")
            }
            if finishedInBackground > 0 { lastMessage = "Everything is backed up" }
            finishedInBackground = 0
        }
    }

    /// Keeps the given order (newest first) but moves long items to the back.
    nonisolated static func backupOrder<T>(_ items: [T], isLong: (T) -> Bool) -> [T] {
        items.filter { !isLong($0) } + items.filter(isLong)
    }

    /// A short, readable reason for a failed item.
    static func explain(_ error: Error, asset: PHAsset) -> String {
        let kind = asset.mediaType == .video ? "a video" : "a photo"
        let ns = error as NSError
        if ns.domain == PHPhotosErrorDomain || ns.domain.contains("PHAssetResource") || ns.domain == "CloudPhotoLibraryErrorDomain" {
            return "\(kind) couldn't be read from iCloud"
        }
        if let h = error as? SandukAPI.HTTPError {
            return h.status == 413 ? "\(kind) is too big" : "the server said \(h.status) for \(kind)"
        }
        return "\(kind): \(error.localizedDescription)"
    }

    // MARK: free up space

    struct FreeUpPlan {
        let assets: [PHAsset]
        let bytes: Int64
        let unchecked: Int   // backed up, but not double-checked yet
    }

    /// Items on this iPhone whose every file the chest has right now. Asks the
    /// server for its current list each time, so nothing stale is trusted.
    func freeUpPlan(keepDays: Int, keepFavorites: Bool) async throws -> FreeUpPlan {
        guard let server = Keychain.get("server"), let secret = Keychain.get("secret") else {
            throw URLError(.userAuthenticationRequired)
        }
        let keys = try SandukCrypto.derive(secret: secret)
        let api = SandukAPI(base: server, token: keys.authToken, session: SandukAPI.makeSession(wifiOnly: false))
        let inChest = try await api.hashes()
        let cutoff = keepDays > 0 ? Date().addingTimeInterval(-Double(keepDays) * 86_400) : nil
        var out: [PHAsset] = []
        var bytes: Int64 = 0
        var unchecked = 0
        for a in fetchAll() where doneIDs.contains(a.localIdentifier) {
            guard let e = ledger[a.localIdentifier] else { unchecked += 1; continue }
            guard !e.h.isEmpty, e.h.allSatisfy(inChest.contains) else { continue }
            // edited after it was backed up: the edit isn't in the chest
            if let m = e.m, let md = a.modificationDate, md.timeIntervalSince1970 > m + 1 { continue }
            if keepFavorites && a.isFavorite { continue }
            if let cutoff, let d = a.creationDate, d > cutoff { continue }
            out.append(a)
            bytes += e.s
        }
        return FreeUpPlan(assets: out, bytes: bytes, unchecked: unchecked)
    }

    /// iOS shows its own "Delete N items?" prompt. Deleted items go to Recently Deleted.
    func delete(_ assets: [PHAsset]) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            refreshCounts()
            return true
        } catch {
            return false // you tapped Don't Allow, or Photos refused
        }
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
        let t = Task(priority: .utility) { await self.pass(trigger: trigger, deadline: deadline) }
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
        let bg = BackgroundTime()
        bg.id = UIApplication.shared.beginBackgroundTask(withName: "sanduk-backup") {
            // iOS wants the time back now (this runs on the main thread): stop work
            // and end the task right away, or iOS terminates the app
            MainActor.assumeIsolated { BackupEngine.shared.cancel() }
            bg.end()
        }

        var ok = 0, skipped = 0, failed = 0, queuedNow = 0
        var failReason: String?
        var stopReason: String?
        do {
            let keys = try SandukCrypto.derive(secret: secret)
            let api = SandukAPI(base: server, token: keys.authToken,
                                session: SandukAPI.makeSession(wifiOnly: wifiOnly))
            let uploader = Uploader(api: api, key: keys.encKey)

            status = "Checking your chest…"
            var known = try await api.hashes()
            let queue = BackgroundUploads.shared
            // newest first, but long videos (often gigabytes) wait at the back so
            // they never hold up your photos
            let pending = Self.backupOrder(
                fetchAll().filter { !doneIDs.contains($0.localIdentifier) && !queue.isQueued($0.localIdentifier) },
                isLong: { $0.duration > 180 })
            passTotal = pending.count

            for asset in pending {
                if Task.isCancelled { stopReason = "Paused, continues next time"; break }
                if let deadline, Date() > deadline { stopReason = "Out of time, continues next time"; break }
                // keep at most ~1.5 GB of encrypted chunks waiting on disk
                if queue.queuedBytes > 1_500_000_000 { stopReason = "Uploading in the background, more after that"; break }
                status = asset.mediaType == .video ? "Preparing video" : "Preparing photo"
                currentAssetID = asset.localIdentifier
                progress = 0
                do {
                    let r = try await uploader.prepare(asset: asset, known: known)
                    let (outcome, hashes, bytes) = (r.outcome, r.hashes, r.bytes)
                    known.formUnion(hashes)
                    passDone += 1
                    if outcome == .queued {
                        // iOS uploads it from here, even if you leave the app
                        queue.enqueue(assetID: asset.localIdentifier, hashes: hashes, bytes: bytes, chunks: r.chunks)
                        backgroundQueued = queue.count
                        queuedNow += 1
                        continue
                    }
                    doneIDs.insert(asset.localIdentifier)
                    if !hashes.isEmpty { ledger[asset.localIdentifier] = entry(asset, hashes, bytes) }
                    doneCount += 1
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
                    if failReason == nil { failReason = Self.explain(error, asset: asset) }
                    passDone += 1
                }
            }
            if stopReason == nil {
                stopReason = await index(uploader: uploader, api: api, keys: keys, known: &known,
                                         deadline: deadline, ok: &ok)
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
        if queuedNow > 0 { bits.append("\(queuedNow) uploading in the background, you can leave the app") }
        if skipped > 0 { bits.append("\(skipped) were already in the chest") }
        if failed > 0 { bits.append("\(failed) failed, will retry" + (failReason.map { " (\($0))" } ?? "")) }
        if let stopReason { bits.append(stopReason) }
        lastMessage = bits.isEmpty ? "Everything is backed up" : bits.joined(separator: " · ")

        // tell you about work done while you weren't looking
        if ok > 0, trigger == .background || trigger == .shortcut
            || UIApplication.shared.applicationState != .active {
            notify(ok == 1 ? "1 new item backed up to your chest."
                           : "\(ok) new items backed up to your chest.")
        }
        bg.end()
    }
}

/// Photos tells us about library changes on a background queue.
private final class LibraryWatcher: NSObject, PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in BackupEngine.shared.libraryChanged() }
    }
}

/// The extra time iOS gives after you leave the app; ended exactly once.
final class BackgroundTime: @unchecked Sendable {
    private let lock = NSLock()
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        lock.lock(); defer { lock.unlock() }
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
