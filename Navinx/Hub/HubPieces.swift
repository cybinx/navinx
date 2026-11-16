import SwiftUI
import UIKit

/// Flutter's `AddCard` in glass mode (C12, D30): a frosted card with 22 pt corners. What sits inside
/// stays plain (no glass in glass). `glass: false` is Flutter's translucent card, for content that has
/// glass of its own (rows with glass pills).
struct HubCard<Content: View>: View {
    var padding = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    var glass = true
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22)
        let card = content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        if glass {
            card.appGlass(in: shape)
        } else {
            card.background(Palette.card.opacity(colorScheme == .dark ? 0.55 : 0.62), in: shape)
        }
    }
}

/// Flutter's `GlassAmbientBackdrop`: the page's colour, with three soft blobs of the accent and
/// two hue-shifted neighbours, so the glass cards have colour behind them.
struct HubBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Centre (fractions of width and height) and radius (fraction of width), as Flutter's.
    private static let blobs: [(x: CGFloat, y: CGFloat, r: CGFloat, hueShift: Double)] = [
        (0.10, 0.10, 0.95, 0), (0.95, 0.42, 0.85, 48), (0.20, 0.85, 0.95, -56),
    ]

    var body: some View {
        let strength = colorScheme == .dark ? 0.42 : 0.30
        let accent = UIColor(Palette.accent)
        GeometryReader { geometry in
            ZStack {
                Palette.background
                ForEach(Self.blobs.indices, id: \.self) { index in
                    let blob = Self.blobs[index]
                    let color = Color(uiColor: accent.shiftingHSLHue(by: blob.hueShift))
                    RadialGradient(
                        stops: [
                            .init(color: color.opacity(strength), location: 0),
                            .init(color: color.opacity(strength * 0.35), location: 0.5),
                            .init(color: color.opacity(0), location: 1),
                        ],
                        center: UnitPoint(x: blob.x, y: blob.y),
                        startRadius: 0,
                        endRadius: geometry.size.width * blob.r
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

extension UIColor {
    /// The colour with its HSL hue turned by `degrees` (Flutter's `HSLColor.withHue`).
    func shiftingHSLHue(by degrees: Double) -> UIColor {
        guard degrees != 0 else { return self }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let (h, s, l) = Self.hsl(r: r, g: g, b: b)
        let hue = (h + degrees).truncatingRemainder(dividingBy: 360)
        let (nr, ng, nb) = Self.rgb(h: hue < 0 ? hue + 360 : hue, s: s, l: l)
        return UIColor(red: nr, green: ng, blue: nb, alpha: a)
    }

    nonisolated static func hsl(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxValue = max(r, g, b), minValue = min(r, g, b)
        let l = (maxValue + minValue) / 2
        let delta = maxValue - minValue
        guard delta > 0 else { return (0, 0, l) }
        let s = delta / (1 - abs(2 * l - 1))
        var h: Double
        switch maxValue {
        case r: h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: h = 60 * ((b - r) / delta + 2)
        default: h = 60 * ((r - g) / delta + 4)
        }
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    nonisolated static func rgb(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double) = switch h {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}

/// The 6 pt progress bar, moving while there's no value (Flutter `LinearProgressIndicator`).
struct HubProgressBar: View {
    let value: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.accent.opacity(0.22))
                if let value {
                    Capsule().fill(Palette.accent).frame(width: max(6, width * value))
                        .animation(.easeOut(duration: 0.3), value: value)
                } else {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(Palette.accent)
                            .frame(width: width * 0.35)
                            .offset(x: (width * 1.35) * phase - width * 0.35)
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(.capsule)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Waiting")
    }
}

/// A wide picture at the server's aspect, or Flutter's accent gradient with a note while it loads, if
/// there's none, or if it fails. Loaded through the app's picture cache and decoded no larger than it's
/// shown, however large the file.
struct HubPicture: View {
    let url: URL?
    let aspect: CGFloat
    @State private var shown: (url: URL, image: UIImage)?
    @State private var width: CGFloat = 0
    @Environment(\.displayScale) private var scale

    /// The longest a picture is decoded, in pixels, whatever the screen.
    static let largestDecode: CGFloat = 4000

    private struct Load: Equatable {
        let url: URL?
        let pixels: Int
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay {
                if let shown, shown.url == url {
                    Image(uiImage: shown.image).resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(.rect(cornerRadius: 22))
            .task(id: Load(url: url, pixels: pixels)) {
                guard let url, pixels > 0 else { return }
                let cache = ArtworkCache.shared
                let image: UIImage?
                if let hit = cache.cached(url: url, maxPixel: pixels) {
                    image = hit
                } else {
                    image = await cache.image(url: url, maxPixel: pixels)
                }
                // A failed load at a new size keeps the picture already shown for this address.
                guard !Task.isCancelled, let image else { return }
                shown = (url, image)
            }
    }

    /// The frame's long side in device pixels: the picture fills it at the server's aspect.
    private var pixels: Int {
        guard width > 0, aspect > 0 else { return 0 }
        let long = max(width, width / aspect) * scale
        return long.isFinite ? Int(min(long, Self.largestDecode).rounded(.up)) : 0
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Palette.accent, Palette.accent.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "music.note")
                .font(.system(size: 42))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// A row's cover (a remote image, loaded with no login), or Flutter's accent gradient with a note while
/// it loads, if there's none or if it fails. Corners of 10.
struct HubCover: View {
    let url: URL?
    let size: CGFloat
    /// The picture loaded, with the address it's for: one for another address isn't shown.
    @State private var shown: (url: URL, image: UIImage)?
    @Environment(\.displayScale) private var scale

    private var image: UIImage? {
        guard let shown, shown.url == url else { return nil }
        return shown.image
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(
                    colors: [Palette.accent, Palette.accent.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.34))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            let pixels = ArtworkCache.pixels(size: size, scale: scale)
            let image: UIImage?
            if let hit = ArtworkCache.shared.cached(url: url, maxPixel: pixels.decode) {
                image = hit
            } else {
                image = await ArtworkCache.shared.image(url: url, maxPixel: pixels.decode)
            }
            // A load overtaken by another address, or that failed, changes nothing.
            guard !Task.isCancelled, let image else { return }
            shown = (url, image)
        }
    }
}

