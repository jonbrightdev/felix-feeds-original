import SwiftUI

/// A decorative, single-colour parent cradling a baby, with no skin-tone default.
struct BreastfeedingIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 64
            context.scaleBy(x: scale, y: scale)
            let ink = GraphicsContext.Shading.color(Palette.green)
            let stroke = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            context.stroke(Path(ellipseIn: CGRect(x: 20, y: 5, width: 15, height: 15)), with: ink, style: stroke)
            context.stroke(Path(ellipseIn: CGRect(x: 37, y: 27, width: 11, height: 11)), with: ink, style: stroke)

            var parent = Path()
            parent.move(to: CGPoint(x: 26, y: 25))
            parent.addCurve(to: CGPoint(x: 15, y: 55), control1: CGPoint(x: 14, y: 28), control2: CGPoint(x: 13, y: 43))
            parent.move(to: CGPoint(x: 29, y: 26))
            parent.addQuadCurve(to: CGPoint(x: 35, y: 34), control: CGPoint(x: 33, y: 29))
            parent.move(to: CGPoint(x: 23, y: 36))
            parent.addCurve(to: CGPoint(x: 45, y: 47), control1: CGPoint(x: 24, y: 49), control2: CGPoint(x: 35, y: 53))
            parent.addQuadCurve(to: CGPoint(x: 49, y: 42), control: CGPoint(x: 49, y: 45))
            parent.move(to: CGPoint(x: 28, y: 42))
            parent.addQuadCurve(to: CGPoint(x: 39, y: 37), control: CGPoint(x: 31, y: 36))
            parent.move(to: CGPoint(x: 17, y: 57))
            parent.addQuadCurve(to: CGPoint(x: 47, y: 57), control: CGPoint(x: 31, y: 60))
            context.stroke(parent, with: ink, style: stroke)
        }
        .frame(width: 62, height: 66)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
