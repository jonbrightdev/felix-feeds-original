import SwiftUI
import FeedingCore

struct HungerCueLogButton: View {
    @Environment(FeedingStore.self) private var store
    @State private var lastAdded: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                let cue = HungerCue()
                if store.change({ try $0.upsert(cue) }) {
                    lastAdded = cue.id
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } label: {
                HStack(spacing: 12) {
                    BabyIllustration(pose: .hungry, width: 58, animated: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Showing hunger signs").font(.headline)
                        Text("Log now without changing the feed timer").font(.caption).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "plus.circle")
                }.padding(18).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Palette.peach, in: RoundedRectangle(cornerRadius: 26))
            }.buttonStyle(SoftPressStyle()).foregroundStyle(Palette.ink)
                .disabled(store.loadFailed).accessibilityIdentifier("log-hunger-cue")
            if let latest = store.ledger.visibleHungerCues.first {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.format("Last hunger signs: %@", latest.recordedAt.formatted(date: .omitted, time: .shortened)))
                        .font(.caption).foregroundStyle(Palette.secondary)
                    Spacer()
                    if lastAdded == latest.id {
                        Button("Undo") {
                            if store.change({ $0.setHungerCueDeleted(latest.id, at: .now) }) { lastAdded = nil }
                        }.font(.caption.weight(.semibold)).frame(minHeight: 44)
                            .accessibilityIdentifier("undo-hunger-cue")
                    }
                }
            }
        }
    }
}

struct HungerCueRow: View {
    let cue: HungerCue
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.tap").foregroundStyle(Palette.green).frame(width: 40, height: 44)
                .background(Palette.peach, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("Hunger signs").font(.headline)
                Text("Observation").font(.caption).foregroundStyle(Palette.secondary)
                if !cue.notes.isEmpty { Text(cue.notes).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            Text(cue.recordedAt, format: .dateTime.hour().minute()).font(.subheadline).foregroundStyle(Palette.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 16).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct HistoryEntryRow: View {
    let entry: HistoryEntry
    var body: some View {
        switch entry {
        case .feed(let feed): FeedRow(feed: feed)
        case .hunger(let cue): HungerCueRow(cue: cue)
        case .pump(let session): PumpingRow(session: session)
        }
    }
}

struct HungerCueEditor: View {
    @Environment(FeedingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let cue: HungerCue
    @State private var recordedAt: Date
    @State private var notes: String
    @State private var validation: String?
    init(cue: HungerCue) {
        self.cue = cue; _recordedAt = State(initialValue: cue.recordedAt); _notes = State(initialValue: cue.notes)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Observed", selection: $recordedAt, in: ...Date.now)
                } footer: { Text("An observation only. Feeding timers and totals are unchanged.") }
                Section("Notes") {
                    TextField("What did you notice?", text: $notes, axis: .vertical).lineLimit(3...7)
                }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                Section {
                    Button("Delete observation", role: .destructive) {
                        if store.change({ $0.setHungerCueDeleted(cue.id, at: .now) }) { dismiss() }
                    }
                } footer: { Text("Deleted observations can be restored in Settings.") }
            }
            .felixFormStyle()
            .navigationTitle("Hunger signs").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = cue; updated.recordedAt = recordedAt; updated.notes = notes
                        do {
                            try updated.validate()
                            if store.change({ try $0.upsert(updated) }) { dismiss() }
                        } catch { validation = error.localizedDescription }
                    }.bold()
                }
            }
            .interactiveDismissDisabled()
        }
    }
}
