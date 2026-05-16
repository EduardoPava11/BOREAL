import CoreImage
import CoreGraphics
import Foundation

/// Generates a 128×128 portrait-oriented thumbnail from a crop-tagged DNG for the UI grid.
///
/// CIRAWFilter automatically honors `DefaultCropOrigin` / `DefaultCropSize` and the EXIF
/// `Orientation` tag, so the returned CIImage is already cropped to 3024×3024 and rotated
/// to portrait. We only need to downscale and rasterize.
///
/// IMPORTANT: CIRAWFilter has an instance-reuse bug — always create fresh per call.
enum PreviewGenerator {
    static func portraitThumb(from dngURL: URL,
                              ctx: CIContext,
                              side: CGFloat = 128) -> CGImage? {
        guard let raw = CIRAWFilter(imageURL: dngURL),
              let img = raw.outputImage else {
            Log.processing.error("PreviewGenerator: CIRAWFilter failed for \(dngURL.lastPathComponent, privacy: .public)")
            return nil
        }
        let extent = img.extent
        let scale = side / max(extent.width, extent.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Render into a side×side rect anchored at the scaled image's origin.
        let target = CGRect(x: scaled.extent.origin.x,
                            y: scaled.extent.origin.y,
                            width: side, height: side)
        return ctx.createCGImage(scaled, from: target)
    }
}
