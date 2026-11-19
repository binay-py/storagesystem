// Search labels for a photo, made on this iPhone with Apple's Vision framework:
// what is in it ("dog", "beach", "food"), whether there are people, and words
// it can read (receipts, signs, screenshots). Nothing leaves the phone except
// the result, encrypted with the chest key, so the server never sees it.

import Foundation
import Photos
import UIKit
import Vision

enum Labeler {
    struct Description {
        let labels: [String]
        let text: String
    }

    static func describe(_ asset: PHAsset) async -> Description? {
        guard let cg = await image(for: asset) else { return nil }

        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let ocr = VNRecognizeTextRequest()
        ocr.recognitionLevel = .fast
        ocr.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([classify, faces, ocr])
        } catch {
            return nil
        }

        var labels: [String] = []
        let seen = (classify.results ?? [])
            .filter { $0.confidence >= 0.3 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(12)
        labels += seen.map { $0.identifier.replacingOccurrences(of: "_", with: " ") }

        let faceCount = faces.results?.count ?? 0
        if faceCount == 1 { labels += ["person", "face"] }
        if faceCount > 1 { labels += ["people", "group", "face"] }
        if asset.mediaSubtypes.contains(.photoScreenshot) { labels.append("screenshot") }
        if asset.mediaSubtypes.contains(.photoPanorama) { labels.append("panorama") }
        if asset.mediaSubtypes.contains(.photoLive) { labels.append("live photo") }
        if asset.mediaType == .video { labels.append("video") }

        let words = (ocr.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        if words.count >= 4 { labels.append("text") }
        var text = words.joined(separator: " ")
        if text.count > 600 { text = String(text.prefix(600)) }

        var unique: [String] = []
        for l in labels where !unique.contains(l) { unique.append(l) }
        return Description(labels: unique, text: text)
    }

    /// The JSON the web app reads: {"v":1,"l":[labels],"t":"text"}.
    static func payload(_ d: Description) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["v": 1, "l": d.labels, "t": d.text])) ?? Data()
    }

    private static func image(for asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat // one callback
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            o.isSynchronous = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 512, height: 512),
                                                  contentMode: .aspectFit, options: o) { img, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                c.resume(returning: img?.cgImage)
            }
        }
    }
}
