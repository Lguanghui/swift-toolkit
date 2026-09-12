//
//  Created by Guanghui Liang on 2026/9/12.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing
import UIKit

@MainActor
struct PaginationViewTests {
    @Test("A drag cannot skip the unread portion of a resource", arguments: [ReadiumNavigator.ReadingProgression.ltr, .rtl])
    func requiresResourceBoundary(progression: ReadiumNavigator.ReadingProgression) async throws {
        let delegate = TestDelegate()
        let view = await makeView(delegate: delegate, progression: progression)
        let page = try #require(view.currentView as? TestPage)
        let forward = CGPoint(x: progression == .ltr ? -1000 : 1000, y: 0)
        let backward = CGPoint(x: -forward.x, y: 0)

        #expect(!view.canBeginDragging(withVelocity: forward))
        #expect(!view.canBeginDragging(withVelocity: backward))
        page.canMoveForward = true
        #expect(view.canBeginDragging(withVelocity: forward))
        #expect(!view.canBeginDragging(withVelocity: backward))
        page.canMoveForward = false
        page.canMoveBackward = true
        #expect(!view.canBeginDragging(withVelocity: forward))
        #expect(view.canBeginDragging(withVelocity: backward))
    }

    @Test("A stale deceleration callback cannot change chapters after returning")
    func ignoresStaleDeceleration() async throws {
        let delegate = TestDelegate()
        let view = await makeView(delegate: delegate)
        let scrollView = try #require(view.subviews.compactMap { $0 as? UIScrollView }.first)
        view.scrollViewWillBeginDragging(scrollView)
        #expect(await view.goToIndex(2, location: .start, options: .init(animated: false)))
        #expect(await view.goToIndex(1, location: .start, options: .init(animated: false)))

        scrollView.contentOffset.x = 640
        view.scrollViewDidEndDecelerating(scrollView)
        #expect(view.currentIndex == 1)
        #expect(scrollView.contentOffset.x == 320)
        view.scrollViewDidEndDecelerating(scrollView)
        #expect(view.currentIndex == 1)

        let page = try #require(view.currentView as? TestPage)
        page.canMoveForward = false
        #expect(!view.canBeginDragging(withVelocity: CGPoint(x: -100, y: 0)))
    }

    @Test("A completed drag changes one resource and is consumed once")
    func completesDragOnce() async throws {
        let delegate = TestDelegate()
        let view = await makeView(delegate: delegate)
        let scrollView = try #require(view.subviews.compactMap { $0 as? UIScrollView }.first)
        view.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset.x = 640
        view.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        #expect(view.currentIndex == 2)

        scrollView.contentOffset.x = 0
        view.scrollViewDidEndDecelerating(scrollView)
        #expect(view.currentIndex == 2)
    }

    @Test("An incomplete drag does not leave an offset for the next ordinary swipe")
    func realignsIncompleteDrag() async throws {
        let delegate = TestDelegate()
        let view = await makeView(delegate: delegate)
        let scrollView = try #require(view.subviews.compactMap { $0 as? UIScrollView }.first)
        view.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset.x = 440
        view.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        #expect(view.currentIndex == 1)
        #expect(scrollView.contentOffset.x == 320)
    }

    private func makeView(delegate: TestDelegate, progression: ReadiumNavigator.ReadingProgression = .ltr) async -> PaginationView {
        let view = PaginationView(frame: CGRect(x: 0, y: 0, width: 320, height: 640), preloadPreviousPositionCount: 0, preloadNextPositionCount: 0, isScrollEnabled: true)
        view.delegate = delegate
        view.reloadAtIndex(1, location: .start, pageCount: 3, readingProgression: progression)
        for _ in 0 ..< 100 where view.currentView == nil {
            await Task.yield()
        }
        view.layoutIfNeeded()
        return view
    }

    private final class TestPage: UIView, PageView {
        var canMoveForward = false
        var canMoveBackward = false

        func canSwipeToAdjacentPage(forward: Bool) -> Bool {
            forward ? canMoveForward : canMoveBackward
        }

        func go(to location: PageLocation, animated: Bool) async {}
    }

    private final class TestDelegate: PaginationViewDelegate {
        func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)? {
            TestPage()
        }

        func paginationViewDidUpdateViews(_ paginationView: PaginationView) {}

        func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int { 1 }
    }
}
