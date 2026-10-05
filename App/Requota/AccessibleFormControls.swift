import SwiftUI

struct AccessibleFormPicker<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let options: [(String, Selection)]
    @Environment(\.dynamicTypeSize) private var textSize
    init(_ title: String, selection: Binding<Selection>, options: [(String, Selection)]) {
        self.title = title; _selection = selection; self.options = options
    }
    var body: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                ForEach(options.indices, id: \.self) { index in
                    let choice = options[index]
                    Button { selection = choice.1 } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(choice.0).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: selection == choice.1 ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == choice.1 ? Theme.accent : .secondary).imageScale(.small)
                        }.foregroundStyle(.primary).padding(.vertical, 6).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(choice.0).accessibilityValue(selection == choice.1 ? "Selected" : "Not selected")
                        .accessibilityAddTraits(selection == choice.1 ? .isSelected : [])
                }
            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        } else { Picker(title, selection: $selection) { ForEach(options.indices, id: \.self) { index in Text(options[index].0).tag(options[index].1) } } }
    }
}

struct AccessibleStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    @Environment(\.dynamicTypeSize) private var textSize
    init(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1) {
        self.title = title; _value = value; self.range = range; self.step = step
    }
    var body: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Stepper(title, value: $value, in: range, step: step).labelsHidden().accessibilityLabel(title)
            }
        } else { Stepper(title, value: $value, in: range, step: step) }
    }
}

struct AccessibleToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.dynamicTypeSize) private var textSize
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Toggle(title, isOn: $isOn).labelsHidden().accessibilityLabel(title)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else { Toggle(title, isOn: $isOn) }
    }
}

struct AccessibleLabeledContent: View {
    let title: String
    let value: String
    @Environment(\.dynamicTypeSize) private var textSize
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(value).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
        } else { LabeledContent(title, value: value) }
    }
}
