import SwiftUI
import UIKit

struct ProviderLogo: View {
    let provider: Provider
    var color: Color
    var size: CGFloat = 22
    var body: some View {
        Image("Logo-" + provider.rawValue).renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

extension Color {
    var hexRGB: UInt32? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return UInt32((red * 255).rounded()) << 16 | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded())
    }
}
