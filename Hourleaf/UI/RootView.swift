import Combine
import CoreData
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var observedLedgerChangeGeneration: UInt64 = 0

    var body: some View {
        Group {
            switch model.startupState {
            case .loading:
                ProgressView("startup.loading")
                    .controlSize(.large)
                    .accessibilityIdentifier("initialLoadIndicator")
            case .failed:
                ContentUnavailableView {
                    Label("startup.failed.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("startup.failed.message")
                }
                .accessibilityIdentifier("initialLoadFailure")
            case .ready:
                readyContent
            }
        }
        .alert(String(localized: "error.title"), isPresented: errorBinding) {
            Button("common.ok") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if ProcessInfo.processInfo.arguments.contains("-quickEntryRouteOnForegroundUITest") {
                router.route(to: .quickEntry)
            }
            Task { await model.refreshAfterForegrounding() }
        }
        .onAppear {
            consumePendingRoute()
            consumeLedgerChange()
        }
        .onChange(of: router.pendingRoute) { _, _ in
            consumePendingRoute()
        }
        .onChange(of: router.ledgerChangeGeneration) { _, _ in
            consumeLedgerChange()
        }
        .onChange(of: model.startupState) { _, state in
            guard state == .ready else { return }
            consumeLedgerChange()
        }
    }

    private var readyContent: some View {
        GeometryReader { geometry in
            tabs
                .overlay(alignment: .bottom) {
                    if let candidate = model.visibleUndoCandidate {
                        MutationBannerView(
                            candidate: candidate,
                            undo: { Task { await model.undoLatestMutation() } },
                            dismiss: model.dismissUndoBanner
                        )
                        .padding(.horizontal)
                        .padding(.bottom, tabBarClearance(in: geometry))
                    }
                }
        }
    }

    private func tabBarClearance(in geometry: GeometryProxy) -> CGFloat {
        // A bottom TabView reserves its standard 49 pt bar above the device's safe area.
        geometry.safeAreaInsets.bottom + 57
    }

    private var tabs: some View {
        TabView(selection: $model.selectedTab) {
            QuickEntryView()
                .tabItem { Label("tab.add", systemImage: "plus.circle.fill") }
                .tag(AppModel.Tab.add)
            HistoryScreen()
                .tabItem { Label("tab.history", systemImage: "clock.arrow.circlepath") }
                .tag(AppModel.Tab.history)
            ProgressScreen()
                .tabItem { Label("tab.progress", systemImage: "chart.bar.fill") }
                .tag(AppModel.Tab.progress)
            SettingsScreen()
                .tabItem { Label("tab.settings", systemImage: "gearshape.fill") }
                .tag(AppModel.Tab.settings)
        }
        .accessibilityIdentifier("appReady")
        .tint(Color(red: 0.16, green: 0.46, blue: 0.27))
        .onReceive(
            NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            Task {
                await model.reload()
                await model.rescheduleReminders()
            }
        }
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !model.settings.onboardingComplete },
            set: { _ in }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private func consumePendingRoute() {
        guard let route = router.consumePendingRoute() else { return }
        switch route {
        case .quickEntry:
            model.prepareQuickEntry()
        }
    }

    private func consumeLedgerChange() {
        guard model.startupState == .ready else { return }
        let generation = router.ledgerChangeGeneration
        guard generation != observedLedgerChangeGeneration else { return }
        observedLedgerChangeGeneration = generation
        Task { await model.refreshAfterExternalLedgerChange() }
    }
}
