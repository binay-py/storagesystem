// Uploads that iOS carries out itself, in a system process, while the app is
// suspended or closed (not force-quit). The app encrypts each 18 MB chunk into a
// file and hands it over; the server finishes the file when its last chunk lands
// (?auto=1), so nothing needs the app awake at the end. Same idea as Google
// Photos' background uploads, but the files leave the phone already encrypted.
//
// Every staged chunk file has a unique name and travels with its own IV and
// checksum, so a retry or a second copy of the same photo can never pair one
// chunk's bytes with another chunk's IV.

import Foundation
import UIKit

final class BackgroundUploads: NSObject, URLSessionDataDelegate {
    static let shared = BackgroundUploads()
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "sanduk") + ".uploads" }

    struct Chunk {
        let fileId: String
        let idx: Int
        let iv: Data
        let file: URL
        let sha: String
        var key: String { "\(fileId)/\(idx)" }
    }

    struct ChunkInfo: Codable {
        var file: String   // file name inside dir, unique per staging
        var iv: String     // base64
        var sha: String    // hex sha256 of the encrypted bytes
        var attempts: Int
    }

    /// One Photos asset (photo, or photo + live video) waiting on its chunks.
    struct Item: Codable {
        var hashes: [String]
        var bytes: Int64
        var queuedAt: Date
        var chunks: [String: ChunkInfo] // "fileId/idx" -> still to send
    }

    private var items: [String: Item] = [:] // assetID -> item
    private let lock = NSLock()
    var finishEvents: (() -> Void)?

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var stateFile: URL { dir.deletingLastPathComponent().appendingPathComponent("upload-queue-v2.json") }

    /// A new, unique place for an encrypted chunk.
    static func newChunkFile(fileId: String, idx: Int) -> URL {
        dir.appendingPathComponent("\(fileId).\(idx).\(UUID().uuidString).bin")
    }

    override init() {
        super.init()
        if let d = try? Data(contentsOf: Self.stateFile),
           let saved = try? JSONDecoder().decode([String: Item].self, from: d) {
            items = saved
        }
    }

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.sessionSendsLaunchEvents = true   // wake the app (briefly) when chunks finish
        c.isDiscretionary = false           // start now, don't wait for "a good time"
        // the session allows every network; each request narrows it to the current
        // "Wi-Fi only" setting, so changing the setting applies right away
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true
        c.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Touch the session at launch so events from a previous run get delivered.
    func wake() { _ = session }

    // MARK: queue state

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    func isQueued(_ assetID: String) -> Bool { lock.lock(); defer { lock.unlock() }; return items[assetID] != nil }

    /// Bytes of encrypted chunks waiting on disk.
    var queuedBytes: Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func save() { // call with lock held
        if let d = try? JSONEncoder().encode(items) {
            try? d.write(to: Self.stateFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func remove(_ info: ChunkInfo) {
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(info.file))
    }

    // MARK: enqueue

    func enqueue(assetID: String, hashes: [String], bytes: Int64, chunks: [Chunk]) {
        lock.lock()
        defer { lock.unlock() }
        var item = Item(hashes: hashes, bytes: bytes, queuedAt: Date(), chunks: [:])
        for c in chunks {
            item.chunks[c.key] = ChunkInfo(file: c.file.lastPathComponent, iv: c.iv.base64EncodedString(),
                                           sha: c.sha, attempts: 0)
        }
        items[assetID] = item
        save()
        // tasks are created while the lock is held, so reconcile() never sees an
        // item without its tasks and starts them a second time
        for (key, info) in item.chunks { start(assetID: assetID, key: key, info: info) }
    }

    /// The PUT for one chunk (the server finishes the file when the last one lands).
    static func chunkRequest(server: String, token: String, fileId: String, idx: Int,
                             iv: String, sha: String) -> URLRequest? {
        guard let url = URL(string: "\(server)/api/files/\(fileId)/chunks/\(idx)?iv=\(SandukAPI.q(iv))&auto=1")
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer " + token, forHTTPHeaderField: "authorization")
        req.setValue(sha, forHTTPHeaderField: "x-chunk-sha256")
        req.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        return req
    }

    private func start(assetID: String, key: String, info: ChunkInfo) {
        let parts = key.split(separator: "/").map(String.init)
        let file = Self.dir.appendingPathComponent(info.file)
        guard parts.count == 2, let idx = Int(parts[1]),
              FileManager.default.fileExists(atPath: file.path), // a missing file would crash uploadTask
              let server = Keychain.get("server"), let secret = Keychain.get("secret"),
              let keys = try? SandukCrypto.derive(secret: secret),
              var req = Self.chunkRequest(server: server, token: keys.authToken, fileId: parts[0],
                                          idx: idx, iv: info.iv, sha: info.sha)
        else { return }
        let wifiOnly = UserDefaults.standard.object(forKey: "wifiOnly") as? Bool ?? true
        req.allowsExpensiveNetworkAccess = !wifiOnly
        req.allowsConstrainedNetworkAccess = !wifiOnly
        let task = session.uploadTask(with: req, fromFile: file)
        task.taskDescription = [assetID, key].joined(separator: "\n")
        if info.attempts > 0 {
            // back off: Telegram rate-limits bursts; 1, 2, 4 ... up to 30 minutes
            let wait = min(60 * pow(2, Double(info.attempts - 1)), 1800)
            task.earliestBeginDate = Date().addingTimeInterval(wait)
        }
        task.resume()
    }

    // MARK: recovery

    /// After a force-quit iOS cancels the transfers. Restart any chunk whose file
    /// is on disk but has no running task; drop items whose files are gone; and
    /// delete chunk files nothing refers to any more.
    func reconcile() {
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap { t -> String? in
                let p = (t.taskDescription ?? "").components(separatedBy: "\n")
                return p.count == 2 ? p[1] : nil
            })
            var dropped: [String] = []
            self.lock.lock()
            let settled = Date().addingTimeInterval(-120) // ignore items queued in the last 2 minutes
            for (asset, item) in self.items where item.queuedAt < settled {
                let lost = item.chunks.values.contains {
                    !FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0.file).path)
                }
                if lost {
                    for t in tasks where (t.taskDescription ?? "").hasPrefix(asset + "\n") { t.cancel() }
                    item.chunks.values.forEach(self.remove)
                    self.items[asset] = nil
                    dropped.append(asset)
                    continue
                }
                for (key, info) in item.chunks where !running.contains(key) {
                    self.start(assetID: asset, key: key, info: info)
                }
            }
            // orphans: staged but never queued (app killed in between), or left over
            let referenced = Set(self.items.values.flatMap { $0.chunks.values.map(\.file) })
            let old = Date().addingTimeInterval(-600)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: Self.dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where !referenced.contains(f.lastPathComponent) {
                let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified < old { try? FileManager.default.removeItem(at: f) }
            }
            self.save()
            self.lock.unlock()
            for asset in dropped {
                Task { @MainActor in BackupEngine.shared.backgroundItemFinished(assetID: asset, hashes: [], bytes: 0, ok: false) }
            }
        }
    }

    /// Forget everything (used when the key is removed from this iPhone).
    func reset() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        lock.lock()
        items = [:]
        save()
        lock.unlock()
        for f in (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let p = (task.taskDescription ?? "").components(separatedBy: "\n")
        guard p.count == 2 else { return }
        let assetID = p[0], key = p[1]
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        // 409 = the file was already finished (a repeated chunk): that's a success too
        let ok = error == nil && ((200..<300).contains(status) || status == 409)
        let cancelled = (error as? URLError)?.code == .cancelled
        let refused = status == 400 || status == 401 || status == 403 || status == 404

        var finished: Item?
        var gaveUp = false
        var retry: ChunkInfo?
        lock.lock()
        if var item = items[assetID], let info = item.chunks[key] {
            if ok {
                remove(info)
                item.chunks[key] = nil
                if item.chunks.isEmpty { items[assetID] = nil; finished = item } else { items[assetID] = item }
            } else if cancelled {
                // iOS dropped it (force-quit): keep it, reconcile() restarts it
            } else if refused || info.attempts >= 8 {
                // give up on this asset for now; the next backup pass resumes the
                // server-side file and sends only what's missing
                items[assetID] = nil
                item.chunks.values.forEach(remove)
                gaveUp = true
            } else {
                var next = info
                next.attempts += 1
                item.chunks[key] = next
                items[assetID] = item
                retry = next
            }
            save()
        }
        lock.unlock()

        if let retry { start(assetID: assetID, key: key, info: retry) }
        if gaveUp {
            // stop the asset's other chunks too, their files are gone
            session.getAllTasks { tasks in
                for t in tasks where (t.taskDescription ?? "").hasPrefix(assetID + "\n") { t.cancel() }
            }
            Task { @MainActor in BackupEngine.shared.backgroundItemFinished(assetID: assetID, hashes: [], bytes: 0, ok: false) }
        } else if let finished {
            Task { @MainActor in
                BackupEngine.shared.backgroundItemFinished(assetID: assetID, hashes: finished.hashes,
                                                           bytes: finished.bytes, ok: true)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            // write everything that finished once, then tell iOS we're done
            BackupEngine.shared.flushBackgroundResults()
            self.finishEvents?()
            self.finishEvents = nil
        }
    }
}

/// iOS relaunches the app in the background to deliver finished uploads.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundUploads.shared.finishEvents = completionHandler
        BackgroundUploads.shared.wake()
    }
}
