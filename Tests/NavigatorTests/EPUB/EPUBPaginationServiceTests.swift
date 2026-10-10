//
//  EPUBPaginationServiceTests.swift
//  ReadiumNavigatorTests
//
//  Created by Guanghui Liang on 2026/10/10.
//

@testable import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit
import XCTest

final class EPUBPaginationServiceTests: XCTestCase {
    @MainActor
    func testMeasuresPercentEncodedTableOfContentsAnchor() async throws {
        let loaded = expectation(description: "HTML loaded")
        let delegate = NavigationDelegate(loaded: loaded)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        webView.navigationDelegate = delegate
        webView.loadHTMLString("""
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html, body { margin: 0; width: 320px; height: 960px; }
        section { position: absolute; top: 480px; }</style></head>
        <body><section id="章节 2">Chapter two</section></body></html>
        """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)

        let link = Link(href: "chapter.xhtml#%E7%AB%A0%E8%8A%82%202")
        let result = try await EPUBPaginationService.measure(in: webView, resolving: [link, Link(href: "chapter.xhtml")])

        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.progressions[link.href], 0.5)
        XCTAssertNil(result.progressions["chapter.xhtml"])
    }

    @MainActor
    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        let loaded: XCTestExpectation

        init(loaded: XCTestExpectation) {
            self.loaded = loaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded.fulfill()
        }
    }
}
