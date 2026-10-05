import SwiftUI

/// Segments have a fixed height and truncate at accessibility text sizes.
struct AccessiblePickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var textSize
    func body(content: Content) -> some View {
        if textSize.isAccessibilitySize { content.pickerStyle(.menu) }
        else { content.pickerStyle(.segmented) }
    }
}
