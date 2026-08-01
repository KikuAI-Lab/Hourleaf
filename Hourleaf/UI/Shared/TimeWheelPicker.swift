import SwiftUI

struct TimeWheelPicker: View {
    @Binding var hours: Int
    @Binding var minutes: Int
    var maximumHours = 99

    var body: some View {
        HStack(spacing: 8) {
            wheel(
                title: String(localized: "time.hours"),
                selection: $hours,
                values: Array(0...maximumHours)
            )
            wheel(
                title: String(localized: "time.minutes"),
                selection: $minutes,
                values: Array(0...59)
            )
        }
        .frame(height: 150)
        .dynamicTypeSize(.xSmall ... .xxxLarge)
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
}
