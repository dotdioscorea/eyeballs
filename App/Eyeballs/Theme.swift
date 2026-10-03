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

struct RequotaMark: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().stroke(Theme.accent.opacity(0.18), lineWidth: size * 0.085)
            Circle().trim(from: 0, to: 0.84)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle().trim(from: 0, to: 0.60)
                .stroke(Color(hex: 0xAAA5FF), style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
                .rotationEffect(.degrees(90)).padding(size * 0.14)
            Path { path in
                path.move(to: CGPoint(x: size * 0.60, y: size * 0.60))
                path.addLine(to: CGPoint(x: size * 0.92, y: size * 0.92))
            }.stroke(Theme.accent, style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
        }.frame(width: size, height: size)
    }
}
