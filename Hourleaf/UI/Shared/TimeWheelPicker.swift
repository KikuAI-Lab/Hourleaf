import SwiftUI

struct TimeWheelPicker: View {
    @Binding var hours: Int
    @Binding var minutes: Int
    var maximumHours = 99
    var usesDirectHourEntry = false
    var maximumDirectHours = 24 * 366
    var wheelHeight: CGFloat = 150
    var selectionFeedbackEnabled = false

    @State private var selectionFeedbackTrigger = false

    var body: some View {
        HStack(spacing: 8) {
            if usesDirectHourEntry {
                directHourInput
            } else {
                wheel(
                    title: String(localized: "time.hours"),
                    selection: feedbackSelection($hours),
                    values: Array(0...maximumHours)
                )
            }
            wheel(
                title: String(localized: "time.minutes"),
                selection: feedbackSelection($minutes),
                values: Array(0...59)
            )
        }
        .frame(height: wheelHeight)
        .dynamicTypeSize(.xSmall ... .xxxLarge)
        .sensoryFeedback(.selection, trigger: selectionFeedbackTrigger)
    }

    private var directHourInput: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "time.hours"), value: $hours, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit())
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "time.hours"))
                .accessibilityIdentifier("baselineHoursField")
                .onChange(of: hours) { _, value in
                    hours = min(max(0, value), maximumDirectHours)
                }
            Text(String(localized: "time.hours"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func wheel(title: String, selection: Binding<Int>, values: [Int]) -> some View {
        HStack(spacing: 0) {
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.wheel)
            .accessibilityLabel(title)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    /// Only Picker writes pass through this binding. Parent-driven updates,
    /// including the reset after saving, update the source binding directly
    /// and therefore do not request feedback.
    private func feedbackSelection(_ selection: Binding<Int>) -> Binding<Int> {
        Binding(
            get: { selection.wrappedValue },
            set: { selectedValue in
                let previousValue = selection.wrappedValue
                selection.wrappedValue = selectedValue
                if TimeSelectionFeedbackPreference.shouldRequestFeedback(
                    for: .userInteraction,
                    isEnabled: selectionFeedbackEnabled,
                    previousValue: previousValue,
                    selectedValue: selectedValue
                ) {
                    selectionFeedbackTrigger.toggle()
                }
            }
        )
    }
}
