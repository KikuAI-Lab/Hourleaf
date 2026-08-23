import CoreHaptics
import UIKit

/// Plays a brief selection confirmation through the platform haptic engine.
/// A fresh lightweight player keeps independent controls from interrupting
/// each other's feedback.
@MainActor
final class SelectionHapticFeedback {
    private let supportsCoreHaptics: Bool
    private let pattern: CHHapticPattern?
    private let fallback = UIImpactFeedbackGenerator(style: .light)
    private var engine: CHHapticEngine?

    init() {
        supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        pattern = try? Self.makePattern()
    }

    func prepare() {
        guard supportsCoreHaptics, pattern != nil else {
            fallback.prepare()
            return
        }
        try? ensureEngineIsRunning()
    }

    func play() {
        guard supportsCoreHaptics, pattern != nil else {
            fallback.impactOccurred(intensity: 0.6)
            fallback.prepare()
            return
        }

        do {
            try playCoreHaptic()
        } catch {
            invalidateEngine()
            try? playCoreHaptic()
        }
    }

    private func playCoreHaptic() throws {
        try ensureEngineIsRunning()
        guard let engine, let pattern else { return }
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: CHHapticTimeImmediate)
    }

    private func ensureEngineIsRunning() throws {
        if let engine {
            try engine.start()
            return
        }

        let engine = try CHHapticEngine()
        engine.isAutoShutdownEnabled = true
        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.invalidateEngine() }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in
                self?.invalidateEngine()
                self?.prepare()
            }
        }
        try engine.start()
        self.engine = engine
    }

    private func invalidateEngine() {
        engine = nil
    }

    private static func makePattern() throws -> CHHapticPattern {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45)
            ],
            relativeTime: 0
        )
        return try CHHapticPattern(events: [event], parameters: [])
    }
}
