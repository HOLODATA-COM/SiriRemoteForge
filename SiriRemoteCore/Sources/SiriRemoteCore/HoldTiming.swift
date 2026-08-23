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
    /// Number of visible thresholds reached at `elapsed`. Stage 0 is the base/tap face, stage 1 is
    /// the first hold face, and so on. Keeping this as a pure elapsed-time calculation lets every UI
    /// render the current state directly; it never has to replay timer callbacks that arrived late.
    public static func reachedStageCount(
        elapsed: TimeInterval,
        stageDelays: [TimeInterval]
    ) -> Int {
        let elapsed = max(elapsed, 0)
        return stageDelays.reduce(into: 0) { count, delay in
            if elapsed >= delay { count += 1 }
        }
    }

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

        let reachedCount = reachedStageCount(elapsed: elapsed, stageDelays: stageDelays)
        return reachedCount > 0 ? .stage(index: reachedCount - 1) : .tap
    }
}
