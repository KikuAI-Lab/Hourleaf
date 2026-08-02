import SwiftUI

struct QuickEntryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var kind: EntryKind = .service
    @State private var date = Date()
    @State private var hours = 0
    @State private var minutes = 0
    @State private var note = ""
    @State private var didSave = false
    @FocusState private var noteFocused: Bool

    private var previousMonth: MonthKey {
        MonthKey(Date(), calendar: .hourleaf).advanced(by: -1, calendar: .hourleaf)
    }

    private var previousReport: MonthlyReport { model.report(for: previousMonth) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if reportNeedsAttention { reportBanner }
                    entryCard
                    monthSummary
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("quick.title")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var reportNeedsAttention: Bool {
        let hasTime = previousReport.rawServiceMinutes + previousReport.rawCreditMinutes
            + previousReport.serviceCarryIn + previousReport.creditCarryIn > 0
        return hasTime && !model.hasConfirmedReceipt(in: previousMonth)
    }

    private var reportBanner: some View {
        Button {
            model.selectedTab = .progress
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("quick.report_ready").font(.headline)
                    Text(AppDateText.month(previousMonth)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("previousReportBanner")
    }

    private var entryCard: some View {
        VStack(spacing: 16) {
            Picker("entry.type", selection: $kind) {
                ForEach(EntryKind.allCases) { item in
                    Text(item.localizedName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("entryKindPicker")

            dateInput

            Divider()
            TimeWheelPicker(hours: $hours, minutes: $minutes)
            Divider()

            TextField("entry.note_placeholder", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .focused($noteFocused)
                .accessibilityIdentifier("entryNoteField")

            Button(action: save) {
                Label(didSave ? "entry.saved" : "entry.save", systemImage: didSave ? "checkmark" : "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(hours == 0 && minutes == 0)
            .accessibilityIdentifier("saveEntryButton")
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var dateInput: some View {
        let range = model.settings.ledgerStartMonth.date(calendar: .hourleaf)...Date()
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text("entry.date").font(.headline)
                DatePicker("entry.date", selection: $date, in: range, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("entryDatePicker")
        } else {
            DatePicker("entry.date", selection: $date, in: range, displayedComponents: .date)
                .datePickerStyle(.compact)
                .accessibilityIdentifier("entryDatePicker")
        }
    }

    private var monthSummary: some View {
        let report = model.report(for: MonthKey(date, calendar: .hourleaf))
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    summaryMetric("quick.month_service", minutes: report.rawServiceMinutes)
                    summaryMetric("quick.month_credit", minutes: report.rawCreditMinutes)
                }
            } else {
                HStack {
                    summaryMetric("quick.month_service", minutes: report.rawServiceMinutes)
                    Spacer()
                    summaryMetric("quick.month_credit", minutes: report.rawCreditMinutes, trailing: true)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func summaryMetric(_ key: LocalizedStringKey, minutes: Int, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 4) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Text(DurationText.format(minutes: minutes)).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

    private func save() {
        noteFocused = false
        guard model.addEntry(kind: kind, date: date, hours: hours, minutes: minutes, note: note) else { return }
        hours = 0
        minutes = 0
        note = ""
        didSave = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { didSave = false }
        }
    }
}
