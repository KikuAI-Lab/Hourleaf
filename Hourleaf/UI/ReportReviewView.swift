import SwiftUI

struct ReportReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let draft: ReportDraft

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                lifecycleHeader
                calculationCard
                reportTextCard
                entryList
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("report.review.title")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            finishButton
        }
    }

    private var lifecycleHeader: some View {
        let isCorrection = model.lifecycleState(for: draft.month) == .changed
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                isCorrection ? "report.state.changed" : "report.state.ready",
                systemImage: isCorrection ? "arrow.triangle.2.circlepath" : "doc.text.magnifyingglass"
            )
            .font(.headline)
            Text(isCorrection ? "report.changed.explanation" : "report.ready.explanation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .hourleafReportCard()
        .accessibilityElement(children: .combine)
    }

    private var calculationCard: some View {
        let reportedCreditHours = String(
            format: String(localized: "duration.hours_format"),
            draft.report.creditHours
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text(String(format: String(localized: "report.entries_count_format"), draft.entries.count))
                .font(.headline)

            breakdownRow(
                key: "report.breakdown.service_format",
                value: DurationText.format(minutes: draft.report.rawServiceMinutes)
            )
            if draft.report.serviceCarryIn > 0 {
                breakdownRow(
                    key: "report.breakdown.incoming_format",
                    value: DurationText.format(minutes: draft.report.serviceCarryIn)
                )
            }
            Text(String(format: String(localized: "report.breakdown.result_format"), draft.report.serviceHours))
            if draft.report.serviceCarryOut > 0 {
                Text(String(
                    format: String(localized: "report.breakdown.carry_format"),
                    draft.report.serviceCarryOut
                ))
            }

            if hasCreditCalculation {
                Divider()
                breakdownRow(
                    key: "report.breakdown.credit_format",
                    value: DurationText.format(minutes: draft.report.rawCreditMinutes)
                )
                if draft.report.creditCarryIn > 0 {
                    breakdownRow(
                        key: "report.breakdown.incoming_format",
                        value: DurationText.format(minutes: draft.report.creditCarryIn)
                    )
                }
                Text("\(draft.creditLabel): \(reportedCreditHours)")
                if draft.report.creditCarryOut > 0 {
                    Text(String(
                        format: String(localized: "report.breakdown.carry_format"),
                        draft.report.creditCarryOut
                    ))
                }
            }

            Divider()
            breakdownRow(key: "report.breakdown.rule_format", value: draft.reportingMode.localizedName)
            if draft.month.month == 8 {
                Label("report.breakdown.august_reset", systemImage: "arrow.counterclockwise")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .hourleafReportCard()
        .accessibilityIdentifier("reportCalculationBreakdown")
    }

    private var hasCreditCalculation: Bool {
        draft.report.rawCreditMinutes > 0
            || draft.report.creditCarryIn > 0
            || draft.report.creditHours > 0
            || draft.report.creditCarryOut > 0
    }

    private var reportTextCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("report.preview")
                .font(.headline)
            Text(draft.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(
                    Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .accessibilityIdentifier("reportPreview")
        }
        .hourleafReportCard()
    }

    private var entryList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: String(localized: "report.entries_count_format"), draft.entries.count))
                .font(.headline)

            if draft.entries.isEmpty {
                Text("history.empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(draft.entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.kind.systemImage)
                            .foregroundStyle(entry.kind == .service ? .green : .orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.kind.localizedName)
                                .font(.headline)
                            Text(AppDateText.day(entry.day))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let note = entry.note, !note.isEmpty {
                                Text(note)
                                    .font(.subheadline)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(DurationText.format(minutes: entry.minutes))
                            .font(.headline.monospacedDigit())
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .hourleafReportCard()
        .accessibilityIdentifier("reportReviewEntryList")
    }

    private var finishButton: some View {
        Button {
            let displayedDraft = draft
            Task {
                if await model.reviewReport(displayedDraft) {
                    dismiss()
                }
            }
        } label: {
            Group {
                if model.reviewingReportMonths.contains(draft.month) {
                    ProgressView()
                } else {
                    Label("report.action.finish_review", systemImage: "checkmark.circle")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .disabled(model.reviewingReportMonths.contains(draft.month))
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityIdentifier("finishReportReviewButton")
    }

    private func breakdownRow(key: String.LocalizationValue, value: String) -> some View {
        Text(String(format: String(localized: key), value))
    }
}

private extension View {
    func hourleafReportCard() -> some View {
        padding()
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
    }
}
