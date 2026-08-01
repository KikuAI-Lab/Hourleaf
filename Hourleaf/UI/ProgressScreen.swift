import SwiftUI

private struct SharePayload: Identifiable {
    let id = UUID()
    let text: String
    let receipt: ReportReceipt
}

struct ProgressScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedMonth = MonthKey(Date(), calendar: .hourleaf).advanced(by: -1, calendar: .hourleaf)
    @State private var sharePayload: SharePayload?
    @State private var receiptToConfirm: ReportReceipt?
    @State private var showSentConfirmation = false

    private var report: MonthlyReport { model.report(for: selectedMonth) }
    private var reportText: String { ReportFormatter.format(report, settings: model.settings) }
    private var currentMonth: MonthKey { MonthKey(Date(), calendar: .hourleaf) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    monthSelector
                    totalsCard
                    serviceYearCard
                    reportCard
                    receiptsCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("progress.title")
            .sheet(item: $sharePayload) { payload in
                ActivityView(text: payload.text) { completed in
                    Task { @MainActor in
                        sharePayload = nil
                        if completed {
                            receiptToConfirm = payload.receipt
                            showSentConfirmation = true
                        }
                    }
                }
            }
            .alert("report.mark_sent.title", isPresented: $showSentConfirmation) {
                Button("report.not_sent", role: .cancel) { receiptToConfirm = nil }
                Button("report.mark_sent") {
                    if let receiptToConfirm { model.markReceiptSent(receiptToConfirm) }
                    receiptToConfirm = nil
                }
            } message: {
                Text("report.mark_sent.message")
            }
        }
    }

    private var monthSelector: some View {
        HStack {
            Button { selectedMonth = selectedMonth.advanced(by: -1, calendar: .hourleaf) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            Spacer()
            Text(AppDateText.month(selectedMonth)).font(.title3.bold())
            Spacer()
            Button { selectedMonth = selectedMonth.advanced(by: 1, calendar: .hourleaf) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(selectedMonth >= currentMonth)
        }
        .accessibilityElement(children: .contain)
    }

    private var totalsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("progress.month_total").font(.headline)
            HStack {
                metric(title: String(localized: "entry.kind.service"), value: DurationText.format(minutes: report.rawServiceMinutes), color: .green)
                Divider().frame(height: 44)
                metric(title: String(localized: "entry.kind.credit"), value: DurationText.format(minutes: report.rawCreditMinutes), color: .orange)
            }
            if report.serviceCarryIn > 0 || report.creditCarryIn > 0 {
                Text(String(format: String(localized: "progress.carry_in_format"), report.serviceCarryIn, report.creditCarryIn))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .hourleafCard()
    }

    private var serviceYearCard: some View {
        let progress = model.serviceYearProgress(containing: LocalDay(selectedMonth.date(calendar: .hourleaf), calendar: .hourleaf))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("progress.service_year").font(.headline)
                Spacer()
                Text("\(progress / 60) / 600").font(.headline.monospacedDigit())
            }
            ProgressView(value: min(Double(progress), 36_000), total: 36_000)
                .tint(.green)
            Text(String(format: String(localized: "progress.minutes_detail_format"), progress % 60))
                .font(.caption).foregroundStyle(.secondary)
        }
        .hourleafCard()
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("report.preview").font(.headline)
                Spacer()
                if report.serviceCarryOut > 0 || report.creditCarryOut > 0 {
                    Label("report.has_carry", systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(reportText)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("reportPreview")
            if report.serviceCarryOut > 0 || report.creditCarryOut > 0 {
                Text(String(format: String(localized: "report.carry_out_format"), report.serviceCarryOut, report.creditCarryOut))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(action: share) {
                Label("report.share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityIdentifier("shareReportButton")
        }
        .hourleafCard()
    }

    @ViewBuilder
    private var receiptsCard: some View {
        let receipts = model.receipts.filter { $0.month == selectedMonth }
        if !receipts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("report.history").font(.headline)
                ForEach(receipts.prefix(3)) { receipt in
                    HStack {
                        Image(systemName: receipt.confirmedSentAt == nil ? "doc" : "checkmark.circle.fill")
                            .foregroundStyle(receipt.confirmedSentAt == nil ? Color.secondary : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: receipt.confirmedSentAt == nil ? "report.prepared" : "report.sent"))
                            Text(receipt.preparedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isStale(receipt) {
                            Text("report.changed").font(.caption.bold()).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .hourleafCard()
        }
    }

    private func metric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func share() {
        guard let receipt = model.createReceipt(for: report, text: reportText) else { return }
        sharePayload = SharePayload(text: reportText, receipt: receipt)
    }
}

private extension View {
    func hourleafCard() -> some View {
        padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
