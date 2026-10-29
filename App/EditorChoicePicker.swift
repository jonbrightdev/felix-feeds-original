import SwiftUI
import FeedingCore

/// Keep short choices visible, with a native menu when larger text needs more room.
struct EditorChoicePicker<Value: Hashable>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Group {
            if typeSize > .large {
                picker.pickerStyle(.menu).labelsHidden()
            } else {
                picker.pickerStyle(.segmented)
            }
        }.frame(minHeight: 44)
    }

    private var picker: some View {
        Picker(L10n.text(title), selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(L10n.text(options[index].1)).tag(options[index].0)
            }
        }
    }
}
