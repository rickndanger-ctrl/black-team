import SwiftUI
import AppKit
import ImageIO

/// The supplied artwork, loaded once from the bundle.
enum BrandArt {
    private static func cgImage(_ name: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The lockup with the PNG's outer black margin clipped, as brand.css does (1800 by 300 of 2048 by 768).
    static let wordmark: CGImage? = cgImage("black-team-logo")?.cropping(to: CGRect(x: 130, y: 186, width: 1800, height: 300))
    static let mark: CGImage? = cgImage("black-team-mark")
}

/// The square emblem on its own.
struct BrandEmblem: View {
    var size: CGFloat = 64
    var cornerRadius: CGFloat = 12
    @Environment(\.btTheme) private var theme
    var body: some View {
        Group {
            if let mark = BrandArt.mark {
                Image(decorative: mark, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.black)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(theme.line2, lineWidth: 1))
        .accessibilityLabel("Black Team")
    }
}

/// The logo wordmark with its black ground feathered into the surface behind it, fog behind,
/// and the tagline underneath. The Linux fog drifts; here it is still (it sits in the sidebar all day).
struct BrandWordmark: View {
    var caption: String? = "PRIVATE AI. TOTAL CONTROL."
    @Environment(\.btTheme) private var theme
    @Environment(\.btMetrics) private var metrics

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                ground
                fog
                lockup
            }
            .aspectRatio(6, contentMode: .fit)
            if let caption {
                Text(caption)
                    .font(BTFont.mono(metrics.compact ? 6 : 7, .medium))
                    .tracking(metrics.compact ? 1.2 : 1.6)
                    .foregroundStyle(theme.brandCaption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 14).padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Black Team. Private AI. Total control.")
    }

    private var lockup: some View {
        GeometryReader { geo in
            Group {
                if let art = BrandArt.wordmark {
                    Image(decorative: art, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Text("BLACK TEAM").font(BTFont.mono(22, .semibold))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .mask(softEllipse(width: geo.size.width, height: geo.size.height, rx: 0.66, ry: 0.5, solid: 0.6))
        }
    }

    private var ground: some View {
        GeometryReader { geo in
            softEllipse(width: geo.size.width, height: geo.size.height, rx: 0.58 * 1.12, ry: 0.48 * 1.1, solid: 0.4, color: theme.brandBg)
        }
    }

    private var fog: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                plume(theme.mist1, w * 0.30, h * 1.2).offset(x: -w * 0.2, y: 0)
                plume(theme.mist2, w * 0.26, h * 1.1).offset(x: w * 0.2, y: -h * 0.08)
                plume(theme.mist3, w * 0.44, h * 1.4).offset(y: h * 0.1)
            }
            .frame(width: w, height: h)
            .blur(radius: 12)
            .mask(softEllipse(width: w, height: h, rx: 0.5, ry: 0.5, solid: 0.25))
        }
    }

    private func plume(_ color: Color, _ w: CGFloat, _ h: CGFloat) -> some View {
        Color.clear.modifier(EllipseFill(color: color, width: w * 2, height: h))
    }

    /// An elliptical radial fade: opaque to `solid` of the radius, clear at the edge.
    private func softEllipse(width: CGFloat, height: CGFloat, rx: CGFloat, ry: CGFloat, solid: CGFloat, color: Color = .black) -> some View {
        Rectangle()
            .fill(RadialGradient(stops: [.init(color: color, location: 0), .init(color: color, location: solid), .init(color: color.opacity(0), location: 1)],
                                 center: .center, startRadius: 0, endRadius: 100))
            .frame(width: 200, height: 200)
            .scaleEffect(x: rx * width / 100, y: ry * height / 100)
            .frame(width: width, height: height)
    }
}

/// Fills an ellipse of the given size with a radial fade of one colour (used by the fog plumes).
private struct EllipseFill: ViewModifier {
    let color: Color, width: CGFloat, height: CGFloat
    func body(content: Content) -> some View {
        Rectangle()
            .fill(RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: 100))
            .frame(width: 200, height: 200)
            .scaleEffect(x: width / 200, y: height / 200)
            .frame(width: width, height: height)
    }
}
