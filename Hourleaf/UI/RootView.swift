import Combine
import CoreData
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
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
            model.reload()
            Task { await model.rescheduleReminders() }
        }
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .alert(String(localized: "error.title"), isPresented: errorBinding) {
            Button("common.ok") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
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
