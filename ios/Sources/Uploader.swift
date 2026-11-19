// Turns one Photos asset into a Sanduk upload, exactly like uploadOne() and the
// live-photo pairing in public/app.js: encrypted name, 18 MB encrypted chunks,
// encrypted thumbnail, then /complete. Runs off the main thread.

import CryptoKit
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

final class Uploader {
    static let chunkSize = 18 * 1024 * 1024 // under Telegram's 20 MB download cap

    let api: SandukAPI
    let key: SymmetricKey

    init(api: SandukAPI, key: SymmetricKey) {
        self.api = api
        self.key = key
    }

    enum Outcome { case uploaded, alreadyInChest, nothingToUpload }

    struct Part {
        let resource: PHAssetResource
        let name: String
        let mime: String
    }

    // MARK: picking the files of an asset

    static func parts(of asset: PHAsset) -> (main: Part, paired: Part?)? {
        let rs = PHAssetResource.assetResources(for: asset)
        func pick(_ types: [PHAssetResourceType]) -> PHAssetResource? {
            for t in types { if let r = rs.first(where: { $0.type == t }) { return r } }
            return nil
        }
        // the original's file name (IMG_1234), with the extension of what we actually send
        let original = pick([.photo, .video]) ?? rs.first
        let stem = ((original?.originalFilename ?? "file") as NSString).deletingPathExtension

        func part(_ r: PHAssetResource) -> Part {
            let ext = (r.originalFilename as NSString).pathExtension
            let type = UTType(r.uniformTypeIdentifier)
            let mime = type?.preferredMIMEType ?? (asset.mediaType == .video ? "video/quicktime" : "image/heic")
            let finalExt = ext.isEmpty ? (type?.preferredFilenameExtension ?? "bin") : ext
            return Part(resource: r, name: "\(stem).\(finalExt)", mime: mime)
        }

        switch asset.mediaType {
        case .image:
            // edited version if there is one, so the chest matches what you see in Photos
            guard let main = pick([.fullSizePhoto, .photo]) else { return nil }
            let video = asset.mediaSubtypes.contains(.photoLive) ? pick([.fullSizePairedVideo, .pairedVideo]) : nil
            return (part(main), video.map(part))
        case .video:
            guard let main = pick([.fullSizeVideo, .video]) else { return nil }
            return (part(main), nil)
        default:
            return nil
        }
    }

    // MARK: one asset

    func backup(asset: PHAsset, known: Set<String>,
                progress: @escaping (Double) -> Void) async throws -> (Outcome, [String]) {
        guard let parts = Self.parts(of: asset) else { return (.nothingToUpload, []) }
        let main = parts.main, paired = parts.paired
        let modifiedMs = Int64((asset.creationDate ?? Date()).timeIntervalSince1970 * 1000)

        let mainURL = try await export(main.resource)
        defer { try? FileManager.default.removeItem(at: mainURL) }
        let mainSize = try Self.size(of: mainURL)
        let mainHash = try SandukCrypto.contentHash(fileURL: mainURL, size: mainSize,
                                                    name: main.name, modifiedMs: modifiedMs)
        if known.contains(mainHash) { return (.alreadyInChest, [mainHash]) }

        let thumb = await thumbnail(for: asset)
        let share = paired == nil ? 1.0 : 0.6
        let photoId = try await upload(file: mainURL, size: mainSize, part: main, hash: mainHash,
                                       thumb: thumb) { progress($0 * share) }
        var hashes = [mainHash]

        if let paired {
            let vURL = try await export(paired.resource)
            defer { try? FileManager.default.removeItem(at: vURL) }
            let vSize = try Self.size(of: vURL)
            let vHash = try SandukCrypto.contentHash(fileURL: vURL, size: vSize,
                                                     name: paired.name, modifiedMs: modifiedMs)
            let videoId = try await upload(file: vURL, size: vSize, part: paired, hash: vHash,
                                           thumb: nil) { progress(0.6 + $0 * 0.4) }
            try await api.pairLive(photoId: photoId, videoId: videoId)
            hashes.append(vHash)
        }
        return (.uploaded, hashes)
    }

    // MARK: one file

    private func upload(file: URL, size: Int64, part: Part, hash: String, thumb: Data?,
                        progress: (Double) -> Void) async throws -> String {
        let nameIv = SandukCrypto.randomIV()
        let nameEnc = try SandukCrypto.seal(Data(part.name.utf8), key: key, iv: nameIv).base64EncodedString()
        let chunkCount = max(1, Int((size + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize)))

        // continue an earlier, interrupted upload of this same file
        var id: String?
        var already = Set<Int>()
        if chunkCount > 1, let found = try? await api.resume(hash: hash, size: size, chunks: chunkCount) {
            id = found.id
            already = found.done
        }
        let fileId: String
        if let id {
            fileId = id
        } else {
            fileId = try await api.createFile(nameEnc: nameEnc, nameIv: nameIv.base64EncodedString(),
                                              mime: part.mime, size: size, chunkCount: chunkCount,
                                              contentHash: hash)
        }

        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var done = already.count
        for i in 0..<chunkCount where !already.contains(i) {
            try Task.checkCancellation()
            try h.seek(toOffset: UInt64(i) * UInt64(Self.chunkSize))
            let plain = try h.read(upToCount: Self.chunkSize) ?? Data()
            let iv = SandukCrypto.randomIV()
            let ct = try SandukCrypto.seal(plain, key: key, iv: iv)
            try await api.putChunk(fileId: fileId, index: i, iv: iv, ciphertext: ct)
            done += 1
            progress(Double(done) / Double(chunkCount))
        }

        if let thumb {
            let tIv = SandukCrypto.randomIV()
            if let tCt = try? SandukCrypto.seal(thumb, key: key, iv: tIv) {
                try? await api.putThumb(fileId: fileId, iv: tIv, ciphertext: tCt)
            }
        }
        try await api.complete(fileId: fileId)
        return fileId
    }

    // MARK: helpers

    private func export(_ r: PHAssetResource) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((r.originalFilename as NSString).pathExtension)
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true // originals may be in iCloud ("Optimize Storage")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: r, toFile: url, options: opts) { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            }
        }
        return url
    }

    private func thumbnail(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat // one callback, not a degraded one first
            o.resizeMode = .exact
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 360, height: 360),
                                                  contentMode: .aspectFit, options: o) { img, info in
                // never resume twice, even if Photos sends a degraded image first
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                c.resume(returning: img?.jpegData(compressionQuality: 0.72))
            }
        }
    }

    private static func size(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
