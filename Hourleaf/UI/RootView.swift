import Combine
import CoreData
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

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
    }

    private var readyContent: some View {
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
            NotificationCenter.default.publisher(for: .openQuickEntry)
                .receive(on: DispatchQueue.main)
        ) { _ in
            model.selectedTab = .add
        }
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
}
