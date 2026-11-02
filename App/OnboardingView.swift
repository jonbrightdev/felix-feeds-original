import SwiftUI
import FeedingCore

struct AppEntryView: View {
    @Environment(FeedingStore.self) private var store
    @AppStorage("onboardingCompleted") private var completed = false
    @AppStorage("babyName") private var babyName = ""
    @State private var needsOnboarding: Bool?

    var body: some View {
        Group {
            if completed || needsOnboarding == false {
                RootView()
            } else if needsOnboarding == true {
                OnboardingView { completed = true }
            } else {
                SplashView()
            }
        }
        .task {
            let ledger = store.ledger
            let existingHistory = !ledger.feeds.isEmpty || !ledger.pumpSessions.isEmpty
                || !ledger.hungerCues.isEmpty || ledger.active != nil || ledger.sharedHistoryID != nil
            if existingHistory {
                if !completed && babyName.isEmpty { babyName = "Felix" }
                completed = true
            }
            needsOnboarding = !completed && !store.loadFailed
        }
    }
}

struct SplashView: View {
    var body: some View {
        VStack(spacing: 24) {
            BabyIllustration(width: 196, animated: false)
            Text("Felix Feeds").font(.system(.largeTitle, design: .rounded, weight: .bold))
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}

struct OnboardingView: View {
    private enum Step { case welcome, name, session, saved }
    private enum Capture: String, Identifiable {
        case bottle, breast, pump
        var id: String { rawValue }
    }

    @Environment(FeedingStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("babyName") private var babyName = ""
    @State private var step = Step.welcome
    @State private var draftName = ""
    @State private var capture: Capture?
    @State private var saved: HistoryEntry?
    @State private var timerStarted = false
    @FocusState private var nameFocused: Bool
    let complete: () -> Void

    private var displayName: String { babyName.isEmpty ? L10n.text("your baby") : babyName }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: step == .welcome || step == .saved ? .center : .leading, spacing: 24) {
                    content
                }
                .frame(maxWidth: 480)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            actions
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .fontDesign(.rounded)
        .foregroundStyle(Palette.ink)
        .background(Palette.background)
        .sheet(item: $capture, onDismiss: captureDismissed) { choice in
            FeedEditor(defaultKind: choice == .breast ? .breast : .formula,
                       startWithPumping: choice == .pump,
                       onSaved: { saved = $0 }, onTimerStarted: { timerStarted = true })
        }
        .onAppear { draftName = babyName }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            BabyIllustration(width: typeSize.isAccessibilitySize ? 100 : 168)
                .padding(.top, 60)
            heading("Welcome to\nFelix Feeds")
                .multilineTextAlignment(.center)
            explanation("Keep track of bottles, breastfeeding and pumping, one session at a time.")
                .multilineTextAlignment(.center)
        case .name:
            BabyIllustration(width: 112, animated: false)
                .frame(maxWidth: .infinity)
            heading("What’s your\nbaby’s name?")
            explanation("A first name or nickname is perfect. You can change it in Settings.")
            VStack(alignment: .leading, spacing: 8) {
                Text("Baby’s name (optional)").font(.subheadline.weight(.semibold))
                TextField("First name or nickname", text: $draftName)
                    .textContentType(.nickname)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.continue)
                    .focused($nameFocused)
                    .onSubmit(saveName)
                    .padding(16)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.secondary.opacity(0.25)))
                    .accessibilityLabel("Baby’s name (optional)")
                    .accessibilityIdentifier("onboarding-baby-name")
            }
        case .session:
            heading(L10n.format("A first session\nfor %@", displayName))
            explanation("Choose what you’d like to record. You can add an earlier session, too.")
            VStack(spacing: 12) {
                sessionChoice(.bottle, title: "Bottle", detail: "Formula or expressed milk", icon: "waterbottle")
                sessionChoice(.breast, title: "Breastfeeding", detail: "Start a timer or add a feed", icon: "heart")
                sessionChoice(.pump, title: "Pumping", detail: "Record milk expressed", icon: "drop.halffull")
            }
        case .saved:
            BabyIllustration(width: 140, animated: false).padding(.top, 32)
            heading(savedIsPump ? "First pumping session saved" : "First feed saved")
                .multilineTextAlignment(.center)
            explanation(L10n.format("%@’s history has begun. You can edit this session at any time.", displayName))
                .multilineTextAlignment(.center)
            if let saved {
                VStack(alignment: .leading, spacing: 8) {
                    switch saved {
                    case .feed(let feed):
                        Text(feed.title).font(.title3.bold())
                        if let ml = feed.millilitres {
                            Text(L10n.format("%d ml", ml)).font(.headline)
                        } else {
                            Text(TimeText.duration(feed.duration)).font(.headline)
                        }
                    case .pump(let session):
                        Text("Pumping").font(.title3.bold())
                        Text(L10n.format("%d ml pumped", session.millilitres)).font(.headline)
                    }
                    Text(saved.date, format: .dateTime.day().month().hour().minute())
                        .foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 8) {
            switch step {
            case .welcome:
                primary("Get started") { step = .name }
                secondary("Explore first", action: complete)
            case .name:
                primary("Continue", action: saveName)
                secondary("Skip for now") { nameFocused = false; step = .session }
                secondary("Back") { nameFocused = false; step = .welcome }
            case .session:
                secondary("I’ll start later", action: complete)
                secondary("Back") { step = .name }
            case .saved:
                primary(L10n.format("Go to %@’s overview", displayName), action: complete)
            }
        }
    }

    private var savedIsPump: Bool {
        if case .pump = saved { return true }
        return false
    }

    private func heading(_ text: String) -> some View {
        Text(L10n.text(text)).font(.system(.largeTitle, design: .rounded, weight: .bold))
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }

    private func explanation(_ text: String) -> some View {
        Text(L10n.text(text)).font(.body).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.text(title)).font(.headline).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 54).padding(.horizontal, 12)
                .padding(.vertical, 4).foregroundStyle(.white)
                .background(Palette.button, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(SoftPressStyle())
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.text(title)).frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
    }

    private func sessionChoice(_ choice: Capture, title: String, detail: String, icon: String) -> some View {
        Button { capture = choice } label: {
            HStack(spacing: 14) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: icon).font(.title2).frame(width: 40).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(title)).font(.title3.bold())
                    Text(L10n.text(detail)).font(.subheadline).foregroundStyle(Palette.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 80)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityIdentifier("onboarding-\(choice.rawValue)")
    }

    private func saveName() {
        babyName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        nameFocused = false
        step = .session
    }

    private func captureDismissed() {
        if timerStarted { complete() }
        else if saved != nil { step = .saved }
    }
}

struct BabyNameSettingsView: View {
    @AppStorage("babyName") private var babyName = ""
    @State private var draftName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("First name or nickname", text: $draftName)
                    .textContentType(.nickname).textInputAutocapitalization(.words)
                    .accessibilityLabel("Baby’s name (optional)")
            } header: { Text("Baby’s name (optional)") }
        }
        .felixFormStyle()
        .navigationTitle("Baby’s name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    babyName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    dismiss()
                }
            }
        }
        .onAppear { draftName = babyName }
    }
}
