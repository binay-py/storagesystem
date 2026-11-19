// Decides what still needs backing up, runs the uploads, and remembers which
// Photos assets are done. Shared by the app screen, background tasks and the
// Shortcuts action.

import Foundation
import Photos
import UIKit

@MainActor
final class BackupEngine: ObservableObject {
    static let shared = BackupEngine()

    @Published private(set) var running = false
    @Published private(set) var status = "idle"
    @Published private(set) var progress: Double = 0
    @Published private(set) var doneCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var lastMessage: String?
    @Published private(set) var configured = false
    @Published var wifiOnly: Bool {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: "wifiOnly") }
    }
    var lastRun: Date? { UserDefaults.standard.object(forKey: "lastRun") as? Date }

    private var doneIDs: Set<String>
    private var current: Task<Void, Never>?

    private static var doneFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("done-assets.json")
    }

    private init() {
        UserDefaults.standard.register(defaults: ["wifiOnly": true])
        wifiOnly = UserDefaults.standard.bool(forKey: "wifiOnly")
        let data = try? Data(contentsOf: Self.doneFile)
        doneIDs = Set((data.flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? [])
        configured = Keychain.get("secret") != nil && Keychain.get("server") != nil
    }

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
    /// Nothing is saved yet. A wrong key still "works" (it is just another, empty
    /// chest), so the screen asks again when this comes back 0.
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

    /// For starting fresh: treat everything currently on the phone as done, so only
    /// new photos from now on are uploaded.
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

    // MARK: counting

    private func fetchAll() -> [PHAsset] {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)] // newest first
        o.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                  PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
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
    }

    static var photosAllowed: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    // MARK: running

    func cancel() { current?.cancel() }

    /// Runs one backup pass. If one is already going, waits for it instead.
    /// `deadline`: stop starting new items after this (for short background windows).
    func run(deadline: Date? = nil) async {
        if let current { await current.value; return }
        let t = Task { await self.pass(deadline: deadline) }
        current = t
        await t.value
        current = nil
    }

    private func pass(deadline: Date?) async {
        guard let server = Keychain.get("server"), let secret = Keychain.get("secret") else {
            lastMessage = "not set up"; return
        }
        guard Self.photosAllowed else { lastMessage = "no access to Photos"; return }

        running = true
        progress = 0
        // a little extra time if the app is closed mid-upload
        let bgID = UIApplication.shared.beginBackgroundTask(withName: "sanduk-backup") {
            Task { @MainActor in BackupEngine.shared.cancel() }
        }
        defer {
            running = false
            status = "idle"
            progress = 0
            UserDefaults.standard.set(Date(), forKey: "lastRun")
            saveDone()
            refreshCounts()
            UIApplication.shared.endBackgroundTask(bgID)
        }

        var ok = 0, skipped = 0, failed = 0
        var stopReason: String?
        do {
            let keys = try SandukCrypto.derive(secret: secret)
            let api = SandukAPI(base: server, token: keys.authToken,
                                session: SandukAPI.makeSession(wifiOnly: wifiOnly))
            let uploader = Uploader(api: api, key: keys.encKey)

            status = "checking chest…"
            var known = try await api.hashes()
            let pending = fetchAll().filter { !doneIDs.contains($0.localIdentifier) }

            for (n, asset) in pending.enumerated() {
                if Task.isCancelled { stopReason = "paused by iOS, continues next time"; break }
                if let deadline, Date() > deadline { stopReason = "out of time, continues next time"; break }
                status = "\(n + 1) of \(pending.count)"
                progress = 0
                do {
                    let (outcome, hashes) = try await uploader.backup(asset: asset, known: known) { p in
                        Task { @MainActor in BackupEngine.shared.progress = p }
                    }
                    known.formUnion(hashes)
                    doneIDs.insert(asset.localIdentifier)
                    doneCount += 1
                    if outcome == .uploaded { ok += 1 } else { skipped += 1 }
                    if (ok + skipped) % 10 == 0 { saveDone() }
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        stopReason = "paused by iOS, continues next time"; break
                    }
                    if let h = error as? SandukAPI.HTTPError, h.status == 401 || h.status == 403 {
                        stopReason = "server refused the key"; break
                    }
                    if error is URLError {
                        stopReason = wifiOnly ? "no Wi-Fi / offline" : "offline"; break
                    }
                    failed += 1 // this one item; try the rest, and it again next run
                }
            }
        } catch {
            stopReason = error.localizedDescription
        }

        var bits: [String] = []
        if ok > 0 { bits.append("\(ok) backed up") }
        if skipped > 0 { bits.append("\(skipped) already in chest") }
        if failed > 0 { bits.append("\(failed) failed, retried next run") }
        if let stopReason { bits.append(stopReason) }
        lastMessage = bits.isEmpty ? "everything is backed up" : bits.joined(separator: " · ")
    }
}
