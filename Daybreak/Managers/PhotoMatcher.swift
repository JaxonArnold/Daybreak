import UIKit
import Vision

/// Compares photos for the photo mission using Vision feature prints.
enum PhotoMatcher {
    /// Photos closer than this count as the same spot. Revision-2 distances
    /// run 0 (identical) to ~1.2. Measured on sample photos: re-framed,
    /// darker, or slightly rotated shots of one scene scored 0.16–0.76 (day
    /// vs night of one scene up to 0.78); different scenes 0.62–1.21, mean
    /// 1.03. Tune on a device — debug builds show each photo's score.
    static let matchThreshold: Float = 0.7

    /// A reference for `image`: a thumbnail to display plus its feature print.
    static func makeReference(from image: UIImage) async -> PhotoReference? {
        guard let working = jpeg(image, maxDimension: 1024, quality: 0.8),
              let thumbnail = jpeg(image, maxDimension: 400, quality: 0.7) else { return nil }
        let print = try? await Task.detached { try featurePrint(ofJPEG: working) }.value
        return print.map { PhotoReference(thumbnail: thumbnail, featurePrint: $0) }
    }

    /// How far `image` is from the reference spot (lower is closer).
    static func distance(from image: UIImage, to reference: PhotoReference) async -> Float? {
        guard let working = jpeg(image, maxDimension: 1024, quality: 0.8) else { return nil }
        let saved = reference.featurePrint
        return try? await Task.detached {
            try distance(between: saved, and: featurePrint(ofJPEG: working))
        }.value
    }

    /// Downscaled JPEG with the photo's orientation baked in, so every image
    /// reaches Vision upright.
    private static func jpeg(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    private nonisolated static func featurePrint(ofJPEG data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let request = VNGenerateImageFeaturePrintRequest()
        // Pinned so prints saved today stay comparable after iOS updates.
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else { throw CocoaError(.fileReadUnknown) }
        return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    private nonisolated static func distance(between a: Data, and b: Data) throws -> Float {
        guard let first = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: a),
              let second = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: b) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var distance: Float = 0
        try first.computeDistance(&distance, to: second)
        return distance
    }
}
