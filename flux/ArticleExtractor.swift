//
//  ArticleExtractor.swift
//  flux
//
//  Created by Codex on 2026/8/15.
//

import Foundation
import WebKit

protocol ArticleExtracting: Sendable {
    func extract(from url: URL) async throws -> ArticleContent
}

struct ArticleExtractionConfiguration: Sendable {
    var totalTimeout: Duration = .seconds(20)
    var readinessTimeout: Duration = .seconds(3)
    var readinessPollInterval: Duration = .milliseconds(250)
    var minimumBodyLength = 500
    var minimumArticleLength = 200

    static let live = ArticleExtractionConfiguration()
}

struct ArticleExtractor: ArticleExtracting, Sendable {
    private let configuration: ArticleExtractionConfiguration

    init(configuration: ArticleExtractionConfiguration = .live) {
        self.configuration = configuration
    }

    func extract(from url: URL) async throws -> ArticleContent {
        guard !url.absoluteString.isEmpty, url.host != nil else {
            throw ArticleExtractionError.invalidURL
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ArticleExtractionError.unsupportedScheme
        }

        return try await extract(source: .url(url))
    }

    func extract(html: String, baseURL: URL) async throws -> ArticleContent {
        try await extract(source: .html(html, baseURL: baseURL))
    }

    private func extract(source: ArticleExtractionSource) async throws -> ArticleContent {
        try Task.checkCancellation()
        let scripts = try ArticleExtractionScripts.loadBundled()
        let data = try await ArticleWebExtractionSession.extract(
            source: source,
            scripts: scripts,
            configuration: configuration
        )

        let envelope: ArticleExtractionEnvelope
        do {
            envelope = try JSONDecoder().decode(ArticleExtractionEnvelope.self, from: data)
        } catch {
            throw ArticleExtractionError.javaScriptFailed(
                "The extraction result could not be decoded: \(error.localizedDescription)"
            )
        }

        if let article = envelope.article {
            return article
        }

        guard let failure = envelope.failure else {
            throw ArticleExtractionError.readabilityReturnedNil
        }

        switch failure.kind {
        case "blocked":
            throw ArticleExtractionError.blocked
        case "paywalled":
            throw ArticleExtractionError.paywalled
        case "insufficient":
            throw ArticleExtractionError.insufficientContent(failure.length ?? 0)
        default:
            throw ArticleExtractionError.readabilityReturnedNil
        }
    }
}

private enum ArticleExtractionSource: Sendable {
    case url(URL)
    case html(String, baseURL: URL)
}

private struct ArticleExtractionScripts: Sendable {
    let readability: String
    let domPurify: String

    static func loadBundled() throws -> ArticleExtractionScripts {
        ArticleExtractionScripts(
            readability: try loadResource(named: "Readability", extension: "js"),
            domPurify: try loadResource(named: "DOMPurify.min", extension: "js")
        )
    }

    private static func loadResource(named name: String, extension fileExtension: String) throws -> String {
        let bundles = [Bundle.main, Bundle(for: ArticleExtractionBundleToken.self)]
        let subdirectories: [String?] = [
            "ArticleExtraction",
            "Resources/ArticleExtraction",
            nil,
        ]

        for bundle in bundles {
            for subdirectory in subdirectories {
                if let url = bundle.url(
                    forResource: name,
                    withExtension: fileExtension,
                    subdirectory: subdirectory
                ), let source = try? String(contentsOf: url, encoding: .utf8) {
                    return source
                }
            }
        }

        throw ArticleExtractionError.missingScriptResource("\(name).\(fileExtension)")
    }
}

private final class ArticleExtractionBundleToken: NSObject {}

private struct ArticleExtractionEnvelope: Decodable {
    struct Failure: Decodable {
        let kind: String
        let length: Int?
    }

    let article: ArticleContent?
    let failure: Failure?
}

private struct ArticleDOMProbe: Decodable {
    let readyState: String
    let bodyLength: Int
    let articleLength: Int
}

@MainActor
private final class ArticleWebExtractionSession: NSObject, WKNavigationDelegate {
    private let source: ArticleExtractionSource
    private let scripts: ArticleExtractionScripts
    private let configuration: ArticleExtractionConfiguration
    private let extractionWorld = WKContentWorld.world(name: "FluxArticleExtraction")

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var navigationGeneration = 0

    private init(
        source: ArticleExtractionSource,
        scripts: ArticleExtractionScripts,
        configuration: ArticleExtractionConfiguration
    ) {
        self.source = source
        self.scripts = scripts
        self.configuration = configuration
        super.init()

        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.navigationDelegate = self
        self.webView = webView
    }

    static func extract(
        source: ArticleExtractionSource,
        scripts: ArticleExtractionScripts,
        configuration: ArticleExtractionConfiguration
    ) async throws -> Data {
        let session = ArticleWebExtractionSession(
            source: source,
            scripts: scripts,
            configuration: configuration
        )
        return try await withTaskCancellationHandler {
            try await session.start()
        } onCancel: {
            Task { @MainActor in
                session.cancel()
            }
        }
    }

    private func start() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            guard !Task.isCancelled else {
                cancel()
                return
            }

            timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: configuration.totalTimeout)
                    try Task.checkCancellation()
                    finish(.failure(ArticleExtractionError.timedOut))
                } catch {
                    // Finishing or caller cancellation intentionally cancels the timer.
                }
            }

            guard let webView else {
                finish(.failure(ArticleExtractionError.navigationFailed(
                    code: nil,
                    message: "The article web view could not be created."
                )))
                return
            }

            switch source {
            case .url(let url):
                webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData))
            case .html(let html, let baseURL):
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            return .cancel
        }

        if scheme == "http" || scheme == "https" {
            return .allow
        }
        if case .html = source, scheme == "about" || scheme == "file" {
            return .allow
        }
        return .cancel
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse else {
            return .allow
        }

        switch response.statusCode {
        case 200 ... 399:
            return .allow
        case 401, 402:
            finish(.failure(ArticleExtractionError.paywalled))
        case 403, 429, 451:
            finish(.failure(ArticleExtractionError.blocked))
        default:
            finish(.failure(ArticleExtractionError.httpStatus(response.statusCode)))
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationGeneration &+= 1
        let generation = navigationGeneration
        readinessTask?.cancel()
        readinessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await waitForReadinessAndExtract()
                guard generation == navigationGeneration else { return }
                finish(.success(data))
            } catch is CancellationError {
                guard generation == navigationGeneration, continuation != nil else { return }
                finish(.failure(CancellationError()))
            } catch {
                guard generation == navigationGeneration else { return }
                finish(.failure(error))
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        reportNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        reportNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(ArticleExtractionError.navigationFailed(
            code: nil,
            message: "The webpage content process stopped responding."
        )))
    }

    private func reportNavigationFailure(_ error: any Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }
        finish(.failure(ArticleExtractionError.navigationFailed(
            code: nsError.code,
            message: error.localizedDescription
        )))
    }

    private func waitForReadinessAndExtract() async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.readinessTimeout)
        var previousBodyLength: Int?
        var stableSamples = 0

        while clock.now < deadline {
            try Task.checkCancellation()
            let probe = try await readDOMProbe()
            let isReady = probe.readyState == "interactive" || probe.readyState == "complete"
            let isPlausible = probe.bodyLength >= configuration.minimumBodyLength
                || probe.articleLength >= configuration.minimumArticleLength

            if isReady, isPlausible, let previousBodyLength {
                let tolerance = max(100, previousBodyLength / 20)
                if abs(probe.bodyLength - previousBodyLength) <= tolerance {
                    stableSamples += 1
                } else {
                    stableSamples = 0
                }
                if stableSamples >= 2 {
                    break
                }
            } else {
                stableSamples = 0
            }

            previousBodyLength = probe.bodyLength
            try await Task.sleep(for: configuration.readinessPollInterval)
        }

        return try await executeExtraction()
    }

    private func readDOMProbe() async throws -> ArticleDOMProbe {
        guard let webView else { throw CancellationError() }
        let script = #"""
        (() => JSON.stringify({
          readyState: document.readyState,
          bodyLength: (document.body?.innerText || "").trim().length,
          articleLength: Array.from(document.querySelectorAll("article, main"))
            .reduce((length, element) => Math.max(length, (element.innerText || "").trim().length), 0)
        }))()
        """#

        do {
            guard let json = try await webView.evaluateJavaScript(
                script,
                in: nil,
                contentWorld: extractionWorld
            ) as? String else {
                throw ArticleExtractionError.javaScriptFailed("The DOM readiness probe returned no result.")
            }
            return try JSONDecoder().decode(ArticleDOMProbe.self, from: Data(json.utf8))
        } catch let error as ArticleExtractionError {
            throw error
        } catch {
            throw ArticleExtractionError.javaScriptFailed(error.localizedDescription)
        }
    }

    private func executeExtraction() async throws -> Data {
        guard let webView else { throw CancellationError() }

        do {
            _ = try await webView.evaluateJavaScript(
                scripts.readability,
                in: nil,
                contentWorld: extractionWorld
            )
            _ = try await webView.evaluateJavaScript(
                scripts.domPurify,
                in: nil,
                contentWorld: extractionWorld
            )
            guard let json = try await webView.evaluateJavaScript(
                Self.extractionJavaScript,
                in: nil,
                contentWorld: extractionWorld
            ) as? String else {
                throw ArticleExtractionError.javaScriptFailed("Reader Mode returned no result.")
            }
            return Data(json.utf8)
        } catch let error as ArticleExtractionError {
            throw error
        } catch {
            throw ArticleExtractionError.javaScriptFailed(error.localizedDescription)
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }

    private static let extractionJavaScript = #"""
    (() => {
      "use strict";

      const normalize = (value, limit = 2000) => {
        if (value === null || value === undefined) return null;
        const string = String(value).replace(/\s+/g, " ").trim();
        return string ? string.slice(0, limit) : null;
      };

      const meta = (...selectors) => {
        for (const selector of selectors) {
          const value = normalize(document.querySelector(selector)?.getAttribute("content"));
          if (value) return value;
        }
        return null;
      };

      const collectedJSONLD = [];
      const collectObjects = value => {
        if (Array.isArray(value)) {
          value.forEach(collectObjects);
          return;
        }
        if (!value || typeof value !== "object") return;
        collectedJSONLD.push(value);
        if (value["@graph"]) collectObjects(value["@graph"]);
      };

      document.querySelectorAll('script[type="application/ld+json"]').forEach(script => {
        try { collectObjects(JSON.parse(script.textContent)); } catch (_) {}
      });

      const articleTypes = new Set(["Article", "NewsArticle", "BlogPosting"]);
      const structured = collectedJSONLD.find(value => {
        const types = Array.isArray(value["@type"]) ? value["@type"] : [value["@type"]];
        return types.some(type => {
          const normalizedType = String(type).split(/[\\/#]/).pop();
          return articleTypes.has(normalizedType);
        });
      }) || null;

      const personName = value => {
        if (Array.isArray(value)) {
          return normalize(value.map(personName).filter(Boolean).join(", "), 500);
        }
        if (value && typeof value === "object") return normalize(value.name, 500);
        return normalize(value, 500);
      };

      const structuredMetadata = {
        title: normalize(structured?.headline || structured?.name, 500),
        byline: personName(structured?.author),
        siteName: normalize(structured?.publisher?.name, 500),
        excerpt: normalize(structured?.description),
        publishedTime: normalize(structured?.datePublished || structured?.dateModified, 200)
      };

      const openGraphMetadata = {
        title: meta('meta[property="og:title"]', 'meta[name="twitter:title"]'),
        byline: meta('meta[name="author"]', 'meta[property="article:author"]'),
        siteName: meta('meta[property="og:site_name"]'),
        excerpt: meta('meta[property="og:description"]', 'meta[name="description"]'),
        publishedTime: meta('meta[property="article:published_time"]', 'meta[name="date"]')
      };

      const classifyPage = () => {
        const text = (document.body?.innerText || "").replace(/\s+/g, " ").slice(0, 50000);
        if (/(subscribe (to|in order to) (continue|read)|sign in (to|in order to) (continue|read)|already a subscriber|members only|premium content|login required)/i.test(text)) {
          return "paywalled";
        }
        if (/(verify (that )?you are human|access denied|captcha|unusual traffic|checking your browser|bot (detection|protection)|enable javascript and cookies)/i.test(text)) {
          return "blocked";
        }
        return "unreadable";
      };

      const chromePattern = /(^|[\s_-])(ad|ads|advert|advertisement|banner|cookie|comment|comments|newsletter|promo|recommendation|recommendations|recommended|related|share|sharing|social|signup|subscribe)([\s_-]|$)/i;

      const readabilityDocument = document.cloneNode(true);
      readabilityDocument.querySelectorAll(
        'script, style, noscript, form, input, button, select, textarea, iframe, frame, embed, object, nav, aside, [role="navigation"], [role="banner"], [role="dialog"], [aria-modal="true"]'
      ).forEach(node => node.remove());
      readabilityDocument.querySelectorAll("*").forEach(node => {
        const marker = [node.id, node.className, node.getAttribute("aria-label")]
          .filter(value => typeof value === "string")
          .join(" ");
        if (marker && chromePattern.test(marker)) {
          node.remove();
          return;
        }
        node.removeAttribute("style");
        node.removeAttribute("hidden");
        Array.from(node.attributes).forEach(attribute => {
          if (/^on/i.test(attribute.name)) node.removeAttribute(attribute.name);
        });
      });

      if (typeof Readability !== "function" || typeof DOMPurify?.sanitize !== "function") {
        throw new Error("Bundled extraction libraries did not initialize.");
      }

      const article = new Readability(readabilityDocument, { keepClasses: true }).parse();
      if (!article || !article.content) {
        return JSON.stringify({ article: null, failure: { kind: classifyPage(), length: 0 } });
      }

      const template = document.createElement("template");
      template.innerHTML = article.content;
      const root = template.content;

      root.querySelectorAll('nav, aside, form, [role="navigation"], [role="banner"], [role="dialog"], [aria-modal="true"]').forEach(node => node.remove());
      root.querySelectorAll("*").forEach(node => {
        const marker = [node.id, node.className, node.getAttribute("aria-label")]
          .filter(value => typeof value === "string")
          .join(" ");
        if (marker && chromePattern.test(marker)) node.remove();
      });

      const safeURL = (value, kind) => {
        const candidate = normalize(value, 10000);
        if (!candidate) return null;
        if (kind === "link" && candidate.startsWith("#")) return candidate;
        if (kind === "image" && /^data:image\/(png|jpeg|gif|webp);base64,/i.test(candidate)) {
          return candidate;
        }
        try {
          const url = new URL(candidate, document.baseURI);
          const schemes = kind === "link" ? new Set(["http:", "https:", "mailto:", "tel:"]) : new Set(["http:", "https:"]);
          return schemes.has(url.protocol) ? url.href : null;
        } catch (_) {
          return null;
        }
      };

      root.querySelectorAll("a").forEach(link => {
        const href = safeURL(link.getAttribute("href"), "link");
        if (href) link.setAttribute("href", href);
        else link.removeAttribute("href");
      });

      const normalizeSourceSet = value => {
        if (!value) return null;
        const candidates = value.split(",").map(candidate => {
          const parts = candidate.trim().split(/\s+/);
          const url = safeURL(parts.shift(), "image");
          return url ? [url, ...parts].join(" ") : null;
        }).filter(Boolean);
        return candidates.length ? candidates.join(", ") : null;
      };

      root.querySelectorAll("img").forEach(image => {
        const marker = [image.id, image.className, image.alt].filter(Boolean).join(" ");
        const width = Number.parseInt(image.getAttribute("width"), 10);
        const height = Number.parseInt(image.getAttribute("height"), 10);
        if (chromePattern.test(marker) || (width > 0 && width <= 2) || (height > 0 && height <= 2)) {
          image.remove();
          return;
        }

        const source = ["src", "data-src", "data-original", "data-lazy-src", "data-url"]
          .map(attribute => image.getAttribute(attribute))
          .find(Boolean);
        const src = safeURL(source, "image");
        if (!src) {
          image.remove();
          return;
        }
        image.setAttribute("src", src);
        const srcset = normalizeSourceSet(image.getAttribute("srcset") || image.getAttribute("data-srcset"));
        if (srcset) image.setAttribute("srcset", srcset);
        else image.removeAttribute("srcset");
        image.setAttribute("loading", "lazy");
        image.setAttribute("decoding", "async");
        image.setAttribute("referrerpolicy", "no-referrer");
      });

      root.querySelectorAll("source").forEach(source => {
        const srcset = normalizeSourceSet(source.getAttribute("srcset") || source.getAttribute("data-srcset"));
        if (srcset) source.setAttribute("srcset", srcset);
        else source.remove();
      });

      const allowedTags = [
        "a", "abbr", "article", "b", "blockquote", "br", "caption", "cite", "code",
        "dd", "del", "details", "div", "dl", "dt", "em", "figcaption", "figure",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "i", "img", "ins",
        "li", "main", "mark", "ol", "p", "picture", "pre", "q", "s", "section",
        "small", "source", "span", "strong", "sub", "summary", "sup", "table", "tbody",
        "td", "tfoot", "th", "thead", "time", "tr", "u", "ul"
      ];
      const allowedAttributes = [
        "alt", "colspan", "datetime", "decoding", "dir", "height", "href", "lang", "loading",
        "open", "referrerpolicy", "rowspan", "scope", "sizes", "src", "srcset", "title", "width"
      ];

      const cleanHTML = DOMPurify.sanitize(root, {
        ALLOWED_TAGS: allowedTags,
        ALLOWED_ATTR: allowedAttributes,
        ALLOW_ARIA_ATTR: false,
        ALLOW_DATA_ATTR: false,
        KEEP_CONTENT: true,
        RETURN_DOM_FRAGMENT: false
      });

      const cleanTemplate = document.createElement("template");
      cleanTemplate.innerHTML = cleanHTML;
      const cleanRoot = cleanTemplate.content;
      cleanRoot.querySelectorAll("a").forEach(link => {
        const href = safeURL(link.getAttribute("href"), "link");
        if (href) link.setAttribute("href", href);
        else link.removeAttribute("href");
      });
      cleanRoot.querySelectorAll("img").forEach(image => {
        const src = safeURL(image.getAttribute("src"), "image");
        if (src) image.setAttribute("src", src);
        else image.remove();
      });

      const container = document.createElement("div");
      container.append(cleanRoot.cloneNode(true));
      const textContent = normalize(container.textContent, 10000000) || "";
      if (textContent.length < 200) {
        return JSON.stringify({
          article: null,
          failure: { kind: classifyPage() === "unreadable" ? "insufficient" : classifyPage(), length: textContent.length }
        });
      }

      const pick = (...values) => values.map(value => normalize(value)).find(Boolean) || null;
      return JSON.stringify({
        article: {
          title: pick(article.title, structuredMetadata.title, openGraphMetadata.title),
          byline: pick(article.byline, structuredMetadata.byline, openGraphMetadata.byline),
          siteName: pick(article.siteName, structuredMetadata.siteName, openGraphMetadata.siteName),
          excerpt: pick(article.excerpt, structuredMetadata.excerpt, openGraphMetadata.excerpt),
          publishedTime: pick(article.publishedTime, structuredMetadata.publishedTime, openGraphMetadata.publishedTime),
          contentHTML: container.innerHTML,
          textContent,
          length: textContent.length,
          language: pick(article.lang, document.documentElement.lang),
          direction: pick(article.dir, document.documentElement.dir)
        },
        failure: null
      });
    })()
    """#
}
