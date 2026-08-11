//
//  FeedIconView.swift
//  flux
//
//  Created by Codex on 2026/8/10.
//

import SwiftUI

struct FeedIconView: View {
    @Environment(FeedIconCache.self) private var iconCache

    @State private var loadedIcon: LoadedFeedIcon?
    @State private var failedURL: URL?

    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.12)

            if let loadedIcon, loadedIcon.url == url {
                Image(uiImage: loadedIcon.image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if let url, failedURL != url {
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentColor)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.primary.opacity(0.06), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: url) {
            await loadIcon()
        }
    }

    private var placeholder: some View {
        Image(systemName: "dot.radiowaves.up.forward")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.tint)
    }

    private func loadIcon() async {
        guard let url else {
            loadedIcon = nil
            failedURL = nil
            return
        }

        failedURL = nil
        let lookup = await iconCache.lookup(for: url)
        guard !Task.isCancelled else { return }

        if let image = lookup.image {
            withAnimation(.easeInOut(duration: 0.2)) {
                loadedIcon = LoadedFeedIcon(url: url, image: image)
            }
        }

        guard lookup.isStale else { return }
        if let image = await iconCache.refresh(for: url) {
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                loadedIcon = LoadedFeedIcon(url: url, image: image)
            }
        } else if lookup.image == nil, !Task.isCancelled {
            failedURL = url
        }
    }
}

private struct LoadedFeedIcon {
    let url: URL
    let image: UIImage
}
