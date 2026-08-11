//
//  ArticleWebView.swift
//  flux
//
//  Created by Codex on 2026/8/11.
//

import SwiftUI
import UIKit
import WebKit

struct ArticleWebViewFailure: Equatable {
    let url: URL
    let message: String
}

enum ArticleWebNavigationDestination: Equatable {
    case webView
    case externalApplication
    case unsupported
}

enum ArticleWebNavigationPolicy {
    private static let externalSchemes: Set<String> = [
        "facetime",
        "facetime-audio",
        "mailto",
        "sms",
        "tel",
    ]

    static func destination(for url: URL?) -> ArticleWebNavigationDestination {
        guard let scheme = url?.scheme?.lowercased(), !scheme.isEmpty else {
            return .unsupported
        }

        switch scheme {
        case "http", "https":
            return .webView
        case _ where externalSchemes.contains(scheme):
            return .externalApplication
        default:
            return .unsupported
        }
    }
}

struct ArticleWebView: UIViewRepresentable {
    let url: URL
    let reloadID: Int
    let onNavigationFailure: (ArticleWebViewFailure) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            requestedURL: url,
            reloadID: reloadID,
            onNavigationFailure: onNavigationFailure
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.loadRequestedURL(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            requestedURL: url,
            reloadID: reloadID,
            onNavigationFailure: onNavigationFailure,
            webView: webView
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var requestedURL: URL
        private var appliedReloadID: Int
        private var onNavigationFailure: (ArticleWebViewFailure) -> Void

        init(
            requestedURL: URL,
            reloadID: Int,
            onNavigationFailure: @escaping (ArticleWebViewFailure) -> Void
        ) {
            self.requestedURL = requestedURL
            appliedReloadID = reloadID
            self.onNavigationFailure = onNavigationFailure
        }

        func loadRequestedURL(in webView: WKWebView) {
            webView.load(URLRequest(url: requestedURL))
        }

        func update(
            requestedURL: URL,
            reloadID: Int,
            onNavigationFailure: @escaping (ArticleWebViewFailure) -> Void,
            webView: WKWebView
        ) {
            self.onNavigationFailure = onNavigationFailure

            if self.requestedURL != requestedURL {
                self.requestedURL = requestedURL
                appliedReloadID = reloadID
                loadRequestedURL(in: webView)
                return
            }

            guard appliedReloadID != reloadID else { return }

            appliedReloadID = reloadID
            if webView.url == nil || webView.reload() == nil {
                loadRequestedURL(in: webView)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            switch ArticleWebNavigationPolicy.destination(for: navigationAction.request.url) {
            case .webView:
                return .allow
            case .externalApplication:
                if let url = navigationAction.request.url {
                    _ = await UIApplication.shared.open(url)
                }
                return .cancel
            case .unsupported:
                return .cancel
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }

            switch ArticleWebNavigationPolicy.destination(for: navigationAction.request.url) {
            case .webView:
                webView.load(navigationAction.request)
            case .externalApplication:
                if let url = navigationAction.request.url {
                    UIApplication.shared.open(url)
                }
            case .unsupported:
                break
            }

            return nil
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            report(error, from: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            report(error, from: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let error = NSError(
                domain: "ArticleWebView",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "The webpage stopped responding.",
                ]
            )
            report(error, from: webView)
        }

        private func report(_ error: any Error, from webView: WKWebView) {
            let nsError = error as NSError
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
                return
            }

            let failureURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
                ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
                    .flatMap(URL.init(string:))
                ?? webView.url
                ?? requestedURL

            onNavigationFailure(
                ArticleWebViewFailure(
                    url: failureURL,
                    message: error.localizedDescription
                )
            )
        }
    }
}
