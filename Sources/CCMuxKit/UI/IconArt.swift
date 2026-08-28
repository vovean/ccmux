import CCMuxCore
import SwiftUI

/// The Claude burst: tapered rays radiating from a point, blunt-tipped, alternating
/// long and short. Drawn rather than shipped as a bitmap so the icon can be re-rendered
/// at any size from `ccmux --render-icon`.
public struct ClaudeBurst: Shape {
    /// Long rays at the cardinal-ish angles, short ones between, which is what gives
    /// the mark its spiky-but-solid weight.
    private static let rayCount = 12

    public init() {}

    public func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let unit = min(rect.width, rect.height) / 2
        var path = Path()

        for index in 0..<Self.rayCount {
            let isLong = index.isMultiple(of: 2)
            let angle = (Double(index) / Double(Self.rayCount)) * 2 * .pi - .pi / 2
            let outer = unit * (isLong ? 1.0 : 0.66)
            let innerRadius = unit * 0.07
            // Rays widen towards the tip; the taper is what separates the mark from a
            // plain asterisk.
            let baseHalf = unit * 0.055
            let tipHalf = unit * (isLong ? 0.105 : 0.088)

            let normal = angle + .pi / 2
            func point(_ radius: Double, _ offset: Double) -> CGPoint {
                CGPoint(x: center.x + cos(angle) * radius + cos(normal) * offset,
                        y: center.y + sin(angle) * radius + sin(normal) * offset)
            }

            path.move(to: point(innerRadius, -baseHalf))
            path.addLine(to: point(outer - tipHalf * 0.7, -tipHalf))
            // A blunt, slightly rounded tip; a sharp point reads as noise below 32pt.
            path.addQuadCurve(to: point(outer - tipHalf * 0.7, tipHalf),
                              control: point(outer + tipHalf * 0.35, 0))
            path.addLine(to: point(innerRadius, baseHalf))
            path.closeSubpath()
        }

        path.addEllipse(in: CGRect(x: center.x - unit * 0.1, y: center.y - unit * 0.1,
                                   width: unit * 0.2, height: unit * 0.2))
        return path
    }
}

/// The app icon: three Claude marks standing one behind another, each further back
/// smaller and dimmer — one session per clone, which is what ccmux does.
public struct AppIconArt: View {
    private let side: CGFloat

    public init(side: CGFloat = 1024) {
        self.side = side
    }

    /// Depth ordering, furthest first. Spacing is wide enough that the clones read as
    /// separate figures rather than a motion blur, and each one in front casts onto the
    /// one behind it — which is what makes stacked silhouettes legible.
    private var clones: [(offset: CGSize, scale: CGFloat, opacity: Double, shadow: Double)] {
        [(CGSize(width: 0.190, height: -0.136), 0.58, 0.38, 0.0),
         (CGSize(width: 0.095, height: -0.068), 0.77, 0.62, 0.30),
         (.zero, 1.0, 1.0, 0.42)]
    }

    public var body: some View {
        ZStack {
            // A transparent margin plus a continuous-corner squircle: a full-bleed
            // square reads as an unfinished icon in the Dock.
            Color.clear
            ZStack {
                LinearGradient(colors: [Color(red: 0.88, green: 0.53, blue: 0.38),
                                        Color(red: 0.57, green: 0.21, blue: 0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                ZStack {
                    ForEach(clones.indices, id: \.self) { index in
                        let clone = clones[index]
                        ClaudeBurst()
                            .fill(.white)
                            .opacity(clone.opacity)
                            .frame(width: side * 0.395, height: side * 0.395)
                            .scaleEffect(clone.scale)
                            .shadow(color: .black.opacity(clone.shadow),
                                    radius: side * 0.016,
                                    x: -side * 0.004, y: side * 0.006)
                            .offset(x: side * clone.offset.width,
                                    y: side * clone.offset.height)
                    }
                }
                // The clones fan up and to the right, so the group is nudged back down
                // and left by half its spread to sit centred in the frame.
                .offset(x: -side * 0.062, y: side * 0.042)
            }
            .frame(width: side * 0.805, height: side * 0.805)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
            .shadow(color: .black.opacity(0.26), radius: side * 0.012, y: side * 0.01)
        }
        .frame(width: side, height: side)
    }
}
