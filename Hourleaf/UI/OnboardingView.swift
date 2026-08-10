import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var baselineHours = 0
    @State private var baselineMinutes = 0
    @State private var serviceCarry = 0
    @State private var creditCarry = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("onboarding.subtitle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("onboarding.progress_title").font(.headline)
                        Text("onboarding.progress_detail").font(.subheadline).foregroundStyle(.secondary)
                        TimeWheelPicker(hours: $baselineHours, minutes: $baselineMinutes, usesDirectHourEntry: true)
                    }
                    .hourleafOnboardingCard()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("onboarding.carry_title").font(.headline)
                        Stepper(String(format: String(localized: "balances.service_carry_format"), serviceCarry), value: $serviceCarry, in: 0...59)
                        Stepper(String(format: String(localized: "balances.credit_carry_format"), creditCarry), value: $creditCarry, in: 0...59)
                        Text("onboarding.carry_detail").font(.caption).foregroundStyle(.secondary)
                    }
                    .hourleafOnboardingCard()
                    Button(action: finish) {
                        Text("onboarding.start")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .accessibilityIdentifier("finishOnboardingButton")
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private func finish() {
        var settings = model.settings
        settings.ledgerStartMonth = MonthKey(model.currentDate, calendar: .hourleaf)
        settings.baselineServiceYearMinutes = baselineHours * 60 + baselineMinutes
        settings.baselineServiceYearStart = ServiceYearCalculator.serviceYearStart(
            containing: LocalDay(model.currentDate, calendar: .hourleaf)
        ).monthKey
        settings.openingServiceCarryMinutes = serviceCarry
        settings.openingCreditCarryMinutes = creditCarry
        settings.onboardingComplete = true
        Task { await model.saveSettings(settings) }
    }
}

private extension View {
    func hourleafOnboardingCard() -> some View {
        padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
