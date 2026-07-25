import Foundation

/// The action a release-to-select hold should take at one instant.
public enum HoldSelection: Equatable {
    /// Released before the first stage.
    case tap
    /// The zero-based position in the sorted list of bound stages.
    case stage(index: Int)
    /// Released at or beyond the optional cancel threshold.
    case cancel
}

/// Pure, monotonic-elapsed-time-based hold selection.
///
/// The HUD and the input handler both compare elapsed monotonic time with the same thresholds.
/// Action selection must not depend on delayed main-queue timer callbacks: under load those callbacks
/// can arrive after the HUD has already crossed into a new visual state.
public enum HoldTiming {
    /// `stageDelays` must be in the same ascending order shown by the HUD.
    public static func selection(
        elapsed: TimeInterval,
        stageDelays: [TimeInterval],
        cancelAt: TimeInterval?
    ) -> HoldSelection {
        let elapsed = max(elapsed, 0)
        if let cancelAt, elapsed >= cancelAt {
            return .cancel
        }

        var reached: Int?
        for (index, delay) in stageDelays.enumerated() where elapsed >= delay {
            reached = index
        }
        return reached.map { .stage(index: $0) } ?? .tap
    }
}
