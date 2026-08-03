import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DataManagementView: View {
    let actions: DataManagementActions

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var backupStatus: BackupConfidenceStatusModel

    @State private var busyOperation: BusyOperation?
    @State private var restoreState = DataManagementRestoreState()
    @State private var includeNotes = false
    @State private var sharePayload: FileSharePayload?
    @State private var isRestoreImporterPresented = false
    @State private var errorMessage: String?

    init(actions: DataManagementActions) {
        self.actions = actions
        _backupStatus = ObservedObject(wrappedValue: actions.backupStatus)
    }

    var body: some View {
        Form {
            backupSection
            restoreSection
            csvSection
        }
        .navigationTitle("data_management.title")
        .fileImporter(
            isPresented: $isRestoreImporterPresented,
            allowedContentTypes: [.hourleafBackup],
            allowsMultipleSelection: false,
            onCompletion: handleRestoreImport
        )
        .sheet(item: $sharePayload) { payload in
            FileActivityView(payload: payload) { _ in
                sharePayload = nil
            }
        }
        .alert(String(localized: "error.title"), isPresented: errorPresented) {
            Button(String(localized: "common.ok")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            restoreState.appear()
            backupStatus.requestRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            backupStatus.requestRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            backupStatus.requestRefresh()
        }
        .onDisappear(perform: discardRestorePreviewOnDisappear)
    }

    private var backupSection: some View {
        Section("data_management.backup") {
            VStack(alignment: .leading, spacing: 6) {
                Text("backup_status.title")
                    .font(.subheadline.weight(.semibold))
                if let state = backupStatus.state {
                    Text(state.localizedStatusText)
                        .accessibilityIdentifier("backupConfidenceStatus")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("backup_status.limitation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                startBackup()
            } label: {
                Label("data_management.backup.create", systemImage: "externaldrive.badge.plus")
            }
            .accessibilityIdentifier("createBackupButton")
            .disabled(isBusy)

            Text("data_management.backup.move")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("data_management.backup.readable")
                .font(.caption)
                .foregroundStyle(.secondary)
            if busyOperation == .backup {
                progressRow(for: .backup)
            }
        }
    }

    private var restoreSection: some View {
        Section("data_management.restore") {
            Button {
                isRestoreImporterPresented = true
            } label: {
                Label("data_management.restore.choose", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("chooseRestoreBackupButton")
            .disabled(isBusy || !isRestoreAvailable)

            if let restorePreview = restoreState.preview {
                Text(restorePreview.summary)
                    .accessibilityIdentifier("restorePreview")
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("data_management.restore.confirmation", isOn: $restoreState.isConfirmed)
                    .accessibilityIdentifier("restoreConfirmationToggle")
                    .disabled(isBusy || !isRestoreAvailable)

                Button("data_management.restore.confirm") {
                    startRestore(using: restorePreview)
                }
                .accessibilityIdentifier("confirmRestoreButton")
                .disabled(!restoreState.isConfirmed || isBusy || !isRestoreAvailable)
            } else {
                Text("data_management.restore.no_preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("data_management.restore.replace")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isRestoreAvailable {
                Text("data_management.restore.unavailable_cloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if busyOperation == .restorePreview {
                progressRow(for: .restorePreview)
            } else if busyOperation == .restore {
                progressRow(for: .restore)
            }
        }
    }

    private var csvSection: some View {
        Section("data_management.csv") {
            Toggle("data_management.csv.include_notes", isOn: $includeNotes)
                .accessibilityIdentifier("csvIncludeNotesToggle")
                .disabled(isBusy)

            Button {
                startCSVExport()
            } label: {
                Label("data_management.csv.export", systemImage: "tablecells")
            }
            .accessibilityIdentifier("exportCSVButton")
            .disabled(isBusy)

            Text("data_management.csv.details")
                .font(.caption)
                .foregroundStyle(.secondary)
            if includeNotes {
                Text("data_management.csv.notes_privacy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if busyOperation == .csv {
                progressRow(for: .csv)
            }
        }
    }

    private func progressRow(for operation: BusyOperation) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(operation.progressTitle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dataManagementProgress")
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private var isBusy: Bool { busyOperation != nil }
    private var isRestoreAvailable: Bool { actions.restoreAvailability.isAvailable }

    private func startBackup() {
        start(.backup) {
            sharePayload = try await actions.createBackup()
        }
    }

    private func startCSVExport() {
        let includesNotes = includeNotes
        start(.csv) {
            sharePayload = try await actions.exportCSV(includesNotes)
        }
    }

    private func handleRestoreImport(_ result: Result<[URL], Error>) {
        guard busyOperation == nil, isRestoreAvailable else { return }

        switch result {
        case let .success(urls):
            guard let url = urls.first else {
                showSanitizedError(for: .restorePreview)
                return
            }
            busyOperation = .restorePreview
            Task { @MainActor in
                await discardCurrentRestorePreview()
                do {
                    let preview = try await actions.previewRestore(url)
                    if restoreState.isVisible {
                        if let previous = restoreState.replacePreview(with: preview) {
                            await actions.discardRestorePreview(previous)
                        }
                    } else {
                        await actions.discardRestorePreview(preview)
                    }
                } catch {
                    showSanitizedError(for: .restorePreview)
                }
                busyOperation = nil
            }
        case let .failure(error):
            guard (error as NSError).code != CocoaError.Code.userCancelled.rawValue else { return }
            showSanitizedError(for: .restorePreview)
        }
    }

    private func startRestore(using preview: DataManagementRestorePreview) {
        guard
            busyOperation == nil,
            isRestoreAvailable,
            restoreState.preview == preview
        else { return }

        busyOperation = .restore
        Task { @MainActor in
            do {
                try await actions.restore(preview)
                if let candidate = restoreState.finishRestore(succeeded: true) {
                    await actions.discardRestorePreview(candidate)
                }
            } catch {
                let shouldShowError = restoreState.isVisible
                if let candidate = restoreState.finishRestore(succeeded: false) {
                    await actions.discardRestorePreview(candidate)
                }
                if shouldShowError {
                    showSanitizedError(for: .restore)
                }
            }
            busyOperation = nil
        }
    }

    private func start(_ operation: BusyOperation, work: @escaping () async throws -> Void) {
        guard busyOperation == nil else { return }
        busyOperation = operation
        Task { @MainActor in
            do {
                try await work()
            } catch {
                showSanitizedError(for: operation)
            }
            busyOperation = nil
        }
    }

    private func discardCurrentRestorePreview() async {
        guard let preview = restoreState.takePreviewForDiscard() else { return }
        await actions.discardRestorePreview(preview)
    }

    private func discardRestorePreviewOnDisappear() {
        let preview = restoreState.disappear(restoreInFlight: busyOperation == .restore)
        guard let preview else { return }
        Task { @MainActor in
            await actions.discardRestorePreview(preview)
        }
    }

    private func showSanitizedError(for operation: BusyOperation) {
        switch operation {
        case .backup:
            errorMessage = String(localized: "data_management.error.backup")
        case .restorePreview:
            errorMessage = String(localized: "data_management.error.restore_preview")
        case .restore:
            errorMessage = String(localized: "data_management.error.restore")
        case .csv:
            errorMessage = String(localized: "data_management.error.csv")
        }
    }
}

private enum BusyOperation: Equatable {
    case backup
    case restorePreview
    case restore
    case csv

    var progressTitle: LocalizedStringKey {
        switch self {
        case .backup: "data_management.progress.backup"
        case .restorePreview: "data_management.progress.restore_preview"
        case .restore: "data_management.progress.restore"
        case .csv: "data_management.progress.csv"
        }
    }
}

private extension UTType {
    static var hourleafBackup: UTType {
        UTType(filenameExtension: "hourleafbackup") ?? .data
    }
}
