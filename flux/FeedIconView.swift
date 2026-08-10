//
//  FeedIconView.swift
//  flux
//
//  Created by Codex on 2026/8/10.
//

import SwiftUI

struct FeedIconView: View {
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        AsyncImage(
            url: url,
            transaction: Transaction(animation: .easeInOut(duration: 0.2))
        ) { phase in
            ZStack {
                Color.accentColor.opacity(0.12)

                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                case .empty where url != nil:
                    ProgressView()
                        .controlSize(.small)
                        .tint(.accentColor)
                case .empty, .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.primary.opacity(0.06), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.tint)
    }
}
