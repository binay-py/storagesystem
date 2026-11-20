// Uploads that iOS carries out itself, in a system process, while the app is
// suspended or closed (not force-quit). The app encrypts each 18 MB chunk into a
// file and hands it over; the server finishes the file when its last chunk lands
// (?auto=1), so nothing needs the app awake at the end. Same idea as Google
// Photos' background uploads, but the files leave the phone already encrypted.

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
    }

    /// One Photos asset (photo, or photo + live video) waiting on its chunks.
    struct Item: Codable {
        var hashes: [String]
        var bytes: Int64
        var pending: [String: Int] // "fileId/idx" -> attempts so far
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
    private static var stateFile: URL { dir.deletingLastPathComponent().appendingPathComponent("upload-queue.json") }

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
        let wifiOnly = UserDefaults.standard.object(forKey: "wifiOnly") as? Bool ?? true
        c.allowsExpensiveNetworkAccess = !wifiOnly
        c.allowsConstrainedNetworkAccess = !wifiOnly
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

    // MARK: enqueue

    func enqueue(assetID: String, hashes: [String], bytes: Int64, chunks: [Chunk]) {
        lock.lock()
        var item = Item(hashes: hashes, bytes: bytes, pending: [:])
        for c in chunks { item.pending["\(c.fileId)/\(c.idx)"] = 0 }
        items[assetID] = item
        save()
        lock.unlock()
        for c in chunks { start(assetID: assetID, fileId: c.fileId, idx: c.idx, iv: c.iv.base64EncodedString(), sha: c.sha) }
    }

    private static func chunkFile(_ fileId: String, _ idx: Int) -> URL {
        dir.appendingPathComponent("\(fileId).\(idx).bin")
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

    private func start(assetID: String, fileId: String, idx: Int, iv: String, sha: String) {
        guard let server = Keychain.get("server"), let secret = Keychain.get("secret"),
              let keys = try? SandukCrypto.derive(secret: secret),
              let req = Self.chunkRequest(server: server, token: keys.authToken, fileId: fileId,
                                          idx: idx, iv: iv, sha: sha)
        else { return }
        let task = session.uploadTask(with: req, fromFile: Self.chunkFile(fileId, idx))
        task.taskDescription = [assetID, fileId, String(idx), iv, sha].joined(separator: "\n")
        task.resume()
    }

    // MARK: recovery

    /// After a force-quit iOS cancels the transfers. Restart any chunk that has its
    /// file on disk but no running task; drop items whose files are gone.
    func reconcile() {
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap { t -> String? in
                let p = (t.taskDescription ?? "").components(separatedBy: "\n")
                return p.count == 5 ? "\(p[1])/\(p[2])" : nil
            })
            var restart: [(String, String, Int)] = []
            var dropped: [(String, Item)] = []
            self.lock.lock()
            for (asset, item) in self.items {
                var lost = false
                for key in item.pending.keys where !running.contains(key) {
                    let parts = key.split(separator: "/").map(String.init)
                    guard parts.count == 2, let idx = Int(parts[1]) else { continue }
                    if FileManager.default.fileExists(atPath: Self.chunkFile(parts[0], idx).path) {
                        restart.append((asset, parts[0], idx))
                    } else {
                        lost = true
                    }
                }
                if lost { dropped.append((asset, item)) }
            }
            for (asset, item) in dropped {
                self.items[asset] = nil
                for key in item.pending.keys { self.removeFile(key) }
            }
            self.save()
            self.lock.unlock()
            // the IV and checksum travel with the task; rebuild them from the file
            for (asset, fileId, idx) in restart {
                guard let meta = self.meta(fileId, idx) else { continue }
                self.start(assetID: asset, fileId: fileId, idx: idx, iv: meta.iv, sha: meta.sha)
            }
            for (asset, _) in dropped {
                Task { @MainActor in BackupEngine.shared.backgroundItemFinished(assetID: asset, hashes: [], bytes: 0, ok: false) }
            }
        }
    }

    // IV + checksum of a chunk file, kept next to it so a lost task can be rebuilt
    func writeMeta(_ c: Chunk) {
        let m = ["iv": c.iv.base64EncodedString(), "sha": c.sha]
        if let d = try? JSONSerialization.data(withJSONObject: m) {
            try? d.write(to: c.file.appendingPathExtension("json"))
        }
    }
    private func meta(_ fileId: String, _ idx: Int) -> (iv: String, sha: String)? {
        guard let d = try? Data(contentsOf: Self.chunkFile(fileId, idx).appendingPathExtension("json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String],
              let iv = o["iv"], let sha = o["sha"] else { return nil }
        return (iv, sha)
    }
    private func removeFile(_ key: String) {
        let parts = key.split(separator: "/").map(String.init)
        guard parts.count == 2, let idx = Int(parts[1]) else { return }
        let f = Self.chunkFile(parts[0], idx)
        try? FileManager.default.removeItem(at: f)
        try? FileManager.default.removeItem(at: f.appendingPathExtension("json"))
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let p = (task.taskDescription ?? "").components(separatedBy: "\n")
        guard p.count == 5, let idx = Int(p[2]) else { return }
        let assetID = p[0], fileId = p[1], iv = p[3], sha = p[4]
        let key = "\(fileId)/\(idx)"
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        // 409 = the file was already finished (a repeated chunk): that's a success too
        let ok = error == nil && ((200..<300).contains(status) || status == 409)
        let refused = status == 401 || status == 403

        var finished: Item?
        var failedItem: Item?
        var retry = false
        lock.lock()
        if var item = items[assetID], item.pending[key] != nil {
            if ok {
                item.pending[key] = nil
                removeFile(key)
                if item.pending.isEmpty { items[assetID] = nil; finished = item } else { items[assetID] = item }
            } else if refused || (item.pending[key] ?? 0) >= 5 || (error as? URLError)?.code == .cancelled {
                // give up on this asset for now; the next backup pass resumes the
                // server-side file by its hash and sends only the missing chunks
                if (error as? URLError)?.code == .cancelled {
                    // cancelled by iOS (force-quit): keep it, reconcile() restarts it
                } else {
                    items[assetID] = nil
                    for k in item.pending.keys { removeFile(k) }
                    failedItem = item
                }
            } else {
                item.pending[key] = (item.pending[key] ?? 0) + 1
                items[assetID] = item
                retry = true
            }
            save()
        }
        lock.unlock()

        if retry { start(assetID: assetID, fileId: fileId, idx: idx, iv: iv, sha: sha) }
        if let finished {
            Task { @MainActor in
                BackupEngine.shared.backgroundItemFinished(assetID: assetID, hashes: finished.hashes,
                                                           bytes: finished.bytes, ok: true)
            }
        } else if failedItem != nil {
            Task { @MainActor in
                BackupEngine.shared.backgroundItemFinished(assetID: assetID, hashes: [], bytes: 0, ok: false)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
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
