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
                    Image(systemName: "leaf.circle.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(.green.gradient)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("onboarding.title").font(.largeTitle.bold())
                        Text("onboarding.subtitle").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
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
                    .tint(.green)
                    .accessibilityIdentifier("finishOnboardingButton")
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private func finish() {
        var settings = model.settings
        settings.ledgerStartMonth = MonthKey(Date(), calendar: .hourleaf)
        settings.baselineServiceYearMinutes = baselineHours * 60 + baselineMinutes
        settings.baselineServiceYearStart = ServiceYearCalculator.serviceYearStart(
            containing: LocalDay(Date(), calendar: .hourleaf)
        ).monthKey
        settings.openingServiceCarryMinutes = serviceCarry
        settings.openingCreditCarryMinutes = creditCarry
        settings.onboardingComplete = true
        model.saveSettings(settings)
    }
}

private extension View {
    func hourleafOnboardingCard() -> some View {
        padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
