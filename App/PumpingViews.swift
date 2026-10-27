import SwiftUI
import FeedingCore

struct PumpingLogButton: View {
    @Environment(FeedingStore.self) private var store
    @State private var showEditor = false
    var body: some View {
        Button { showEditor = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "drop.halffull").font(.title2).foregroundStyle(Palette.green)
                    .frame(width: 58, height: 58).background(Palette.sage, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Log pumping").font(.headline)
                    Text("Record the time and combined ml").font(.subheadline).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Palette.green)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 26))
        }.buttonStyle(SoftPressStyle()).foregroundStyle(Palette.ink)
            .disabled(store.loadFailed).accessibilityIdentifier("log-pumping")
            .sheet(isPresented: $showEditor) { PumpingEditor() }
    }
}

struct PumpingSummaryCard: View {
    @Environment(FeedingStore.self) private var store
    let now: Date
    var body: some View {
        let today = PumpSummary(sessions: store.ledger.pumpSessions(on: now))
        let last24 = store.ledger.pumpedInLast24Hours(at: now)
        VStack(alignment: .leading, spacing: 10) {
            Label("Pumped today", systemImage: "drop.halffull").font(.headline).foregroundStyle(Palette.green)
            Text("\(today.totalML) ml")
                .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
            Text(L10n.format(today.sessionCount == 1 ? "%d session · Last 24 hours: %d ml" : "%d sessions · Last 24 hours: %d ml",
                             today.sessionCount, last24.totalML))
                .font(.subheadline).foregroundStyle(Palette.secondary)
            Text("Combined output from both sides. Not counted as milk drunk.")
                .font(.caption).foregroundStyle(Palette.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 26))
            .accessibilityElement(children: .combine).accessibilityIdentifier("pumping-summary")
    }
}

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
                }
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
    private var timeShortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set time").font(.subheadline).foregroundStyle(Palette.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach([0, 5, 15, 30, 60], id: \.self) { minutesAgo in
                    Button {
                        pumpedAt = Date.now.addingTimeInterval(-Double(minutesAgo) * 60)
                        validation = nil
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
