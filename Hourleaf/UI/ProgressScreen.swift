import SwiftUI

private struct ReportSharePayload: Identifiable {
    let id = UUID()
    let text: String
}

enum ReportPreviewText {
    static func resolve(
        draftText: String,
        lifecycleState: ReportLifecycleState,
        snapshotText: String?
    ) -> String {
        guard lifecycleState != .draft else { return draftText }
        return snapshotText ?? draftText
    }
}

struct ProgressScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sharePayload: ReportSharePayload?

    private var selectedMonth: MonthKey { model.selectedReportMonth }
    private var earliestMonth: MonthKey { model.settings.ledgerStartMonth }
    private var draft: ReportDraft { model.reportDraft(for: selectedMonth) }
    private var lifecycleState: ReportLifecycleState { model.lifecycleState(for: selectedMonth) }
    private var currentPace: ServiceYearPace { model.currentServiceYearPace() }

    private var selectedStateRecord: ReportStateRecord? {
        model.reportStates.first { $0.month == selectedMonth }
    }

    private var currentSnapshot: ReportSnapshotMetadata? {
        guard let id = selectedStateRecord?.currentSnapshotID else { return nil }
        return model.reportSnapshots.first { $0.id == id }
    }

    private var monthSnapshots: [ReportSnapshotMetadata] {
        model.reportSnapshots
            .filter { $0.receipt.month == selectedMonth }
            .sorted {
                if $0.version != $1.version { return $0.version > $1.version }
                return $0.id.uuidString > $1.id.uuidString
            }
    }

    private var selectedServiceYearStart: MonthKey {
        ServiceYearCalculator.serviceYearStart(
            containing: LocalDay(year: selectedMonth.year, month: selectedMonth.month, day: 1)
        ).monthKey
    }

    private var selectedServiceYearDraft: ServiceYearDraft {
        model.serviceYearDraft(starting: selectedServiceYearStart)
    }

    private var selectedServiceYearArchives: [ServiceYearArchiveRecord] {
        let draft = selectedServiceYearDraft
        return model.serviceYearArchives.filter {
            $0.startMonth == draft.startMonth && $0.endMonth == draft.endMonth
        }
    }

    private var selectedServiceYearStatus: ServiceYearArchiveStatus {
        ServiceYearArchiveStatus.resolve(
            draft: selectedServiceYearDraft,
            currentMonth: model.currentMonth,
            archives: selectedServiceYearArchives
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    monthSelector
                    totalsCard
                    serviceYearCard
                    if selectedServiceYearStart != currentPace.start.monthKey {
                        selectedServiceYearArchiveCard
                    }
                    reportLifecycleCard
                    reportVersionHistory
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("progress.title")
            .sheet(item: $sharePayload) { payload in
                ActivityView(text: payload.text) { _ in
                    sharePayload = nil
                }
            }
            .onAppear(perform: normalizeSelectedMonth)
            .onChange(of: model.settings.ledgerStartMonth) { _, _ in normalizeSelectedMonth() }
            .onChange(of: model.currentMonth) { _, _ in normalizeSelectedMonth() }
        }
    }

    private var monthSelector: some View {
        HStack {
            Button {
                model.selectedReportMonth = selectedMonth.advanced(by: -1, calendar: .hourleaf)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(selectedMonth <= earliestMonth)
            .accessibilityLabel("report.month.previous")
            .accessibilityIdentifier("previousReportMonthButton")

            Spacer()
            Text(AppDateText.month(selectedMonth))
                .font(.title3.bold())
                .accessibilityIdentifier("selectedReportMonth")
            Spacer()

            Button {
                model.selectedReportMonth = selectedMonth.advanced(by: 1, calendar: .hourleaf)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .disabled(selectedMonth >= model.currentMonth)
            .accessibilityLabel("report.month.next")
            .accessibilityIdentifier("nextReportMonthButton")
        }
        .accessibilityElement(children: .contain)
    }

    private var totalsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("progress.month_total")
                .font(.headline)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        monthMetric(
                            title: String(localized: "entry.kind.service"),
                            value: DurationText.format(minutes: draft.report.rawServiceMinutes),
                            color: Color.accentColor
                        )
                        monthMetric(
                            title: String(localized: "entry.kind.credit"),
                            value: DurationText.format(minutes: draft.report.rawCreditMinutes),
                            color: .orange
                        )
                    }
                } else {
                    HStack {
                        monthMetric(
                            title: String(localized: "entry.kind.service"),
                            value: DurationText.format(minutes: draft.report.rawServiceMinutes),
                            color: Color.accentColor
                        )
                        Divider().frame(height: 44)
                        monthMetric(
                            title: String(localized: "entry.kind.credit"),
                            value: DurationText.format(minutes: draft.report.rawCreditMinutes),
                            color: .orange
                        )
                    }
                }
            }
            if draft.report.serviceCarryIn > 0 || draft.report.creditCarryIn > 0 {
                Text(String(
                    format: String(localized: "progress.carry_in_format"),
                    draft.report.serviceCarryIn,
                    draft.report.creditCarryIn
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .hourleafCard()
    }

    private var serviceYearCard: some View {
        let pace = currentPace

        return VStack(alignment: .leading, spacing: 12) {
            Text(String(
                format: String(localized: "pace.service_year_range_format"),
                AppDateText.range(from: pace.start, through: pace.endInclusive)
            ))
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("currentServiceYearRange")

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        serviceYearActual(pace)
                        serviceYearTarget(pace)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        serviceYearActual(pace)
                        Spacer(minLength: 12)
                        serviceYearTarget(pace)
                    }
                }
            }

            ProgressView(
                value: min(Double(pace.actualMinutes), Double(pace.targetMinutes)),
                total: Double(pace.targetMinutes)
            )
            .tint(Color.accentColor)
            .accessibilityLabel(String(localized: "progress.service_year"))
            .accessibilityValue(DurationText.format(minutes: pace.actualMinutes))

        }
        .hourleafCard()
        .accessibilityElement(children: .contain)
    }

    private func serviceYearActual(_ pace: ServiceYearPace) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("pace.actual_label")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(DurationText.format(minutes: pace.actualMinutes))
                .font(.title3.bold().monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func serviceYearTarget(_ pace: ServiceYearPace) -> some View {
        Text(String(
            format: String(localized: "pace.target_format"),
            DurationText.format(minutes: pace.targetMinutes)
        ))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selectedServiceYearArchiveCard: some View {
        let yearDraft = selectedServiceYearDraft
        let totalMinutes = yearDraft.actualServiceMinutes + yearDraft.baselineServiceMinutes
        let status = selectedServiceYearStatus

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("service_year.archive_title")
                    .font(.headline)
                Spacer()
                Text("\(totalMinutes / 60) / \(yearDraft.targetMinutes / 60)")
                    .font(.headline.monospacedDigit())
            }
            ProgressView(
                value: min(Double(totalMinutes), Double(yearDraft.targetMinutes)),
                total: Double(yearDraft.targetMinutes)
            )
            .tint(Color.accentColor)
            Text(String(format: String(localized: "progress.minutes_detail_format"), totalMinutes % 60))
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(status.localizationKey, systemImage: status.symbolName)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("serviceYearArchiveState")

            if status != .current {
                NavigationLink {
                    ServiceYearArchiveView(
                        draft: yearDraft,
                        currentMonth: model.currentMonth,
                        archives: selectedServiceYearArchives,
                        isBusy: model.closingServiceYearStarts.contains(yearDraft.startMonth),
                        onCloseServiceYear: {
                            let displayedDraft = yearDraft
                            Task { _ = await model.closeServiceYear(displayedDraft) }
                        }
                    )
                } label: {
                    Label(serviceYearActionKey(for: status), systemImage: "chevron.right")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("reviewServiceYearButton")
            }
        }
        .hourleafCard()
        .accessibilityElement(children: .contain)
    }

    private var reportLifecycleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(reportStateKey, systemImage: reportStateSymbol)
                .font(.headline)
                .accessibilityIdentifier("reportLifecycleState")
            reportExplanation
            reportBreakdown
            reportTextPreview
            reportAction
        }
        .hourleafCard()
    }

    @ViewBuilder
    private var reportExplanation: some View {
        switch lifecycleState {
        case .draft:
            Text("report.draft.explanation")
        case .ready:
            Text("report.ready.explanation")
        case .changed:
            VStack(alignment: .leading, spacing: 5) {
                Text("report.changed.explanation")
                if let currentSnapshot,
                   currentSnapshot.calculationFingerprint != draft.calculationFingerprint {
                    Label("report.changed.calculation", systemImage: "sum")
                } else {
                    Label("report.changed.wording", systemImage: "textformat")
                }
            }
        case .reviewed, .prepared, .sent:
            EmptyView()
        }
    }

    private var reportBreakdown: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(format: String(localized: "report.entries_count_format"), draft.entries.count))
            Text(String(
                format: String(localized: "report.breakdown.service_format"),
                DurationText.format(minutes: draft.report.rawServiceMinutes)
            ))
            Text(String(
                format: String(localized: "report.breakdown.credit_format"),
                DurationText.format(minutes: draft.report.rawCreditMinutes)
            ))
            Text(String(
                format: String(localized: "report.breakdown.rule_format"),
                draft.reportingMode.localizedName
            ))
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var reportTextPreview: some View {
        Text(ReportPreviewText.resolve(
            draftText: draft.text,
            lifecycleState: lifecycleState,
            snapshotText: currentSnapshot?.receipt.text
        ))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                Color(.tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .accessibilityIdentifier("reportPreview")
    }

    @ViewBuilder
    private var reportAction: some View {
        switch lifecycleState {
        case .draft:
            EmptyView()

        case .ready, .changed:
            NavigationLink {
                ReportReviewView(draft: draft)
            } label: {
                Label(
                    lifecycleState == .changed
                        ? "report.action.review_correction"
                        : "report.action.review",
                    systemImage: "doc.text.magnifyingglass"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .accessibilityIdentifier("reportReviewButton")

        case .reviewed:
            Button {
                let displayedDraft = draft
                Task {
                    if let snapshot = await model.prepareReport(displayedDraft) {
                        sharePayload = ReportSharePayload(text: snapshot.receipt.text)
                    }
                }
            } label: {
                Group {
                    if model.preparingReportMonths.contains(selectedMonth) {
                        ProgressView()
                    } else {
                        Label(
                            currentSnapshot == nil
                                ? "report.action.prepare"
                                : "report.action.prepare_correction",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(model.preparingReportMonths.contains(selectedMonth))
            .accessibilityIdentifier("prepareReportButton")

        case .prepared:
            if let currentSnapshot {
                VStack(alignment: .leading, spacing: 10) {
                    Text("report.share.disclaimer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    sharePreparedButton(currentSnapshot)
                    Button {
                        let snapshot = currentSnapshot
                        Task { _ = await model.markReportSent(snapshot) }
                    } label: {
                        Group {
                            if model.markingSentSnapshotIDs.contains(currentSnapshot.id) {
                                ProgressView()
                            } else {
                                Label("report.action.mark_sent", systemImage: "checkmark.circle")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.markingSentSnapshotIDs.contains(currentSnapshot.id))
                    .accessibilityIdentifier("markReportSentButton")
                }
            }

        case .sent:
            if let currentSnapshot {
                VStack(alignment: .leading, spacing: 8) {
                    if let sentAt = currentSnapshot.receipt.confirmedSentAt {
                        Label {
                            Text(sentAt, style: .date)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .foregroundStyle(.secondary)
                    }
                    sharePreparedButton(currentSnapshot)
                }
            }
        }
    }

    private func sharePreparedButton(_ snapshot: ReportSnapshotMetadata) -> some View {
        Button {
            sharePayload = ReportSharePayload(text: snapshot.receipt.text)
        } label: {
            Label("report.action.share_prepared", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .accessibilityIdentifier("sharePreparedReportButton")
    }

    @ViewBuilder
    private var reportVersionHistory: some View {
        if !monthSnapshots.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("report.history")
                    .font(.headline)
                ForEach(monthSnapshots) { snapshot in
                    DisclosureGroup {
                        Text(snapshot.receipt.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        if snapshot.legacyCalculationUnavailable {
                            Text("report.snapshot.legacy")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: snapshot.receipt.confirmedSentAt == nil ? "doc" : "checkmark.circle.fill")
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshotVersionTitle(snapshot))
                                    .font(.headline)
                                Text(snapshot.receipt.confirmedSentAt == nil ? "report.state.prepared" : "report.state.sent")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if snapshot.id != selectedStateRecord?.currentSnapshotID {
                                    Text("report.snapshot.earlier")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(snapshot.receipt.preparedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .hourleafCard()
            .accessibilityIdentifier("reportVersionHistory")
        }
    }

    private var reportStateKey: LocalizedStringKey {
        switch lifecycleState {
        case .draft: "report.state.draft"
        case .ready: "report.state.ready"
        case .reviewed: "report.state.reviewed"
        case .prepared: "report.state.prepared"
        case .sent: "report.state.sent"
        case .changed: "report.state.changed"
        }
    }

    private var reportStateSymbol: String {
        switch lifecycleState {
        case .draft: "calendar"
        case .ready: "doc.text.magnifyingglass"
        case .reviewed: "checkmark.circle"
        case .prepared: "square.and.arrow.up"
        case .sent: "checkmark.circle.fill"
        case .changed: "arrow.triangle.2.circlepath"
        }
    }

    private func snapshotVersionTitle(_ snapshot: ReportSnapshotMetadata) -> String {
        if snapshot.version <= 1 {
            return String(localized: "report.snapshot.original")
        }
        return String(
            format: String(localized: "report.snapshot.correction_format"),
            snapshot.version - 1
        )
    }

    private func serviceYearActionKey(for status: ServiceYearArchiveStatus) -> LocalizedStringKey {
        switch status {
        case .ready: "service_year.action.review"
        case .changed: "service_year.action.review_correction"
        case .archived, .corrected, .legacy: "service_year.action.view"
        case .current: "service_year.action.view"
        }
    }

    private func monthMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func normalizeSelectedMonth() {
        if model.selectedReportMonth < earliestMonth {
            model.selectedReportMonth = earliestMonth
        } else if model.selectedReportMonth > model.currentMonth {
            model.selectedReportMonth = model.currentMonth
        }
    }
}

private extension View {
    func hourleafCard() -> some View {
        padding()
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
    }
}
