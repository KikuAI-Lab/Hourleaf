import SwiftUI

struct WatchEntryView: View {
    private enum DurationField: Hashable {
        case hours
        case minutes
    }

    private enum SaveState: Equatable {
        case idle
        case sending
        case saved
    }

    @State private var kind: WatchTimeEntryKindV1 = .service
    @State private var hours = 0
    @State private var minutes = 0
    @State private var saveState: SaveState = .idle
    @State private var errorMessage: String?
    @FocusState private var focusedField: DurationField?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 3) {
                kindButton(.service, title: "watch.kind.service")
                kindButton(.credit, title: "watch.kind.credit")
            }
            .padding(3)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .accessibilityLabel(Text("watch.kind.label"))
            .accessibilityIdentifier("watchKindPicker")

            HStack(spacing: 6) {
                crownField(
                    value: hours,
                    range: 0...99,
                    field: .hours,
                    label: "watch.hours",
                    shortLabel: "watch.hours.short",
                    identifier: "watchHoursField"
                )

                Text(":")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                crownField(
                    value: minutes,
                    range: 0...59,
                    field: .minutes,
                    label: "watch.minutes",
                    shortLabel: "watch.minutes.short",
                    identifier: "watchMinutesField"
                )
            }

            saveButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            focusedField = .hours
        }
        .alert(
            "watch.error.title",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("watch.error.dismiss", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func kindButton(
        _ candidate: WatchTimeEntryKindV1,
        title: LocalizedStringKey
    ) -> some View {
        let isSelected = kind == candidate

        return Button {
            kind = candidate
            saveState = .idle
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 27)
                .background(
                    isSelected ? Color.accentColor : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(
            candidate == .service ? "watchKindServiceButton" : "watchKindCreditButton"
        )
    }

    private func crownField(
        value: Int,
        range: ClosedRange<Int>,
        field: DurationField,
        label: LocalizedStringKey,
        shortLabel: LocalizedStringKey,
        identifier: String
    ) -> some View {
        let isFocused = focusedField == field
        let crownValue = Binding<Double>(
            get: { Double(value) },
            set: { newValue in
                let boundedValue = min(
                    range.upperBound,
                    max(range.lowerBound, Int(newValue.rounded()))
                )
                switch field {
                case .hours:
                    hours = boundedValue
                case .minutes:
                    minutes = boundedValue
                }
                saveState = .idle
            }
        )

        return Button {
            focusedField = field
            saveState = .idle
        } label: {
            VStack(spacing: 0) {
                Text(verbatim: String(format: "%02d", value))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text(shortLabel)
                    .font(.caption2)
                    .foregroundStyle(isFocused ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(
                isFocused ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedField, equals: field)
        .digitalCrownRotation(
            crownValue,
            from: Double(range.lowerBound),
            through: Double(range.upperBound),
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: String(value)))
        .accessibilityHint(Text("watch.crown.hint"))
        .accessibilityIdentifier(identifier)
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Group {
                switch saveState {
                case .idle:
                    Image(systemName: "checkmark")
                case .sending:
                    ProgressView()
                case .saved:
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                }
            }
            .font(.headline.weight(.semibold))
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(saveState == .saved ? .green : Color.accentColor)
        .disabled(saveState == .sending || hours * 60 + minutes == 0)
        .accessibilityLabel(Text("watch.save"))
        .accessibilityValue(saveAccessibilityValue)
        .accessibilityIdentifier("watchSaveButton")
    }

    private var saveAccessibilityValue: Text {
        switch saveState {
        case .idle:
            Text("")
        case .sending:
            Text("watch.sending")
        case .saved:
            Text("watch.saved")
        }
    }

    private func save() {
        saveState = .sending
        errorMessage = nil
        let selectedKind = kind
        let selectedHours = hours
        let selectedMinutes = minutes

        Task {
            do {
                let now = Date.now
                let total = try WatchTimeEntryDurationV1.totalMinutes(
                    hours: selectedHours,
                    minutes: selectedMinutes
                )
                let envelope = try WatchTimeEntryEnvelopeV1(
                    kind: selectedKind,
                    day: WatchCivilDayV1(now),
                    minutes: total,
                    occurredAt: now
                )
                try await HourleafWatchConnectivityClient.shared.send(envelope)
                await MainActor.run {
                    saveState = .saved
                    hours = 0
                    minutes = 0
                    focusedField = .hours
                }
                try? await Task.sleep(for: .seconds(1.5))
                await MainActor.run {
                    if saveState == .saved {
                        saveState = .idle
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "watch.error.not_confirmed")
                await MainActor.run {
                    saveState = .idle
                    errorMessage = message
                }
            }
        }
    }
}
