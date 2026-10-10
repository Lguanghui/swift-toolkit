//
//  EPUBPublisherColorPolicyTests.swift
//  ReadiumNavigatorTests
//
//  Created by Guanghui Liang on 2026/10/10.
//

import ReadiumNavigator
import ReadiumShared
import Testing

@MainActor
struct EPUBPublisherColorPolicyTests {
    @Test
    func supportsReflowableResourcesInFixedLayoutPublication() {
        var properties = Properties()
        properties.epubLayout = .reflowable
        let publication = Publication(manifest: Manifest(
            metadata: Metadata(title: "Mixed", layout: .fixed),
            readingOrder: [Link(href: "chapter.xhtml", mediaType: .xhtml, properties: properties)]
        ))
        let editor = EPUBPreferencesEditor(initialPreferences: .empty, publication: publication, defaults: EPUBDefaults())

        #expect(editor.publisherColorPolicy.isEffective)
        editor.publisherColorPolicy.set(.preserve)
        #expect(editor.preferences.publisherColorPolicy == .preserve)
    }

    @Test
    func ignoresFixedResourcesInReflowablePublication() {
        var properties = Properties()
        properties.epubLayout = .fixed
        let publication = Publication(manifest: Manifest(
            metadata: Metadata(title: "Fixed resources"),
            readingOrder: [Link(href: "page.xhtml", mediaType: .xhtml, properties: properties)]
        ))
        let editor = EPUBPreferencesEditor(initialPreferences: .empty, publication: publication, defaults: EPUBDefaults())

        #expect(!editor.publisherColorPolicy.isEffective)
    }

    @Test
    func usesRenderedReadingOrder() {
        let publication = Publication(manifest: Manifest(
            metadata: Metadata(title: "Bitmap fallback"),
            readingOrder: [Link(href: "page.xhtml", mediaType: .xhtml)]
        ))
        let editor = EPUBPreferencesEditor(
            initialPreferences: .empty,
            publication: publication,
            readingOrder: [Link(href: "page.jpg", mediaType: .jpeg)],
            defaults: EPUBDefaults()
        )

        #expect(!editor.publisherColorPolicy.isEffective)
    }
}
