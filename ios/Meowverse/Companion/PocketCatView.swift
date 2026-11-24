@preconcurrency import ActivityKit
import SwiftUI

struct PocketCatView: View {
    /// The cat keeping you company, shown on the Lock Screen and the watch. A parameter, not
    /// the environment's `AppModel`: `PocketCatReturn` presents this page in a hosting
    /// controller of its own, outside the app's SwiftUI environment.
    let catName: String
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @State private var available = TourDevice.liveActivitiesOn
    @State private var activity: PocketCatActivity?
    @State private var session: PocketCatState?
    @State private var mood = PocketCatMood.sleeping
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    PocketCatPortrait(mood: mood, size: 48)
                        .padding(9)
                        .background(Color(red: 0.16, green: 0.23, blue: 0.19), in: .rect(cornerRadius: 11))
                        .padding(4)
                        .background(RoomPaper.paper, in: .rect(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(RoomPaper.edge) }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(mood.title).font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(RoomPaper.ink)
                            .accessibilityIdentifier("pocket-expression")
                        if activity != nil {
                            Text("Keeping you company", tableName: "PocketCat")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("pocket-active")
                        }
                    }
                }
                // Chapter 12 of the tour waits for this page by it (12.2), and may begin here.
                .tourAnchor("pocket-page", padding: 4)
                Picker(selection: Binding(get: { mood }, set: selectMood)) {
                    ForEach(PocketCatMood.allCases, id: \.self) { item in Text(item.title).tag(item) }
                } label: {
                    Text("Expression", tableName: "PocketCat")
                }
                .accessibilityIdentifier("pocket-select")
            } footer: {
                Text("Your pixel cat appears on the Lock Screen and, on supported iPhones, in the Dynamic Island. It changes to a random expression every five minutes.", tableName: "PocketCat")
            }
            .listRowBackground(RoomPaper.sheet)
            Section {
                if let activity {
                    Button(role: .destructive) {
                        busy = true
                        Task {
                            await activity.end(nil, dismissalPolicy: .immediate)
                            PocketCatCompanyMirror.ended(activity.id)
                            refresh()
                            busy = false
                        }
                    } label: { Text(PocketCatCopy.end) }
                    .accessibilityIdentifier("pocket-end")
                    .tourAnchor("pocket-end", padding: 0)
                } else if available {
                    Button(action: start) { Text("Start company", tableName: "PocketCat") }
                        .accessibilityIdentifier("pocket-start")
                        .tourAnchor("pocket-start", padding: 0)
                } else {
                    Text("To invite your pixel cat, allow Live Activities in the app’s settings.", tableName: "PocketCat")
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: { Text("Open Settings", tableName: "PocketCat") }
                }
                if failed {
                    Text("Couldn’t start this Live Activity. Try again, or check Live Activities in Settings.", tableName: "PocketCat")
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(RoomPaper.sheet)
        }
        .disabled(busy)
        .memoryPage(.companion)
        .navigationTitle(Text(PocketCatCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refresh()
            TourCompanyPageSeen.appeared()
        }
        .onDisappear { TourCompanyPageSeen.disappeared() }
        .onChange(of: phase) { _, phase in if phase == .active { refresh() } }
        .task(id: activity?.id) {
            guard let activity else { return }
            for await content in activity.contentUpdates {
                guard !Task.isCancelled, self.activity?.id == activity.id else { break }
                display(content.state)
            }
        }
        .task(id: phase == .active ? session : nil) {
            guard phase == .active, let session else { return }
            while let deadline = session.nextChange(after: .now) {
                do {
                    try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                } catch { return }
                guard !Task.isCancelled, self.session == session else { return }
                mood = session.mood(at: .now)
            }
        }
        .task(id: activity?.id) {
            guard let activity else { return }
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, self.activity?.id == activity.id else { break }
                if state == .ended || state == .dismissed { refresh(); break }
            }
        }
    }

    private func display(_ state: PocketCatState) {
        session = state
        mood = state.mood(at: .now)
    }

    private func refresh() {
        available = TourDevice.liveActivitiesOn
        activity = PocketCatActivity.activities.first(where: \.isOngoing)
        if let activity { display(activity.content.state) }
        else { session = nil }
    }

    private func start() {
        refresh()
        guard available, activity == nil else { return }
        do {
            let state = PocketCatState(startingWith: mood, at: .now, interval: LaunchOptions.current.pocketCatInterval)
            activity = try PocketCatActivity.request(attributes: PocketCatAttributes(catName: catName),
                                                     content: .init(state: state, staleDate: nil))
            if let activity { PocketCatCompanyMirror.kept(activity.id, state) }
            display(state)
            failed = false
        } catch {
            failed = true
            refresh()
        }
    }

    private func selectMood(_ selection: PocketCatMood) {
        mood = selection
        guard let activity else { return }
        busy = true
        Task {
            await activity.show(selection)
            refresh()
            busy = false
        }
    }
}
