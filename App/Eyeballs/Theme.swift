import SwiftUI

enum Theme {
    static let background = Color(hex: 0x101211)
    static let card = Color(hex: 0x1B1E1B)
    static let border = Color.white.opacity(0.07)
    static let accent = Color(hex: 0xB9F577)
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    func panel() -> some View {
        padding(20).background(Theme.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.border, lineWidth: 1))
    }
}

struct EyeballsMark: View {
    var size: CGFloat = 40
    var body: some View {
        HStack(spacing: -size * 0.06) {
            ForEach(0..<2) { _ in
                ZStack {
                    Circle().stroke(Theme.accent, lineWidth: size * 0.06)
                    Circle().fill(Theme.accent).frame(width: size * 0.21, height: size * 0.21).offset(x: size * 0.065, y: -size * 0.035)
                }.frame(width: size * 0.5, height: size * 0.5)
            }
        }.frame(width: size, height: size)
    }
}
