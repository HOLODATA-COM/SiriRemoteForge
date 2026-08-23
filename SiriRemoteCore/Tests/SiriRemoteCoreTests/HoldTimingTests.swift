import XCTest
@testable import SiriRemoteCore

final class HoldTimingTests: XCTestCase {
    private let stages: [TimeInterval] = [0.5, 1.2]
    private let cancelAt: TimeInterval = 2.2

    func testReleaseBeforeFirstStageIsTap() {
        XCTAssertEqual(HoldTiming.selection(elapsed: 0.499, stageDelays: stages, cancelAt: cancelAt),
                       .tap)
    }

    func testNegativeElapsedTimeIsClampedToTap() {
        XCTAssertEqual(HoldTiming.selection(elapsed: -1, stageDelays: stages, cancelAt: cancelAt),
                       .tap)
    }

    func testStageChangesAtExactVisualThresholds() {
        XCTAssertEqual(HoldTiming.selection(elapsed: 0.5, stageDelays: stages, cancelAt: cancelAt),
                       .stage(index: 0))
        XCTAssertEqual(HoldTiming.selection(elapsed: 1.2, stageDelays: stages, cancelAt: cancelAt),
                       .stage(index: 1))
    }

    func testCancelChangesAtExactVisualThreshold() {
        XCTAssertEqual(HoldTiming.selection(elapsed: 2.199, stageDelays: stages, cancelAt: cancelAt),
                       .stage(index: 1))
        XCTAssertEqual(HoldTiming.selection(elapsed: 2.2, stageDelays: stages, cancelAt: cancelAt),
                       .cancel)
    }

    func testSelectionDoesNotNeedTimerCallbacksToHaveRun() {
        // This is the reported regression: the HUD already shows Cancel from elapsed time while a
        // delayed main-queue callback has not yet recorded it. Wall-clock selection still cancels.
        XCTAssertEqual(HoldTiming.selection(elapsed: 2.7, stageDelays: stages, cancelAt: cancelAt),
                       .cancel)
    }

    func testNoCancelThresholdKeepsDeepestStageSelected() {
        XCTAssertEqual(HoldTiming.selection(elapsed: 20, stageDelays: stages, cancelAt: nil),
                       .stage(index: 1))
    }

    func testEqualThresholdsSelectTheLaterDisplayedStage() {
        XCTAssertEqual(HoldTiming.selection(elapsed: 0.5,
                                            stageDelays: [0.5, 0.5],
                                            cancelAt: nil),
                       .stage(index: 1))
    }

    func testLateVisualTickJumpsStraightToCurrentStage() {
        // A busy main queue can skip every display callback between these two samples. The visual
        // state must resolve directly from elapsed time instead of replaying Close before Quit.
        XCTAssertEqual(HoldTiming.reachedStageCount(elapsed: 0.40,
                                                    stageDelays: [0.5, 1.2, 2.2]), 0)
        XCTAssertEqual(HoldTiming.reachedStageCount(elapsed: 1.35,
                                                    stageDelays: [0.5, 1.2, 2.2]), 2)
    }

    func testReachedStageCountUsesExactSameBoundaryAsReleaseSelection() {
        let delays: [TimeInterval] = [0.5, 1.2, 2.2]
        XCTAssertEqual(HoldTiming.reachedStageCount(elapsed: 0.499, stageDelays: delays), 0)
        XCTAssertEqual(HoldTiming.reachedStageCount(elapsed: 0.5, stageDelays: delays), 1)
        XCTAssertEqual(HoldTiming.reachedStageCount(elapsed: 1.2, stageDelays: delays), 2)
        XCTAssertEqual(HoldTiming.reachedStageCount(elapsed: 2.2, stageDelays: delays), 3)
    }
}
