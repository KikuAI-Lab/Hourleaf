import SwiftUI

enum ServiceYearArchiveStatus: Equatable {
    case current
    case ready
    case archived
    case changed
    case corrected
    case legacy

    static func resolve(
        draft: ServiceYearDraft,
        currentMonth: MonthKey,
        archives: [ServiceYearArchiveRecord]
    ) -> ServiceYearArchiveStatus {
        guard draft.endMonth < currentMonth else { return .current }
        guard let latest = archives.sorted(by: archiveOrder).first else { return .ready }

        if latest.calculationFingerprint.hasPrefix("service-year-v1:") {
            guard ReportReadiness.archiveMatchesDraft(latest, draft: draft) else { return .changed }
            return latest.version > 1 ? .corrected : .archived
        }

        let legacyMatches = latest.startMonth == draft.startMonth
            && latest.endMonth == draft.endMonth
            && latest.actualServiceMinutes == draft.actualServiceMinutes
            && latest.baselineServiceMinutes == draft.baselineServiceMinutes
            && latest.targetMinutes == draft.targetMinutes
        return legacyMatches ? .legacy : .changed
    }

    var localizationKey: LocalizedStringKey {
        switch self {
        case .current: "service_year.state.current"
        case .ready: "service_year.state.ready"
        case .archived: "service_year.state.archived"
        case .changed: "service_year.state.changed"
        case .corrected: "service_year.state.corrected"
        case .legacy: "service_year.state.legacy"
        }
    }

    var symbolName: String {
        switch self {
        case .current: "calendar"
        case .ready: "archivebox"
        case .archived: "checkmark.seal"
        case .changed: "arrow.triangle.2.circlepath"
        case .corrected: "checkmark.seal.fill"
        case .legacy: "clock.arrow.circlepath"
        }
    }

    private static func archiveOrder(_ lhs: ServiceYearArchiveRecord, _ rhs: ServiceYearArchiveRecord) -> Bool {
        if lhs.version != rhs.version { return lhs.version > rhs.version }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

struct ServiceYearArchiveView: View {
    let draft: ServiceYearDraft
    let currentMonth: MonthKey
    let archives: [ServiceYearArchiveRecord]
    let isBusy: Bool
    let onCloseServiceYear: () -> Void

    private var periodArchives: [ServiceYearArchiveRecord] {
        archives
            .filter { $0.startMonth == draft.startMonth && $0.endMonth == draft.endMonth }
            .sorted {
                if $0.version != $1.version { return $0.version > $1.version }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString > $1.id.uuidString
            }
    }

    private var status: ServiceYearArchiveStatus {
        ServiceYearArchiveStatus.resolve(
            draft: draft,
            currentMonth: currentMonth,
            archives: periodArchives
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusCard
                summaryCard
                if !periodArchives.isEmpty {
                    historyCard
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("service_year.review.title")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            actionSection
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(status.localizationKey, systemImage: status.symbolName)
                .font(.headline)
            Text(String(
                format: String(localized: "service_year.period_format"),
                AppDateText.month(draft.startMonth),
                AppDateText.month(draft.endMonth)
            ))
            .font(.title3.bold())
        }
        .hourleafArchiveCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("serviceYearArchiveState")
    }

    private var summaryCard: some View {
        let recorded = DurationText.format(minutes: draft.actualServiceMinutes)
        let baseline = DurationText.format(minutes: draft.baselineServiceMinutes)
        let total = DurationText.format(minutes: draft.actualServiceMinutes + draft.baselineServiceMinutes)

        return VStack(alignment: .leading, spacing: 12) {
            Text(String(format: String(localized: "service_year.recorded_format"), recorded))
            if draft.baselineServiceMinutes > 0 {
                Text(String(format: String(localized: "service_year.baseline_format"), baseline))
            }
            Text(String(format: String(localized: "service_year.total_format"), total))
                .font(.headline)
            Label("service_year.target", systemImage: "target")
            Label("service_year.credit_excluded", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if status == .ready || status == .changed {
                Text("service_year.close_explanation")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .hourleafArchiveCard()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("service_year.archive.history")
                .font(.headline)
            ForEach(periodArchives) { archive in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(versionTitle(for: archive))
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text(archive.createdAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(String(
                        format: String(localized: "service_year.total_format"),
                        DurationText.format(
                            minutes: archive.actualServiceMinutes + archive.baselineServiceMinutes
                        )
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                if archive.id != periodArchives.last?.id {
                    Divider()
                }
            }
        }
        .hourleafArchiveCard()
    }

    @ViewBuilder
    private var actionSection: some View {
        if status == .ready || status == .changed {
            Button(action: onCloseServiceYear) {
                Group {
                    if isBusy {
                        ProgressView()
                    } else if status == .ready {
                        Label("service_year.action.close", systemImage: "archivebox")
                    } else {
                        Label("service_year.action.save_correction", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(isBusy)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityIdentifier(
                status == .ready ? "closeServiceYearButton" : "saveServiceYearCorrectionButton"
            )
        }
    }

    private func versionTitle(for archive: ServiceYearArchiveRecord) -> String {
        if archive.version <= 1 {
            return String(localized: "service_year.archive.original")
        }
        return String(
            format: String(localized: "service_year.archive.correction_format"),
            archive.version - 1
        )
    }
}

private extension View {
    func hourleafArchiveCard() -> some View {
        padding()
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
    }
}
