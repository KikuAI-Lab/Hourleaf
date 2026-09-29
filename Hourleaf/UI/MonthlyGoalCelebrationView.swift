import SwiftUI
import UIKit

struct MonthlyGoalCelebrationView: View {
    let celebration: MonthlyGoalCelebration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if !reduceMotion {
                    confetti(in: geometry.size)
                        .accessibilityHidden(true)
                }

                celebrationCard
                    .padding(.horizontal, 28)
                    .opacity(isPresented ? 1 : 0)
                    .scaleEffect(isPresented ? 1 : 0.94)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monthlyGoalCelebration")
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) {
                isPresented = true
            }
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "monthly_goal.celebration.announcement")
            )
        }
    }

    private var celebrationCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text("monthly_goal.celebration.title")
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            Text("monthly_goal.celebration.message")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 7)
    }

    private func confetti(in size: CGSize) -> some View {
        ForEach(0..<42, id: \.self) { index in
            let horizontalPosition = random(index, salt: 1) * size.width
            let delay = random(index, salt: 2) * 0.55
            let drift = (random(index, salt: 3) - 0.5) * 90
            let turns = 1.5 + random(index, salt: 4) * 3.5
            let width = 6 + random(index, salt: 5) * 5
            let height = 10 + random(index, salt: 6) * 7

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(particleColor(for: index))
                .frame(width: width, height: height)
                .position(x: horizontalPosition, y: -24)
                .offset(
                    x: isPresented ? drift : 0,
                    y: isPresented ? size.height + 70 : 0
                )
                .rotationEffect(.degrees(isPresented ? 360 * turns : 0))
                .opacity(0.92)
                .animation(
                    .timingCurve(0.35, 0, 0.8, 1, duration: 1.9)
                        .delay(delay),
                    value: isPresented
                )
        }
    }

    private func particleColor(for index: Int) -> Color {
        let colors: [Color] = [
            Color(red: 74 / 255, green: 109 / 255, blue: 167 / 255),
            Color(red: 79 / 255, green: 168 / 255, blue: 205 / 255),
            Color(red: 245 / 255, green: 190 / 255, blue: 74 / 255),
            Color(red: 226 / 255, green: 105 / 255, blue: 118 / 255),
            Color(red: 137 / 255, green: 105 / 255, blue: 190 / 255)
        ]
        return colors[index % colors.count]
    }

    private func random(_ index: Int, salt: Int) -> CGFloat {
        let raw = sin(Double(index * 12_989 + salt * 78_233)) * 43_758.5453
        return CGFloat(raw - floor(raw))
    }
}
