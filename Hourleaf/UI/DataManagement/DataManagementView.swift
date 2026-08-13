import SwiftUI
import UniformTypeIdentifiers

/// View-owned lifecycle for one staged CSV import. It deliberately keeps the
/// coordinator candidate separate from the durable result and short-lived Undo
/// token so replacing or dismissing a preview cannot reuse old raw rows.
struct DataManagementCSVImportState: Equatable {
    private(set) var preview: DataManagementCSVImportPreview?
    private(set) var result: CSVImportResult?
    private(set) var undoResult: CSVImportUndoResult?
    private(set) var undoToken: CSVImportUndoToken?
    var skipPossibleMatches = true
    private(set) var isVisible = true

    mutating func appear() {
        isVisible = true
    }

    @discardableResult
    mutating func beginNewChoice() -> DataManagementCSVImportPreview? {
        let previous = preview
        preview = nil
        result = nil
        undoResult = nil
        undoToken = nil
        skipPossibleMatches = true
        return previous
    }

    @discardableResult
    mutating func replacePreview(with preview: DataManagementCSVImportPreview) -> DataManagementCSVImportPreview? {
        let previous = beginNewChoice()
        self.preview = preview
        return previous
    }

    mutating func disappear(importInFlight: Bool) -> DataManagementCSVImportPreview? {
        isVisible = false
        guard !importInFlight else { return nil }
        return takePreviewForDiscard()
    }

    /// A verified success consumes the staged candidate and stores only the
    /// aggregate result plus its process-memory Undo token.
    mutating func finishImport(with result: CSVImportResult) {
        preview = nil
        self.result = result
        undoResult = nil
        undoToken = result.undoToken
    }

    /// If confirmation failed after dismissal, the coordinator candidate must
    /// still be discarded. A visible failure keeps it for an explicit retry.
    mutating func finishImportFailure() -> DataManagementCSVImportPreview? {
        guard !isVisible else { return nil }
        return takePreviewForDiscard()
    }

    mutating func finishUndo(with result: CSVImportUndoResult) {
        undoResult = result
        undoToken = nil
    }

    mutating func takePreviewForDiscard() -> DataManagementCSVImportPreview? {
        defer { preview = nil }
        return preview
    }
}

@MainActor
struct DataManagementView: View {
    let actions: DataManagementActions

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var backupStatus: BackupConfidenceStatusModel

    @State private var busyOperation: BusyOperation?
    @State private var restoreState = DataManagementRestoreState()
    @State private var csvImportState = DataManagementCSVImportState()
    @State private var includeNotes = false
    @State private var sharePayload: FileSharePayload?
    @State private var fileImportKind: FileImportKind?
    @State private var isFileImporterPresented = false
    @State private var errorMessage: String?

    init(actions: DataManagementActions) {
        self.actions = actions
        _backupStatus = ObservedObject(wrappedValue: actions.backupStatus)
    }

    var body: some View {
        Form {
#if HOURLEAF_LOCAL_DEVICE
            localBuildMigrationGuidance
#endif
            backupSection
            restoreSection
            csvSection
            csvImportSection
        }
        .navigationTitle("data_management.title")
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: fileImportKind?.allowedContentTypes ?? [.data],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
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
            csvImportState.appear()
            backupStatus.requestRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            backupStatus.requestRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            backupStatus.requestRefresh()
        }
        .onDisappear {
            discardRestorePreviewOnDisappear()
            discardCSVImportPreviewOnDisappear()
        }
    }

#if HOURLEAF_LOCAL_DEVICE
    private var localBuildMigrationGuidance: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("data_management.local_migration.create")
                Text("data_management.local_migration.restore")
                Text("data_management.local_migration.keep")
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("localBuildMigrationGuidance")
        } header: {
            Text("data_management.local_migration.title")
        }
    }
#endif

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
                presentFileImporter(for: .restore)
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

            if busyOperation == .csvExport {
                progressRow(for: .csvExport)
            }
        }
    }

    private var csvImportSection: some View {
        Section("data_management.csv_import") {
            Text("data_management.csv_import.intro")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                presentFileImporter(for: .csv)
            } label: {
                Label("data_management.csv_import.choose", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("chooseCSVImportButton")
            .accessibilityLabel(Text("data_management.csv_import.choose"))
            .disabled(isBusy)

            if let preview = csvImportState.preview {
                csvImportPreviewView(preview)
            }

            if let result = csvImportState.result {
                csvImportResultView(result)
            }

            if busyOperation == .csvImportPreview {
                progressRow(for: .csvImportPreview)
            } else if busyOperation == .csvImport {
                progressRow(for: .csvImport)
            } else if busyOperation == .csvImportUndo {
                progressRow(for: .csvImportUndo)
            }
        }
    }

    @ViewBuilder
    private func csvImportPreviewView(_ preview: DataManagementCSVImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: String(localized: "data_management.csv_import.preview_rows"), Int64(preview.totalRows)))
                .accessibilityIdentifier("csvImportPreviewRows")
                .accessibilityLabel(Text(String(format: String(localized: "data_management.csv_import.preview_rows"), Int64(preview.totalRows))))
            if let dateRange = preview.dateRange {
                Text(String(format: String(localized: "data_management.csv_import.preview_dates"), dateRangeStart(dateRange), dateRangeEnd(dateRange)))
                    .accessibilityIdentifier("csvImportPreviewDateRange")
            }
            Text(String(format: String(localized: "data_management.csv_import.preview_notes"), Int64(preview.noteCount)))
                .accessibilityIdentifier("csvImportPreviewNotes")
            Text(String(format: String(localized: "data_management.csv_import.preview_previously_imported"), Int64(preview.previouslyImportedCount)))
                .accessibilityIdentifier("csvImportPreviewPreviouslyImported")
            Text(String(format: String(localized: "data_management.csv_import.preview_possible_matches"), Int64(preview.possibleMatchCount)))
                .accessibilityIdentifier("csvImportPreviewPossibleMatches")

            if preview.possibleMatchCount > 0 {
                Toggle(
                    "data_management.csv_import.skip_possible_matches",
                    isOn: $csvImportState.skipPossibleMatches
                )
                .accessibilityIdentifier("csvImportSkipPossibleMatchesToggle")
                .accessibilityLabel(Text("data_management.csv_import.skip_possible_matches"))
                .disabled(isBusy)

                if csvImportState.skipPossibleMatches {
                    Text("data_management.csv_import.skip_possible_matches_detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("data_management.csv_import.skip_possible_matches_detail_off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                startCSVImport(using: preview)
            } label: {
                Text(String(format: String(localized: "data_management.csv_import.confirm"), Int64(csvImportCount(for: preview))))
            }
            .accessibilityIdentifier("confirmCSVImportButton")
            .accessibilityLabel(Text(String(format: String(localized: "data_management.csv_import.confirm"), Int64(csvImportCount(for: preview)))))
            .disabled(isBusy)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func csvImportResultView(_ result: CSVImportResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(
                format: String(localized: "data_management.csv_import.result"),
                Int64(result.importedCount),
                Int64(result.previouslyImportedCount),
                Int64(result.skippedPossibleMatchCount)
            ))
            .accessibilityIdentifier("csvImportResult")

            if let undoResult = csvImportState.undoResult {
                Text(String(
                    format: String(localized: "data_management.csv_import.undo_result"),
                    Int64(undoResult.deletedCount)
                ))
                .accessibilityIdentifier("csvImportUndoResult")
            } else if csvImportState.undoToken != nil {
                Button("data_management.csv_import.undo") {
                    startCSVImportUndo()
                }
                .accessibilityIdentifier("undoCSVImportButton")
                .accessibilityLabel(Text("data_management.csv_import.undo"))
                .disabled(isBusy)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
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
        start(.csvExport) {
            sharePayload = try await actions.exportCSV(includesNotes)
        }
    }

    private func presentFileImporter(for kind: FileImportKind) {
        guard !isBusy else { return }
        fileImportKind = kind
        isFileImporterPresented = true
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard let kind = fileImportKind else { return }
        fileImportKind = nil
        switch kind {
        case .restore:
            handleRestoreImport(result)
        case .csv:
            handleCSVImport(result)
        }
    }

    private func handleCSVImport(_ result: Result<[URL], Error>) {
        guard busyOperation == nil else { return }

        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            busyOperation = .csvImportPreview
            Task { @MainActor in
                await discardCurrentCSVImportPreviewForNewChoice()
                do {
                    let preview = try await actions.previewCSVImport(url)
                    if csvImportState.isVisible {
                        _ = csvImportState.replacePreview(with: preview)
                    } else {
                        await actions.discardCSVImportPreview(preview)
                    }
                } catch {
                    showSanitizedError(for: .csvImportPreview)
                }
                busyOperation = nil
            }
        case let .failure(error):
            guard !isCancellation(error) else { return }
            showSanitizedError(for: .csvImportPreview)
        }
    }

    private func startCSVImport(using preview: DataManagementCSVImportPreview) {
        guard busyOperation == nil, csvImportState.preview == preview else { return }

        busyOperation = .csvImport
        let policy: CSVImportDuplicatePolicy = csvImportState.skipPossibleMatches
            ? .skipPossibleMatches
            : .includePossibleMatches
        Task { @MainActor in
            do {
                let result = try await actions.confirmCSVImport(preview, policy)
                csvImportState.finishImport(with: result)
            } catch {
                if let candidate = csvImportState.finishImportFailure() {
                    await actions.discardCSVImportPreview(candidate)
                }
                showSanitizedError(for: .csvImport)
            }
            busyOperation = nil
        }
    }

    private func startCSVImportUndo() {
        guard busyOperation == nil, let token = csvImportState.undoToken else { return }

        busyOperation = .csvImportUndo
        Task { @MainActor in
            do {
                let result = try await actions.undoCSVImport(token)
                csvImportState.finishUndo(with: result)
            } catch {
                showSanitizedError(for: .csvImportUndo)
            }
            busyOperation = nil
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
                    showRestoreInterlockErrorIfSafe(error, fallback: .restorePreview)
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
                    showRestoreInterlockErrorIfSafe(error, fallback: .restore)
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

    private func discardCurrentCSVImportPreviewForNewChoice() async {
        guard let preview = csvImportState.beginNewChoice() else { return }
        await actions.discardCSVImportPreview(preview)
    }

    private func discardRestorePreviewOnDisappear() {
        let preview = restoreState.disappear(restoreInFlight: busyOperation == .restore)
        guard let preview else { return }
        Task { @MainActor in
            await actions.discardRestorePreview(preview)
        }
    }

    private func discardCSVImportPreviewOnDisappear() {
        let preview = csvImportState.disappear(importInFlight: busyOperation == .csvImport)
        guard let preview else { return }
        Task { @MainActor in
            await actions.discardCSVImportPreview(preview)
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
        case .csvExport:
            errorMessage = String(localized: "data_management.error.csv")
        case .csvImportPreview, .csvImport, .csvImportUndo:
            errorMessage = String(localized: "data_management.error.csv_import")
        }
    }

    private func csvImportCount(for preview: DataManagementCSVImportPreview) -> Int {
        csvImportState.skipPossibleMatches
            ? preview.importableWhenSkippingMatches
            : preview.importableWhenIncludingMatches
    }

    private func dateRangeStart(_ range: ClosedRange<LocalDay>) -> String {
        range.lowerBound.date().formatted(date: .abbreviated, time: .omitted)
    }

    private func dateRangeEnd(_ range: ClosedRange<LocalDay>) -> String {
        range.upperBound.date().formatted(date: .abbreviated, time: .omitted)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as NSError).code == CocoaError.Code.userCancelled.rawValue
    }

    private func showRestoreInterlockErrorIfSafe(
        _ error: Error,
        fallback operation: BusyOperation
    ) {
        guard let hostError = error as? QuickSurfaceHostError else {
            showSanitizedError(for: operation)
            return
        }
        switch hostError {
        case .timerMustBeResolved:
            errorMessage = String(localized: "quick_surfaces.restore.blocked")
        case .resetRequired, .restoreProjectionFailed:
            errorMessage = String(localized: "quick_surfaces.restore.reset_required")
        case .stateUnreadable:
            errorMessage = String(localized: "quick_surfaces.restore.unavailable")
        case .unavailable,
             .preferenceUpdateFailed,
             .invalidReview,
             .resetFailed:
            showSanitizedError(for: operation)
        }
    }
}

private enum BusyOperation: Equatable {
    case backup
    case restorePreview
    case restore
    case csvExport
    case csvImportPreview
    case csvImport
    case csvImportUndo

    var progressTitle: LocalizedStringKey {
        switch self {
        case .backup: "data_management.progress.backup"
        case .restorePreview: "data_management.progress.restore_preview"
        case .restore: "data_management.progress.restore"
        case .csvExport: "data_management.progress.csv"
        case .csvImportPreview: "data_management.progress.csv_import_preview"
        case .csvImport: "data_management.progress.csv_import"
        case .csvImportUndo: "data_management.progress.csv_import_undo"
        }
    }
}

private enum FileImportKind {
    case restore
    case csv

    var allowedContentTypes: [UTType] {
        switch self {
        case .restore: [.hourleafBackup]
        case .csv: [.commaSeparatedText]
        }
    }
}
