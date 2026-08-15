//
//  ReaderHTMLWebView.swift
//  flux
//
//  Created by Codex on 2026/8/15.
//

import SwiftUI
import WebKit

enum ReaderTextScale {
    static let minimum = 0.85
    static let maximum = 1.40
    static let defaultValue = 1.0
    static let step = 0.10

    static func clamped(_ value: Double) -> Double {
        min(maximum, max(minimum, value))
    }

    static func smaller(than value: Double) -> Double {
        clamped(value - step)
    }

    static func larger(than value: Double) -> Double {
        clamped(value + step)
    }
}

enum ReaderNavigationDestination: Equatable {
    case document
    case external
    case unsupported
}

enum ReaderNavigationPolicy {
    static func destination(
        for url: URL?,
        navigationType: WKNavigationType
    ) -> ReaderNavigationDestination {
        guard let url, let scheme = url.scheme?.lowercased() else {
            return .unsupported
        }

        if scheme == "about" {
            return .document
        }
        guard navigationType == .linkActivated else {
            return .unsupported
        }
        switch scheme {
        case "http", "https", "mailto", "tel":
            return .external
        default:
            return .unsupported
        }
    }
}

struct ArticleReaderDocument: Equatable {
    let html: String

    init(
        content: ArticleContent,
        fallbackTitle: String,
        fallbackSiteName: String?,
        fallbackPublishedAt: Date,
        textScale: Double
    ) {
        let title = Self.preferred(content.title, fallback: fallbackTitle)
        let siteName = Self.nonempty(content.siteName) ?? Self.nonempty(fallbackSiteName)
        var metadata: [String] = []
        if let byline = Self.nonempty(content.byline) {
            metadata.append(byline)
        }
        if let siteName {
            metadata.append(siteName)
        }
        metadata.append(Self.displayDate(content.publishedTime, fallback: fallbackPublishedAt))

        let safeTitle = Self.escape(title)
        let safeMetadata = metadata.map(Self.escape).joined(separator: " <span aria-hidden=\"true\">•</span> ")
        let language = Self.safeLanguage(content.language)
        let direction = Self.safeDirection(content.direction)
        let fontSize = 18 * ReaderTextScale.clamped(textScale)
        let formattedFontSize = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), fontSize)

        html = #"""
        <!doctype html>
        <html lang="\#(language)" dir="\#(direction)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta name="referrer" content="no-referrer">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline'; media-src 'none'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
          <style>
            :root {
              color-scheme: light dark;
              --background: #ffffff;
              --text: #171717;
              --secondary: #66666b;
              --accent: #0a66c2;
              --surface: #f3f3f5;
              --border: #d9d9de;
              --quote: #8a8a90;
              --font-size: \#(formattedFontSize)px;
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --background: #000000;
                --text: #f2f2f2;
                --secondary: #a1a1a8;
                --accent: #6eaeff;
                --surface: #1c1c1e;
                --border: #3a3a3c;
                --quote: #85858c;
              }
            }
            * { box-sizing: border-box; }
            html, body { margin: 0; padding: 0; background: var(--background); color: var(--text); }
            body { -webkit-text-size-adjust: 100%; overflow-wrap: anywhere; }
            .reader {
              width: min(100%, 720px);
              margin: 0 auto;
              padding: 30px 22px 72px;
            }
            .reader-title {
              margin: 0 0 12px;
              font: 750 clamp(30px, 7vw, 46px)/1.12 -apple-system, BlinkMacSystemFont, sans-serif;
              letter-spacing: -0.025em;
            }
            .reader-metadata {
              margin: 0 0 34px;
              color: var(--secondary);
              font: 500 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif;
            }
            .reader-content {
              font: 400 var(--font-size)/1.68 ui-serif, Georgia, serif;
              text-rendering: optimizeLegibility;
            }
            .reader-content p, .reader-content ul, .reader-content ol, .reader-content dl,
            .reader-content blockquote, .reader-content pre, .reader-content figure,
            .reader-content table, .reader-content details { margin: 0 0 1.35em; }
            .reader-content h1, .reader-content h2, .reader-content h3,
            .reader-content h4, .reader-content h5, .reader-content h6 {
              margin: 1.65em 0 0.6em;
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
              line-height: 1.22;
              letter-spacing: -0.015em;
            }
            .reader-content h1 { font-size: 1.75em; }
            .reader-content h2 { font-size: 1.48em; }
            .reader-content h3 { font-size: 1.25em; }
            .reader-content h4, .reader-content h5, .reader-content h6 { font-size: 1.08em; }
            .reader-content a { color: var(--accent); text-decoration-thickness: 0.08em; text-underline-offset: 0.15em; }
            .reader-content img { display: block; max-width: 100%; height: auto; margin: 0 auto; border-radius: 8px; }
            .reader-content figure { margin-left: 0; margin-right: 0; }
            .reader-content figcaption { margin-top: 0.6em; color: var(--secondary); font: 400 0.78em/1.45 -apple-system, BlinkMacSystemFont, sans-serif; text-align: center; }
            .reader-content blockquote { margin-left: 0; padding: 0.15em 0 0.15em 1.15em; border-left: 4px solid var(--quote); color: var(--secondary); }
            .reader-content pre { overflow-x: auto; padding: 16px; border-radius: 10px; background: var(--surface); border: 1px solid var(--border); line-height: 1.5; }
            .reader-content code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.86em; }
            .reader-content :not(pre) > code { padding: 0.12em 0.28em; border-radius: 4px; background: var(--surface); }
            .reader-content ul, .reader-content ol { padding-left: 1.35em; }
            .reader-content li { margin: 0.4em 0; }
            .reader-content table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 0.86em; }
            .reader-content th, .reader-content td { padding: 9px 12px; border: 1px solid var(--border); text-align: start; vertical-align: top; }
            .reader-content th { background: var(--surface); font-weight: 650; }
            .reader-content hr { margin: 2.2em 0; border: 0; border-top: 1px solid var(--border); }
            .reader-content details { padding: 12px 14px; border: 1px solid var(--border); border-radius: 8px; }
            .reader-content summary { cursor: pointer; font-weight: 650; }
            @media (max-width: 480px) {
              .reader { padding-left: 19px; padding-right: 19px; }
              .reader-metadata { margin-bottom: 28px; }
            }
          </style>
        </head>
        <body>
          <main class="reader">
            <header>
              <h1 class="reader-title">\#(safeTitle)</h1>
              <p class="reader-metadata">\#(safeMetadata)</p>
            </header>
            <article class="reader-content">\#(content.contentHTML)</article>
          </main>
        </body>
        </html>
        """#
    }

    private static func preferred(_ value: String?, fallback: String?) -> String {
        nonempty(value) ?? nonempty(fallback) ?? "Untitled Article"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func displayDate(_ value: String?, fallback: Date) -> String {
        if let value = nonempty(value),
           let parsed = ISO8601DateFormatter().date(from: value) {
            return parsed.formatted(date: .long, time: .omitted)
        }
        return fallback.formatted(date: .long, time: .omitted)
    }

    private static func safeLanguage(_ value: String?) -> String {
        guard let value = nonempty(value),
              value.range(of: #"^[A-Za-z0-9-]{1,35}$"#, options: .regularExpression) != nil else {
            return "en"
        }
        return value
    }

    private static func safeDirection(_ value: String?) -> String {
        switch nonempty(value)?.lowercased() {
        case "ltr": "ltr"
        case "rtl": "rtl"
        default: "auto"
        }
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

struct ReaderHTMLWebView: UIViewRepresentable {
    let document: ArticleReaderDocument
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenURL: onOpenURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.load(document, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.load(document, in: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onOpenURL: (URL) -> Void
        private var loadedDocument: ArticleReaderDocument?

        init(onOpenURL: @escaping (URL) -> Void) {
            self.onOpenURL = onOpenURL
        }

        func load(_ document: ArticleReaderDocument, in webView: WKWebView) {
            guard loadedDocument != document else { return }
            loadedDocument = document
            webView.loadHTMLString(document.html, baseURL: nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            switch ReaderNavigationPolicy.destination(
                for: navigationAction.request.url,
                navigationType: navigationAction.navigationType
            ) {
            case .document:
                return .allow
            case .external:
                if let url = navigationAction.request.url {
                    onOpenURL(url)
                }
                return .cancel
            case .unsupported:
                return .cancel
            }
        }
    }
}
