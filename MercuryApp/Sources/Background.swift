import SwiftUI
import CoreImage
import ImageIO

/// A background the screen recording is composited onto (Screen Studio-style).
struct BackgroundOption: Identifiable, Hashable {
    enum Style: Hashable {
        case none
        case solid(String)              // hex
        case gradient(String, String)   // top-left hex, bottom-right hex
        case image(URL)
    }

    let id: String
    let name: String
    let style: Style

    var isNone: Bool { if case .none = style { return true }; return false }

    /// Built-in presets: "None" plus every image in the bundled `Backgrounds`
    /// folder. Drop a file into `Backgrounds/` and it appears here — no code
    /// change needed. The display name is derived from the filename, so name
    /// files the way you want them labelled (`Soft-Dusk.jpg` → "Soft Dusk").
    static let none = BackgroundOption(id: "none", name: "None", style: .none)

    static let presets: [BackgroundOption] = {
        [none] + bundledImages()
    }()

    private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "tiff"]

    private static func bundledImages() -> [BackgroundOption] {
        guard let dir = Bundle.main.resourceURL?
                .appendingPathComponent("Backgrounds", isDirectory: true),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else {
            AppLog.log("Backgrounds: no bundled folder found")
            return []
        }

        let options = urls
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            // localizedStandardCompare gives natural ordering, so image-2
            // sorts before image-10 rather than after it.
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending }
            .map {
                BackgroundOption(id: $0.deletingPathExtension().lastPathComponent,
                                 name: displayName(for: $0),
                                 style: .image($0))
            }
        AppLog.log("Backgrounds: \(options.count) bundled images")
        return options
    }

    /// `26-Tahoe-Dark.jpeg` → "Tahoe Dark"; `image-1.jpg` → "Image 1".
    private static func displayName(for url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        // Drop a leading sort prefix such as "26-" or "03_".
        if let prefix = stem.range(of: "^[0-9]+[-_]", options: .regularExpression) {
            stem.removeSubrange(prefix)
        }
        return stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// A custom background from a user-picked image file.
    static func custom(_ url: URL) -> BackgroundOption {
        .init(id: "custom", name: "Custom", style: .image(url))
    }
}

/// Amount of empty space around the inset screen content.
// MARK: - Color helpers

extension CIColor {
    static func fromHex(_ hex: String) -> CIColor {
        let (r, g, b) = rgb(from: hex)
        return CIColor(red: r, green: g, blue: b)
    }
}

extension Color {
    init(hex: String) {
        let (r, g, b) = rgb(from: hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

private func rgb(from hex: String) -> (CGFloat, CGFloat, CGFloat) {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    let r = CGFloat((v >> 16) & 0xFF) / 255
    let g = CGFloat((v >> 8) & 0xFF) / 255
    let b = CGFloat(v & 0xFF) / 255
    return (r, g, b)
}

// MARK: - SwiftUI swatch preview

extension BackgroundOption {
    @ViewBuilder
    var swatch: some View {
        switch style {
        case .none:
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "slash.circle").foregroundStyle(.secondary)
            }
        case .solid(let hex):
            Rectangle().fill(Color(hex: hex))
        case .gradient(let a, let b):
            LinearGradient(colors: [Color(hex: a), Color(hex: b)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .image(let url):
            AsyncImageOrColor(url: url)
        }
    }
}

/// Thumbnail for a background tile. Decodes a downsampled image via
/// CGImageSource rather than loading the full file — the bundled backgrounds
/// run to several megabytes each, and a grid of nineteen full-resolution
/// decodes visibly stalls the picker. Results are cached per URL.
private struct AsyncImageOrColor: View {
    let url: URL

    var body: some View {
        GeometryReader { geo in
            if let img = ThumbnailCache.shared.thumbnail(
                for: url, maxPixel: max(geo.size.width, geo.size.height) * 3) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
    }
}

private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func thumbnail(for url: URL, maxPixel: CGFloat) -> NSImage? {
        // Round up to a stable bucket so minor layout changes don't thrash the cache.
        let target = max(64, (maxPixel / 64).rounded(.up) * 64)
        let key = url as NSURL
        if let hit = cache.object(forKey: key) { return hit }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: target
              ] as CFDictionary)
        else { return nil }

        let img = NSImage(cgImage: cg, size: .zero)
        cache.setObject(img, forKey: key)
        return img
    }
}
