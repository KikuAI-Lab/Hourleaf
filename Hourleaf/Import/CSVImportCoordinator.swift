import Foundation

enum CSVImportCoordinatorError: LocalizedError, Equatable, Sendable {
    case noPreparedCandidate
    case importFailed

    var errorDescription: String? {
        switch self {
        case .noPreparedCandidate, .importFailed:
            "The CSV file could not be imported."
        }
    }
}

/// Keeps the decoded CSV document in memory between the privacy-safe preview
/// and confirmation. The source URL is deliberately not retained, so a
/// confirmation cannot reread a file that changed after preview.
actor CSVImportCoordinator {
    private struct PreparedCandidate: Sendable {
        let id: UUID
        let document: CSVImportDocument
    }

    private let repository: any LedgerRepository
    private let codec: CSVImportCodec
    private var preparedCandidate: PreparedCandidate?

    init(
        repository: any LedgerRepository,
        codec: CSVImportCodec = CSVImportCodec()
    ) {
        self.repository = repository
        self.codec = codec
    }

    func prepare(from url: URL) async throws -> CSVImportPreview {
        // A new choice explicitly replaces any older preview before reading
        // begins. No source path or raw row data is kept after this method.
        preparedCandidate = nil

        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        let document: CSVImportDocument
        do {
            document = try codec.decode(from: url)
        } catch let error as CSVImportCodecError {
            throw error
        } catch {
            throw CSVImportCoordinatorError.importFailed
        }

        let candidateID = UUID()
        do {
            let preview = try await repository.previewCSVImport(
                document,
                candidateID: candidateID
            )
            preparedCandidate = PreparedCandidate(
                id: candidateID,
                document: document
            )
            return preview
        } catch let error as CSVImportRepositoryError {
            throw CSVImportCoordinatorError.importFailed
        } catch {
            throw CSVImportCoordinatorError.importFailed
        }
    }

    func confirm(
        _ candidateID: UUID,
        policy: CSVImportDuplicatePolicy
    ) async throws -> CSVImportResult {
        guard let candidate = preparedCandidate, candidate.id == candidateID else {
            throw CSVImportCoordinatorError.noPreparedCandidate
        }

        do {
            let result = try await repository.applyCSVImport(
                candidate.document,
                policy: policy
            )
            // Consumption happens only after the repository returns a verified
            // result. A failed confirmation leaves this exact candidate ready
            // for an explicit retry while the view remains alive.
            preparedCandidate = nil
            return result
        } catch let error as CSVImportRepositoryError {
            _ = error
            throw CSVImportCoordinatorError.importFailed
        } catch {
            throw CSVImportCoordinatorError.importFailed
        }
    }

    func discard(_ candidateID: UUID) async {
        guard preparedCandidate?.id == candidateID else { return }
        preparedCandidate = nil
    }

    func undo(_ token: CSVImportUndoToken) async throws -> CSVImportUndoResult {
        do {
            return try await repository.undoCSVImport(token)
        } catch let error as CSVImportRepositoryError {
            _ = error
            throw CSVImportCoordinatorError.importFailed
        } catch {
            throw CSVImportCoordinatorError.importFailed
        }
    }
}
