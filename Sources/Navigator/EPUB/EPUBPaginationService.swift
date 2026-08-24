//
//  EPUBPaginationService.swift
//  ReadiumNavigator
//
//  Created by Guanghui Liang on 2026/8/23.
//

import ReadiumShared
import UIKit
import WebKit

/// Renders reflowable EPUB resources in an isolated web view to determine
/// their visual page count for a given viewport and set of preferences.
///
/// The service owns a dedicated, non-persistent web view and reuses the
/// navigator's resource server and Readium CSS injection pipeline. Resources
/// are rendered sequentially without creating or attaching a second navigator.
@MainActor
public final class EPUBPaginationService: NSObject {
    public struct Configuration {
        public var preferences: EPUBPreferences
        public var viewportSize: CGSize
        public var contentInset: UIEdgeInsets
        public var fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration]
        public var readiumCSSRSProperties: CSSRSProperties

        public init(
            preferences: EPUBPreferences = .empty,
            viewportSize: CGSize,
            contentInset: UIEdgeInsets = .zero,
            fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration] = [],
            readiumCSSRSProperties: CSSRSProperties = CSSRSProperties()
        ) {
            self.preferences = preferences
            self.viewportSize = viewportSize
            self.contentInset = contentInset
            self.fontFamilyDeclarations = fontFamilyDeclarations
            self.readiumCSSRSProperties = readiumCSSRSProperties
        }
    }

    public struct Result: Equatable, Sendable {
        public let pageCount: Int
        public let progressions: [String: Double]

        public init(pageCount: Int, progressions: [String: Double] = [:]) {
            self.pageCount = pageCount
            self.progressions = progressions
        }
    }

    public enum PaginationError: Error, Sendable {
        case publicationRestricted
        case invalidViewport
        case resourceLoadFailed
        case resourceMeasurementFailed
        case interrupted
    }

    private struct PendingNavigation {
        let generation: Int
        let targetURL: URL
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let viewModel: EPUBNavigatorViewModel
    private let webView: WKWebView
    private var pendingNavigation: PendingNavigation?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var generation = 0
    private var isPaginating = false

    public convenience init(publication: Publication, configuration: Configuration) throws {
        guard !publication.isRestricted else { throw PaginationError.publicationRestricted }

        let navigatorConfiguration = EPUBNavigatorViewController.Configuration(
            preferences: configuration.preferences,
            editingActions: [],
            contentInset: [
                .compact: (top: configuration.contentInset.top, bottom: configuration.contentInset.bottom),
                .regular: (top: configuration.contentInset.top, bottom: configuration.contentInset.bottom),
            ],
            preloadPreviousPositionCount: 0,
            preloadNextPositionCount: 0,
            fontFamilyDeclarations: configuration.fontFamilyDeclarations,
            readiumCSSRSProperties: configuration.readiumCSSRSProperties
        )
        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: publication.readingOrder,
            config: navigatorConfiguration
        )
        viewModel.viewSizeWillChange(configuration.viewportSize)

        try self.init(viewModel: viewModel, viewportSize: configuration.viewportSize, contentInset: configuration.contentInset)
    }

    init(viewModel: EPUBNavigatorViewModel, viewportSize: CGSize, contentInset: UIEdgeInsets) throws {
        let contentSize = CGSize(width: viewportSize.width, height: viewportSize.height - contentInset.top - contentInset.bottom)
        guard contentSize.width > 0, contentSize.height > 0 else { throw PaginationError.invalidViewport }

        viewModel.viewSizeWillChange(viewportSize)
        self.viewModel = viewModel

        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.websiteDataStore = .nonPersistent()
        webViewConfiguration.mediaTypesRequiringUserActionForPlayback = .all
        webViewConfiguration.suppressesIncrementalRendering = true
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = false
        webViewConfiguration.setURLSchemeHandler(viewModel.server, forURLScheme: viewModel.server.scheme)

        webView = WKWebView(frame: CGRect(origin: .zero, size: contentSize), configuration: webViewConfiguration)
        super.init()

        viewModel.server.registerBackgroundWebView(webView)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.isPagingEnabled = true
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }

    isolated deinit {
        navigationTimeoutTask?.cancel()
        viewModel.server.unregisterBackgroundWebView(webView)
    }

    /// Renders one reading-order resource and returns its visual page count.
    ///
    /// `links` may contain fragment links in the resource, such as table of
    /// contents entries. Their visual progressions are returned by `href`.
    public func paginate(_ link: Link, resolving links: [Link] = []) async throws -> Result {
        try await viewModel.renderingScheduler.waitUntilBackgroundWorkIsAllowed()
        let targetURL = viewModel.url(to: link).url

        isPaginating = true
        defer { isPaginating = false }
        let generation = generation

        if !matches(webView.url, targetURL) {
            try await load(targetURL, generation: generation)
        }
        guard generation == self.generation else { throw PaginationError.interrupted }

        let result = try await Self.measure(in: webView, resolving: links)
        guard generation == self.generation else { throw PaginationError.interrupted }
        return result
    }

    static func measure(in webView: WKWebView, resolving links: [Link]) async throws -> Result {
        let anchors = links.compactMap { link -> [String: String]? in
            guard let fragment = link.url().fragment, !fragment.isEmpty else { return nil }
            return ["href": link.href, "fragment": fragment]
        }
        let value = try await webView.callAsyncJavaScript(
            measurementScript,
            arguments: ["anchors": anchors],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let value = value as? [String: Any], let pageCount = (value["pageCount"] as? NSNumber)?.intValue, pageCount > 0 else {
            throw PaginationError.resourceMeasurementFailed
        }

        let progressions = (value["progressions"] as? [String: Any])?.reduce(into: [String: Double]()) { result, item in
            guard let progression = (item.value as? NSNumber)?.doubleValue else { return }
            result[item.key] = min(max(progression, 0), 1)
        } ?? [:]
        return Result(pageCount: pageCount, progressions: progressions)
    }

    /// Interrupts the active resource load or measurement. The service can be
    /// reused for another call to `paginate(_:resolving:)` afterwards.
    public func interrupt() {
        guard isPaginating || pendingNavigation != nil else { return }
        generation += 1
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        resumePendingNavigation(throwing: PaginationError.interrupted)
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func load(_ targetURL: URL, generation: Int) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingNavigation = PendingNavigation(generation: generation, targetURL: targetURL, continuation: continuation)
                webView.load(URLRequest(url: targetURL))
                navigationTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard let self, self.pendingNavigation?.generation == generation else { return }
                    self.resumePendingNavigation(throwing: PaginationError.resourceLoadFailed)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.interrupt() }
        }
    }

    private func resumePendingNavigation(throwing error: (any Error)? = nil) {
        guard let pendingNavigation else { return }
        self.pendingNavigation = nil
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        if let error {
            pendingNavigation.continuation.resume(throwing: error)
        } else {
            pendingNavigation.continuation.resume()
        }
    }

    private func matches(_ loadedURL: URL?, _ targetURL: URL) -> Bool {
        guard let loadedURL else { return false }
        var loadedComponents = URLComponents(url: loadedURL, resolvingAgainstBaseURL: false)
        var targetComponents = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)
        loadedComponents?.fragment = nil
        targetComponents?.fragment = nil
        return loadedComponents?.url == targetComponents?.url
    }

    private static let measurementScript = """
    const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
    const nextLayout = () => Promise.race([
        new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
        sleep(50),
    ]);
    const metrics = () => {
        const root = document.scrollingElement;
        if (!root || window.innerWidth <= 0 || window.innerHeight <= 0) return null;

        const horizontal = root.scrollWidth > window.innerWidth + 1;
        const viewportLength = horizontal ? window.innerWidth : window.innerHeight;
        const contentLength = horizontal ? root.scrollWidth : root.scrollHeight;
        if (viewportLength <= 0 || contentLength <= 0) return null;
        return { horizontal, viewportLength, pageCount: Math.max(1, Math.round(contentLength / viewportLength)) };
    };

    let measured = null;
    let stableSampleCount = 0;
    for (let attempt = 0; attempt < 12; attempt++) {
        await nextLayout();
        const sample = metrics();
        if (sample && measured && sample.pageCount === measured.pageCount && sample.horizontal === measured.horizontal) {
            stableSampleCount += 1;
        } else {
            measured = sample;
            stableSampleCount = sample ? 1 : 0;
        }

        const fontsReady = !document.fonts || document.fonts.status !== "loading";
        if (stableSampleCount >= 2 && fontsReady) break;
        await sleep(25);
    }
    if (!measured || measured.pageCount <= 0) return null;

    const progressions = {};
    for (const anchor of anchors) {
        const candidates = [anchor.fragment];
        try {
            const decoded = decodeURIComponent(anchor.fragment);
            if (decoded !== anchor.fragment) candidates.push(decoded);
        } catch (_) {}

        let element = null;
        for (const candidate of candidates) {
            element = document.getElementById(candidate) || document.getElementsByName(candidate)[0];
            if (element) break;
        }
        if (!element) continue;

        const rect = element.getBoundingClientRect();
        const offset = measured.horizontal ? Math.abs(rect.left + window.scrollX) : Math.abs(rect.top + window.scrollY);
        const pageOffset = Math.min(measured.pageCount - 1, Math.max(0, Math.floor(offset / measured.viewportLength)));
        progressions[anchor.href] = pageOffset / measured.pageCount;
    }
    return { pageCount: measured.pageCount, progressions };
    """
}

extension EPUBPaginationService: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let pendingNavigation, pendingNavigation.generation == generation, matches(webView.url, pendingNavigation.targetURL) else { return }
        resumePendingNavigation()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        resumePendingNavigation(throwing: error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        resumePendingNavigation(throwing: error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        generation += 1
        resumePendingNavigation(throwing: PaginationError.resourceLoadFailed)
    }
}
