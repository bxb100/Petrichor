import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ImageUtils {
    private static let renderBitmapInfo =
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    private static let opaqueBitmapInfo =
        CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// Compress image data to HEIC format, downscaling to fit within maxDimension while preserving aspect ratio.
    /// Never upscales images smaller than maxDimension.
    /// - Parameters:
    ///   - imageData: Original image data in any supported format (JPEG, PNG, HEIC, etc.)
    ///   - maxDimension: Maximum width or height in pixels (default: 960)
    ///   - quality: HEIC compression quality (0.0 to 1.0, default: 0.8)
    ///   - source: Optional source identifier (e.g. file path) included in failure logs
    /// - Returns: Compressed HEIC data, or nil if compression fails
    static func compressImage(
        from imageData: Data,
        maxDimension: CGFloat = 960,
        quality: CGFloat = 0.8,
        source: String? = nil
    ) -> Data? {
        guard let cgImage = decodedCGImage(from: imageData, source: source) else { return nil }
        let preservesAlpha = hasAlphaChannel(cgImage)
        let preparedImage = preparedCGImageForStorage(cgImage, maxDimension: maxDimension) ?? cgImage
        return compressedImageData(from: preparedImage, quality: quality, preservesAlpha: preservesAlpha, source: source)
    }

    /// Validate that image data is decodable before storing or rendering it.
    static func validatedImageData(from imageData: Data, source: String? = nil) -> Data? {
        guard decodedCGImage(from: imageData, source: source) != nil else { return nil }
        return imageData
    }

    /// Validate image data and prefer a smaller re-encoded representation when storing artwork.
    /// Falls back to the original bytes when re-encoding is not beneficial or fails.
    static func processedImageDataForStorage(
        from imageData: Data,
        maxDimension: CGFloat = 960,
        quality: CGFloat = 0.8,
        source: String? = nil
    ) -> Data? {
        guard let cgImage = decodedCGImage(from: imageData, source: source) else { return nil }
        let preservesAlpha = hasAlphaChannel(cgImage)
        let preparedImage = preparedCGImageForStorage(cgImage, maxDimension: maxDimension) ?? cgImage

        guard let compressedData = compressedImageData(
            from: preparedImage,
            quality: quality,
            preservesAlpha: preservesAlpha,
            source: source
        ) else {
            return imageData
        }

        return compressedData.count < imageData.count ? compressedData : imageData
    }

    /// Encode a CGImage as HEIC data.
    static func encodeHEIC(
        _ cgImage: CGImage,
        quality: CGFloat = 0.8,
        preservesAlpha: Bool = true
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let encodedImage = imagePreparedForEncoding(cgImage, preservesAlpha: preservesAlpha)
        CGImageDestinationAddImage(destination, encodedImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            Logger.warning("Failed to encode image as HEIC")
            return nil
        }
        return data as Data
    }

    /// Resize an image from Data to specified size and return as JPEG Data
    /// - Parameters:
    ///   - imageData: Original image data
    ///   - size: Target size (will be used for both width and height)
    ///   - compressionFactor: JPEG compression quality (0.0 to 1.0)
    /// - Returns: Resized JPEG data, or nil if resizing fails
    static func resizeImage(from imageData: Data, to size: NSSize, compressionFactor: Float = 0.8) -> Data? {
        guard let cgImage = decodedCGImage(from: imageData) else { return nil }
        let preservesAlpha = hasAlphaChannel(cgImage)

        let width = Int(size.width)
        let height = Int(size.height)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: renderBitmapInfo
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let resizedCG = context.makeImage() else { return nil }
        return encodeJPEG(resizedCG, quality: CGFloat(compressionFactor), preservesAlpha: preservesAlpha)
    }

    static func decodedCGImage(from imageData: Data, source: String? = nil) -> CGImage? {
        if let nsImage = NSImage(data: imageData),
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return normalizedCGImageIfNeeded(cgImage)
        }

        guard let imageSource = CGImageSourceCreateWithData(
            imageData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary) else {
            let context = source.map { " from \($0)" } ?? ""
            Logger.warning("Failed to decode image\(context) (\(imageData.count) bytes)")
            return nil
        }

        return normalizedCGImageIfNeeded(cgImage)
    }

    private static func normalizedCGImageIfNeeded(_ cgImage: CGImage) -> CGImage {
        let alphaInfo = CGImageAlphaInfo(
            rawValue: cgImage.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue
        ) ?? .none
        let hasCompatibleLayout =
            cgImage.bitsPerComponent == 8 &&
            cgImage.bitsPerPixel == 32 &&
            cgImage.colorSpace?.model == .rgb &&
            [
                CGImageAlphaInfo.premultipliedFirst,
                .premultipliedLast,
                .first,
                .last,
                .noneSkipFirst,
                .noneSkipLast
            ].contains(alphaInfo)

        guard !hasCompatibleLayout else { return cgImage }

        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: renderBitmapInfo
        ) else {
            return cgImage
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return context.makeImage() ?? cgImage
    }

    private static func encodeJPEG(
        _ cgImage: CGImage,
        quality: CGFloat,
        preservesAlpha: Bool
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let encodedImage = imagePreparedForEncoding(cgImage, preservesAlpha: preservesAlpha)
        CGImageDestinationAddImage(destination, encodedImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            Logger.warning("Failed to encode image as JPEG")
            return nil
        }
        return data as Data
    }

    private static func imagePreparedForEncoding(_ cgImage: CGImage, preservesAlpha: Bool) -> CGImage {
        guard !preservesAlpha else { return cgImage }

        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: opaqueBitmapInfo
        ) else {
            return cgImage
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return context.makeImage() ?? cgImage
    }

    private static func preparedCGImageForStorage(_ cgImage: CGImage, maxDimension: CGFloat) -> CGImage? {
        let srcWidth = CGFloat(cgImage.width)
        let srcHeight = CGFloat(cgImage.height)

        guard srcWidth > maxDimension || srcHeight > maxDimension else {
            return cgImage
        }

        let scale = min(maxDimension / srcWidth, maxDimension / srcHeight)
        let destWidth = max(1, Int((srcWidth * scale).rounded(.down)))
        let destHeight = max(1, Int((srcHeight * scale).rounded(.down)))

        guard let context = CGContext(
            data: nil,
            width: destWidth,
            height: destHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: renderBitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(destWidth), height: CGFloat(destHeight)))
        return context.makeImage()
    }

    private static func compressedImageData(
        from cgImage: CGImage,
        quality: CGFloat,
        preservesAlpha: Bool,
        source: String?
    ) -> Data? {
        if let heicData = encodeHEIC(cgImage, quality: quality, preservesAlpha: preservesAlpha) {
            return heicData
        }

        let logContext = source.map { " from \($0)" } ?? ""
        Logger.warning("HEIC encoding failed\(logContext), falling back to JPEG")
        return encodeJPEG(cgImage, quality: quality, preservesAlpha: preservesAlpha)
    }

    private static func hasAlphaChannel(_ cgImage: CGImage) -> Bool {
        let alphaInfo = CGImageAlphaInfo(
            rawValue: cgImage.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue
        ) ?? cgImage.alphaInfo

        switch alphaInfo {
        case .premultipliedFirst, .premultipliedLast, .first, .last:
            return true
        case .alphaOnly:
            return true
        default:
            return false
        }
    }
    
    /// Extract dominant colors from image data using grid-based sampling with diversity selection.
    /// Samples a 4x4 grid via CIAreaAverage, then greedily picks the most distinct colors.
    /// - Parameters:
    ///   - imageData: Image data in any supported format
    ///   - colorCount: Number of dominant colors to return (default: 6)
    /// - Returns: Array of NSColor with maximum color diversity, or empty array if extraction fails
    static func extractDominantColors(
        from imageData: Data,
        colorCount: Int = 6
    ) -> [NSColor] {
        guard let ciImage = CIImage(data: imageData) else { return [] }

        let extent = ciImage.extent
        let gridSize = 4
        let cellW = extent.width / CGFloat(gridSize)
        let cellH = extent.height / CGFloat(gridSize)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])

        // Sample each grid cell to build candidate colors
        var candidates: [(h: CGFloat, s: CGFloat, b: CGFloat)] = []
        var pixel = [UInt8](repeating: 0, count: 4)

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let rect = CGRect(
                    x: extent.origin.x + cellW * CGFloat(col),
                    y: extent.origin.y + cellH * CGFloat(row),
                    width: cellW,
                    height: cellH
                )

                guard let filter = CIFilter(
                    name: "CIAreaAverage",
                    parameters: [
                        kCIInputImageKey: ciImage.cropped(to: rect),
                        kCIInputExtentKey: CIVector(cgRect: rect)
                    ]
                ), let output = filter.outputImage else { continue }

                ctx.render(
                    output,
                    toBitmap: &pixel,
                    rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )

                let r = CGFloat(pixel[0]) / 255.0
                let g = CGFloat(pixel[1]) / 255.0
                let b = CGFloat(pixel[2]) / 255.0

                // Clamp near-black to dark grey and near-white to light grey
                let cR = min(max(r, 0.05), 0.9)
                let cG = min(max(g, 0.05), 0.9)
                let cB = min(max(b, 0.05), 0.9)

                var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0
                NSColor(red: cR, green: cG, blue: cB, alpha: 1).getHue(&h, saturation: &s, brightness: &br, alpha: nil)
                candidates.append((h, s, br))
            }
        }

        guard !candidates.isEmpty else { return [] }

        // Greedy farthest-point selection for maximum diversity
        var selected = [candidates.max { $0.s < $1.s }!]

        while selected.count < min(colorCount, candidates.count) {
            var bestIdx = 0
            var bestDist: CGFloat = -1

            for (i, c) in candidates.enumerated() {
                let minDist = selected.map { s -> CGFloat in
                    let hd = min(abs(c.h - s.h), 1 - abs(c.h - s.h))
                    return hd * hd * 4 + (c.s - s.s) * (c.s - s.s) + (c.b - s.b) * (c.b - s.b)
                }.min() ?? 0

                if minDist > bestDist {
                    bestDist = minDist
                    bestIdx = i
                }
            }

            selected.append(candidates[bestIdx])
        }

        return selected.map { NSColor(hue: $0.h, saturation: $0.s, brightness: $0.b, alpha: 1) }
    }

    /// Adjust dominant colors for use as background gradients based on color scheme.
    /// - Parameters:
    ///   - colors: Raw dominant colors from extractDominantColors
    ///   - isDark: Whether the current color scheme is dark mode
    /// - Returns: Array of SwiftUI Colors adjusted for background use
    static func backgroundGradientColors(
        from colors: [NSColor],
        isDark: Bool
    ) -> [Color] {
        colors.map { color -> Color in
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return Color(nsColor: color) }

            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

            if isDark {
                brightness = min(brightness, 0.55)
                saturation = min(saturation, 0.8)
            } else {
                brightness = max(brightness, 0.6)
                saturation = min(saturation, 0.7)
            }

            return Color(nsColor: NSColor(
                hue: hue,
                saturation: saturation,
                brightness: brightness,
                alpha: alpha
            ))
        }
    }

    // MARK: - Cached Color Lookups

    private static var colorCache = NSCache<NSString, CachedNSColors>()

    /// Returns cached dominant colors for the given ID, extracting from imageData on cache miss.
    static func cachedDominantColors(
        id: UUID,
        imageData: Data
    ) -> [NSColor] {
        let cacheKey = "\(id.uuidString)-dominantColors" as NSString
        if let cached = colorCache.object(forKey: cacheKey) {
            return cached.colors
        }

        let colors = extractDominantColors(from: imageData)
        colorCache.setObject(CachedNSColors(colors: colors), forKey: cacheKey)
        return colors
    }

    /// Returns cached background gradient colors for the given ID and color scheme.
    static func cachedBackgroundGradientColors(
        id: UUID,
        imageData: Data,
        isDark: Bool
    ) -> [Color] {
        let suffix = isDark ? "dark" : "light"
        let cacheKey = "\(id.uuidString)-gradient-\(suffix)" as NSString
        if let cached = colorCache.object(forKey: cacheKey) {
            return cached.colors.map { Color(nsColor: $0) }
        }

        let dominant = cachedDominantColors(id: id, imageData: imageData)
        let adjusted = backgroundGradientColors(from: dominant, isDark: isDark)
        let nsColors = adjusted.map { NSColor($0) }
        colorCache.setObject(CachedNSColors(colors: nsColors), forKey: cacheKey)
        return adjusted
    }

    /// Common sizes used in the app
    enum Size {
        static let small = NSSize(width: ViewDefaults.tableArtworkSize * 2, height: ViewDefaults.tableArtworkSize * 2)    // Table view (2x retina)
        static let medium = NSSize(width: ViewDefaults.listArtworkSize * 2, height: ViewDefaults.listArtworkSize * 2)     // List view (2x retina)
        static let large = NSSize(width: ViewDefaults.gridArtworkSize * 2, height: ViewDefaults.gridArtworkSize * 2)      // Grid view (2x retina)
    }
}

// MARK: - Color Cache Object

private class CachedNSColors: NSObject {
    let colors: [NSColor]
    init(colors: [NSColor]) { self.colors = colors }
}
