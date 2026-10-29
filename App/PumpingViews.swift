import SwiftUI
import FeedingCore

struct PumpingRow: View {
    let session: PumpSession
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "drop.halffull").foregroundStyle(Palette.green).frame(width: 40, height: 44)
                .background(Palette.blue, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("Pumping").font(.headline)
                Text(L10n.format("%d ml combined", session.millilitres)).font(.subheadline).foregroundStyle(Palette.secondary)
                if !session.notes.isEmpty { Text(session.notes).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            Text(session.pumpedAt, format: .dateTime.hour().minute()).font(.subheadline).foregroundStyle(Palette.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 16).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct PumpingEditor: View {
    @Environment(FeedingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: PumpSession?
    @State private var pumpedAt: Date
    @State private var amount: String
    @State private var notes: String
    @State private var validation: String?
    init(session: PumpSession? = nil) {
        self.session = session
        _pumpedAt = State(initialValue: session?.pumpedAt ?? .now)
        _amount = State(initialValue: session.map { String($0.millilitres) } ?? "")
        _notes = State(initialValue: session?.notes ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                PumpingFields(pumpedAt: $pumpedAt, amount: $amount, notes: $notes) { validation = nil }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let session {
                    Section {
                        Button("Delete pumping session", role: .destructive) {
                            if store.change({ $0.setPumpSessionDeleted(session.id, at: .now) }) { dismiss() }
                        }
                    } footer: { Text("Deleted pumping sessions can be restored in Settings.") }
                }
            }
            .felixFormStyle()
            .navigationTitle(L10n.text(session == nil ? "Log pumping" : "Edit pumping"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).bold().accessibilityIdentifier("save-pumping") }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .interactiveDismissDisabled()
        }
    }
    private func save() {
        do {
            guard let millilitres = Int(amount.trimmingCharacters(in: .whitespaces)) else {
                throw FeedingError.invalid("Enter a combined pumped amount between 0 and 2,000 ml.")
            }
            var entry = session ?? PumpSession(millilitres: millilitres)
            entry.pumpedAt = pumpedAt; entry.millilitres = millilitres; entry.notes = notes
            try entry.validate()
            if store.change({ try $0.upsert(entry) }) { dismiss() }
        } catch { validation = error.localizedDescription }
    }
}

struct PumpingFields: View {
    @Binding var pumpedAt: Date
    @Binding var amount: String
    @Binding var notes: String
    var onTimeSelected: () -> Void = {}

    var body: some View {
        Section("Pumping") {
            timeShortcuts
            DatePicker("Pumped at", selection: $pumpedAt, in: ...Date.now)
                .accessibilityIdentifier("pumped-at")
        }
        Section {
            HStack {
                Text("Combined output (ml)")
                Spacer()
                TextField(L10n.text("e.g. 120"), text: $amount).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .frame(minWidth: 65, maxWidth: 120).accessibilityLabel(L10n.text("Combined output (ml)"))
                    .accessibilityIdentifier("pumped-amount")
            }
        } header: { Text("Output") } footer: {
            Text("Add both sides together. Pumped milk is not counted as milk drunk; log a bottle when Felix drinks it.")
        }
        Section("Notes") {
            TextField("Anything to remember?", text: $notes, axis: .vertical).lineLimit(3...7)
                .accessibilityIdentifier("pumping-notes")
        }
    }
    private var timeShortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set time").font(.subheadline).foregroundStyle(Palette.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach([0, 5, 15, 30, 60], id: \.self) { minutesAgo in
                    Button {
                        pumpedAt = Date.now.addingTimeInterval(-Double(minutesAgo) * 60)
                        onTimeSelected()
                    } label: {
                        Text(minutesAgo == 0 ? L10n.text("Now") :
                            minutesAgo == 60 ? L10n.text("1 hour ago") : L10n.format("%d min ago", minutesAgo))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Palette.sage, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(minutesAgo == 0 ? L10n.text("Set pumping time to now") :
                        L10n.format("Set pumping time to %d minutes ago", minutesAgo))
                    .accessibilityIdentifier("pumping-time-\(minutesAgo)")
                }
            }
        }.padding(.vertical, 4)
    }
}
