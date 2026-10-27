import SwiftUI

/// Original flat vector artwork; no image downloads, frame rendering or personal photos.
/// The illustration is decorative. Feeding status is always also shown as text.
struct BabyIllustration: View {
    enum Pose: Equatable { case hello, feeding, resting, hungry, bottle }
    var pose: Pose = .hello
    var width: CGFloat = 110
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var blinking = false
    @State private var waving = false
    private var motionEnabled: Bool { animated && !reduceMotion && scenePhase == .active }

    var body: some View {
        ZStack {
            // Feet and a rounded, solid-colour romper.
            Ellipse().fill(Palette.skin).frame(width: 23, height: 18).offset(x: -19, y: 57)
            Ellipse().fill(Palette.skin).frame(width: 23, height: 18).offset(x: 19, y: 57)
            RoundedRectangle(cornerRadius: 28).fill(pose == .resting ? Color(hex: 0xA9C2A0) : Palette.romper)
                .frame(width: 71, height: 61).offset(y: 34)
            // Arms pivot from the shoulders. A single wave accompanies entering a state.
            arm(left: true)
            arm(left: false)
            Circle().fill(Palette.skin).frame(width: 16).offset(x: -43, y: -12)
            Circle().fill(Palette.skin).frame(width: 16).offset(x: 43, y: -12)
            RoundedRectangle(cornerRadius: 39).fill(Palette.skin).frame(width: 84, height: 78).offset(y: -17)
            // A little curl, rosy cheeks and a sleepy / awake expression.
            BabyCurl().stroke(Palette.artInk, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: 22, height: 22).offset(x: 0, y: -54)
            Ellipse().fill(Palette.blush).frame(width: 14, height: 8).offset(x: -25, y: -8)
            Ellipse().fill(Palette.blush).frame(width: 14, height: 8).offset(x: 25, y: -8)
            HStack(spacing: 22) {
                eye
                eye
            }.offset(y: -23)
            if pose == .hungry {
                Ellipse().fill(Palette.artInk).frame(width: 9, height: 11).offset(y: -5)
            } else {
                BabySmile().stroke(Palette.artInk, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 13, height: 8).offset(y: -4)
            }
            if pose == .bottle {
                bottle.rotationEffect(.degrees(-20)).offset(x: 18, y: 27)
            } else {
                Image(systemName: "heart.fill").font(.system(size: 15)).foregroundStyle(Color(hex: 0xFFF8ED)).offset(y: 31).accessibilityHidden(true)
            }
        }
        .frame(width: 140, height: 150)
        .scaleEffect(width / 140)
        .frame(width: width, height: width * 150 / 140)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 1), value: pose)
        .task(id: motionEnabled) {
            blinking = false
            waving = false
            guard motionEnabled else { return }
            do {
                // Brief greeting on appearance, then occasional blinking; the whole baby stays still.
                if pose == .hello || pose == .hungry {
                    withAnimation(.spring(response: 0.4, dampingFraction: 1)) { waving = true }
                    try await Task.sleep(for: .milliseconds(550))
                    withAnimation(.spring(response: 0.4, dampingFraction: 1)) { waving = false }
                }
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(6))
                    withAnimation(.easeInOut(duration: 0.12)) { blinking = true }
                    try await Task.sleep(for: .milliseconds(160))
                    withAnimation(.easeInOut(duration: 0.12)) { blinking = false }
                }
            } catch { /* SwiftUI cancels on disappearance or when the app goes inactive. */ }
        }
    }

    @ViewBuilder private var eye: some View {
        if pose == .resting {
            BabySmile().stroke(Palette.artInk, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).frame(width: 10, height: 5)
        } else {
            Capsule().fill(Palette.artInk).frame(width: 5, height: 8).scaleEffect(y: blinking ? 0.12 : 1)
        }
    }

    private func arm(left: Bool) -> some View {
        Capsule().fill(Palette.skin).frame(width: 17, height: 36)
            .rotationEffect(.degrees(left ? -34 : (waving ? -105 : 34)), anchor: .top)
            .offset(x: left ? -35 : 35, y: 27)
    }

    private var bottle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Palette.romper).frame(width: 8, height: 12).offset(y: -21)
            RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x89AABA)).frame(width: 22, height: 7).offset(y: -13)
            RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0xFFFAE9)).frame(width: 23, height: 31).offset(y: 4)
            VStack(spacing: 4) {
                Capsule().fill(Color(hex: 0x89AABA)).frame(width: 7, height: 2)
                Capsule().fill(Color(hex: 0x89AABA)).frame(width: 7, height: 2)
            }.offset(x: 4, y: 5)
        }.frame(width: 30, height: 50)
    }
}

private struct BabySmile: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        }
    }
}

private struct BabyCurl: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.width * 0.15, y: r.height * 0.9))
            p.addCurve(to: CGPoint(x: r.width * 0.85, y: r.height * 0.45), control1: CGPoint(x: r.width * 0.95, y: r.height * 0.9), control2: CGPoint(x: r.width, y: r.height * 0.1))
            p.addCurve(to: CGPoint(x: r.width * 0.45, y: r.height * 0.42), control1: CGPoint(x: r.width * 0.65, y: -r.height * 0.05), control2: CGPoint(x: r.width * 0.1, y: r.height * 0.05))
        }
    }
}
