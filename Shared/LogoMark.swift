import SwiftUI

// The app icon's mark — the "h" frame with the up/down chevrons and the dot,
// see logo.svg — drawn as shapes so no target needs an image asset for it
// (the watch widget extension has no asset catalog). This is the icon's
// small-size cut: heavier strokes and a solid dot instead of the rings, so
// it survives at complication sizes. Colours follow the ground like the app
// icon's: lilac frame and ping green on light, cream and mint on dark
// (HissiMarkFrame/HissiMarkAccent in Shared/Colors.xcassets). The watch is
// always dark, so its targets spell the dark pair out rather than trusting
// the catalog's appearance resolution on the wrist. Tinted faces render
// complications in accented mode, which flattens everything to the face's
// tint — the mark then survives by shape.
//
// In Shared/ because the watch widget extension draws it on the face and the
// iOS widget extension draws it for the watch presentation of the Live
// Activity (rendered on the phone, mirrored to the wrist).
struct LogoMark: View {
    #if os(watchOS)
    private static let frame  = Color(red: 251/255, green: 243/255, blue: 228/255)
    private static let accent = Color(red: 63/255,  green: 224/255, blue: 197/255)
    #else
    private static let frame  = Color.hissiMarkFrame
    private static let accent = Color.hissiMarkAccent
    #endif

    var body: some View {
        ZStack {
            LogoPart.frame.fill(Self.frame)
            LogoPart.chevrons.fill(Self.accent)
            LogoPart.dot.fill(Self.accent)
        }
        .aspectRatio(LogoPart.bounds.width / LogoPart.bounds.height, contentMode: .fit)
    }

    // For accessoryInline, which takes an Image and nothing else. The system
    // renders inline images as monochrome templates, so only the shape
    // survives there — colour is not on offer in that family.
    // UIKit-only (the SwiftPM test package compiles Shared/ on macOS).
    #if canImport(UIKit)
    @MainActor
    static func image(pointSize: CGFloat, scale: CGFloat) -> Image {
        let renderer = ImageRenderer(content: LogoMark().frame(height: pointSize))
        renderer.scale = scale
        guard let uiImage = renderer.uiImage else { return Image(systemName: "star") }
        return Image(uiImage: uiImage.withRenderingMode(.alwaysTemplate))
    }
    #endif
}

// Geometry in the icon's 160-unit space (the strokes already outlined, so
// every part fills), fitted into the given rect.
enum LogoPart: Shape {
    case frame, chevrons, dot

    // Outer extent including stroke widths: frame stroke 22 (left edge 33),
    // dot radius 19 around (116, 40).
    static let bounds = CGRect(x: 33, y: 21, width: 102, height: 117)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.bounds.width, rect.height / Self.bounds.height)
        let origin = CGPoint(
            x: rect.midX - Self.bounds.midX * scale,
            y: rect.midY - Self.bounds.midY * scale
        )
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        switch self {
        case .frame:
            // Left post, then the arch: up the left post, over the top with
            // two quarter arcs, down the right post.
            path.move(to: point(44, 12))
            path.addLine(to: point(44, 138))
            path.move(to: point(44, 62))
            path.addArc(tangent1End: point(44, 40), tangent2End: point(66, 40), radius: 22 * scale)
            path.addLine(to: point(94, 40))
            path.addArc(tangent1End: point(116, 40), tangent2End: point(116, 62), radius: 22 * scale)
            path.addLine(to: point(116, 138))
            return path.strokedPath(StrokeStyle(lineWidth: 22 * scale, lineCap: .butt, lineJoin: .miter))
        case .chevrons:
            path.move(to: point(64, 82))
            path.addLine(to: point(80, 66))
            path.addLine(to: point(96, 82))
            path.move(to: point(64, 106))
            path.addLine(to: point(80, 122))
            path.addLine(to: point(96, 106))
            return path.strokedPath(StrokeStyle(lineWidth: 15 * scale, lineCap: .round, lineJoin: .round))
        case .dot:
            path.addEllipse(in: CGRect(
                x: point(116, 40).x - 19 * scale,
                y: point(116, 40).y - 19 * scale,
                width: 38 * scale,
                height: 38 * scale
            ))
            return path
        }
    }
}
