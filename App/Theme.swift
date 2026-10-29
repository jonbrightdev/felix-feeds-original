import SwiftUI

/// Solid colour surfaces shared by the app. Illustration colours stay the same in both themes.
enum Palette {
    static let green = Color("AccentColor")
    static let button = Color(hex: 0x315D4E)
    static let ink = adaptive(0x284A3D, 0xF6F1E5)
    static let secondary = adaptive(0x526553, 0xC2CFC4)
    static let background = adaptive(0xFFF8ED, 0x192A25)
    static let card = adaptive(0xFFFFFF, 0x263B33)
    static let sage = adaptive(0xE0EACC, 0x354B3B)
    static let blue = adaptive(0xDFECF5, 0x2C414B)
    static let yellow = adaptive(0xF7E6AB, 0x4A432B)
    static let artInk = Color(hex: 0x344C40)
    static let skin = Color(hex: 0xF4BB95)
    static let blush = Color(hex: 0xEA907D)
    static let romper = Color(hex: 0xE6AF67)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct SoftPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func felixFormStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(Palette.background)
            .foregroundStyle(Palette.ink)
    }
}
