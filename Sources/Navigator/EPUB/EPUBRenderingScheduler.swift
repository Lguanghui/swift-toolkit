//
//  EPUBRenderingScheduler.swift
//  ReadiumNavigator
//
//  Created by Guanghui Liang on 2026/8/24.
//

import Foundation

/// Coordinates visible EPUB rendering and lower-priority background pagination.
@MainActor
final class EPUBRenderingScheduler {
    private var isNavigatorIdle = false
    private var isBackgroundWorkSuspended = false
    private var backgroundWorkResumeDate = Date.distantPast

    func updateNavigatorIdle(_ isIdle: Bool) {
        isNavigatorIdle = isIdle
    }

    func deferBackgroundWork(for interval: TimeInterval) {
        backgroundWorkResumeDate = max(backgroundWorkResumeDate, Date().addingTimeInterval(interval))
    }

    func suspendBackgroundWork() {
        isBackgroundWorkSuspended = true
    }

    func resumeBackgroundWork(after interval: TimeInterval) {
        isBackgroundWorkSuspended = false
        deferBackgroundWork(for: interval)
    }

    func waitUntilBackgroundWorkIsAllowed() async throws {
        while true {
            try Task.checkCancellation()
            let remaining = backgroundWorkResumeDate.timeIntervalSinceNow
            if isNavigatorIdle, !isBackgroundWorkSuspended, remaining <= 0 {
                return
            }

            let delay = remaining > 0 ? min(0.1, remaining) : 0.05
            try await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
        }
    }
}
