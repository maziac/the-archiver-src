import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Zielgröße pro DIN-A4-Seite.
public enum SizePreset: String, Codable, CaseIterable, Sendable {
    case original, kb300, kb150, kb80, kb40

    /// Zielgröße in Bytes für eine A4-Seite; nil = keine Kompression
    public var targetBytesA4: Int? {
        switch self {
        case .original: return nil
        case .kb300: return 300_000
        case .kb150: return 150_000
        case .kb80: return 80_000
        case .kb40: return 40_000
        }
    }

    public var label: String {
        switch self {
        case .original: return "Original (keine Kompression)"
        case .kb300: return "ca. 300 KB pro Seite (hohe Qualität)"
        case .kb150: return "ca. 150 KB pro Seite"
        case .kb80: return "ca. 80 KB pro Seite"
        case .kb40: return "ca. 40 KB pro Seite (klein)"
        }
    }
}

/// Farbmodus beim Umwandeln.
public enum ColorMode: String, Codable, CaseIterable, Sendable {
    case original, gray, blackWhite

    public var label: String {
        switch self {
        case .original: return "Farbe/Original"
        case .gray: return "Graustufen"
        case .blackWhite: return "Schwarz-Weiß (1 Bit)"
        }
    }
}

/// Ein fürs PDF fertig kodiertes Seitenbild.
public struct EncodedImage {
    /// wird unverändert ins PDF gezeichnet (JPEG-Daten werden von Quartz direkt übernommen)
    public let image: CGImage
    /// geschätzte Größe im PDF
    public let bytes: Int
    public let dpi: Double
}

public enum PageCompressor {
    static let a4Area: Double = 595.2 * 841.9
    static let minQuality = 0.25
    static let maxQuality = 0.9

    /// Kodiert ein Seitenbild für die gegebene Seitengröße (Punkte) nach Zielgröße und Farbmodus.
    /// - Parameter originalJPEG: Originaldaten, falls das Bild ein JPEG war (für „Original“ unverändert übernommen)
    public static func encode(_ image: CGImage, pageSize: CGSize, preset: SizePreset, color: ColorMode,
                              originalJPEG: Data? = nil) -> EncodedImage {
        let dpi = Double(image.width) / (pageSize.width / 72)

        guard let target = preset.targetBytesA4.map({ Int(Double($0) * Double(pageSize.width * pageSize.height) / a4Area) }) else {
            // keine Kompression
            if color == .original, let originalJPEG, let jpeg = jpegImage(originalJPEG) {
                return EncodedImage(image: jpeg, bytes: originalJPEG.count, dpi: dpi)
            }
            let converted = convert(image, to: color)
            return EncodedImage(image: converted, bytes: losslessSize(converted), dpi: dpi)
        }

        // Verlustfrei in voller Auflösung ist bei sauberen Seiten oft schon klein genug – dann ist es
        // die beste Wahl (keine Artefakte). Sonst dient es als Obergrenze für die JPEG-Versuche.
        let fullConverted = convert(image, to: color)
        let lossless = EncodedImage(image: fullConverted, bytes: losslessSize(fullConverted), dpi: dpi)
        if lossless.bytes <= target { return lossless }

        // Auflösungsstufen: Original, dann 200 und 150 dpi, falls das Ziel sonst nicht erreichbar ist
        let steps = [dpi] + [200.0, 150.0].filter { $0 < dpi - 1 }
        var best: EncodedImage? = lossless
        for stepDPI in steps {
            let converted = stepDPI < dpi - 1 ? convert(resample(image, scale: stepDPI / dpi), to: color) : fullConverted
            let candidate: EncodedImage
            if color == .blackWhite {
                candidate = EncodedImage(image: converted, bytes: losslessSize(converted), dpi: stepDPI)
            } else {
                guard let jpeg = bestJPEG(converted, target: target) else { continue }
                candidate = EncodedImage(image: jpeg.image, bytes: jpeg.bytes, dpi: stepDPI)
            }
            if best == nil || candidate.bytes < best!.bytes { best = candidate }
            if candidate.bytes <= target { return candidate }
        }
        return best ?? EncodedImage(image: image, bytes: losslessSize(image), dpi: dpi)
    }

    // MARK: JPEG

    /// Höchste Qualität, die noch ins Ziel passt (Binärsuche); sonst die kleinste.
    private static func bestJPEG(_ image: CGImage, target: Int) -> (image: CGImage, bytes: Int)? {
        var low = minQuality, high = maxQuality
        var best: Data?
        guard let smallest = jpegData(image, quality: low) else { return nil }
        if smallest.count > target { return jpegImage(smallest).map { ($0, smallest.count) } }
        best = smallest
        for _ in 0..<6 {
            let mid = (low + high) / 2
            guard let data = jpegData(image, quality: mid) else { break }
            if data.count <= target { best = data; low = mid } else { high = mid }
        }
        if let top = jpegData(image, quality: maxQuality), top.count <= target { best = top }
        guard let best, let decoded = jpegImage(best) else { return nil }
        return (decoded, best.count)
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func jpegImage(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Farbe

    static func convert(_ image: CGImage, to mode: ColorMode) -> CGImage {
        switch mode {
        case .original: return image
        case .gray: return grayscale(image) ?? image
        case .blackWhite: return grayscale(image).flatMap(oneBit) ?? image
        }
    }

    private static func grayscale(_ image: CGImage) -> CGImage? {
        if image.colorSpace?.model == .monochrome, image.bitsPerComponent == 8, image.bitsPerPixel == 8 { return image }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// 1-Bit-Bild mit automatisch bestimmtem Schwellwert (Otsu).
    private static func oneBit(_ gray: CGImage) -> CGImage? {
        let width = gray.width, height = gray.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(gray, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = ctx.data else { return nil }
        let pixels = raw.assumingMemoryBound(to: UInt8.self)
        let stride = ctx.bytesPerRow

        var histogram = [Int](repeating: 0, count: 256)
        for y in 0..<height { for x in 0..<width { histogram[Int(pixels[y * stride + x])] += 1 } }
        let threshold = otsu(histogram, total: width * height)

        let rowBytes = (width + 7) / 8
        var packed = Data(count: rowBytes * height)
        packed.withUnsafeMutableBytes { buffer in
            let out = buffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width where Int(pixels[y * stride + x]) > threshold {
                    out[y * rowBytes + x / 8] |= UInt8(0x80 >> (x % 8))  // 1 = weiß
                }
            }
        }
        guard let provider = CGDataProvider(data: packed as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func otsu(_ histogram: [Int], total: Int) -> Int {
        let sumAll = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var sumBackground = 0.0, weightBackground = 0.0
        var bestVariance = 0.0, threshold = 127
        for t in 0..<256 {
            weightBackground += Double(histogram[t])
            if weightBackground == 0 { continue }
            let weightForeground = Double(total) - weightBackground
            if weightForeground == 0 { break }
            sumBackground += Double(t * histogram[t])
            let meanB = sumBackground / weightBackground
            let meanF = (sumAll - sumBackground) / weightForeground
            let variance = weightBackground * weightForeground * (meanB - meanF) * (meanB - meanF)
            if variance > bestVariance { bestVariance = variance; threshold = t }
        }
        return threshold
    }

    // MARK: Hilfen

    static func resample(_ image: CGImage, scale: Double) -> CGImage {
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        let gray = image.colorSpace?.model == .monochrome
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// Geschätzte Größe bei verlustfreier Einbettung (Quartz nutzt Flate/zlib).
    static func losslessSize(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return image.bytesPerRow * image.height }
        let capacity = data.count + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let size = data.withUnsafeBytes { source in
            compression_encode_buffer(destination, capacity, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return size > 0 ? size : data.count
    }
}
