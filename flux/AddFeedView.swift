//
//  AddFeedView.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import SwiftData
import SwiftUI

struct AddFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FeedStore.self) private var feedStore

    @State private var urlInput = ""
    @State private var parsedFeed: ParsedFeed?
    @State private var errorMessage: String?
    @State private var isChecking = false
    @State private var isSubscribing = false
    @State private var checkTask: Task<Void, Never>?
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/feed", text: $urlInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isURLFieldFocused)
                        .disabled(isChecking || isSubscribing)
                        .submitLabel(.go)
                        .onSubmit(beginCheck)
                } header: {
                    Text("Feed URL")
                } footer: {
                    Text("Flux detects RSS, Atom, and JSON Feed automatically.")
                }

                if let parsedFeed {
                    Section("Detected Feed") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(parsedFeed.title)
                                .font(.headline)
                            Text(parsedFeed.sourceURL.host ?? parsedFeed.sourceURL.absoluteString)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)

                        LabeledContent("Format", value: parsedFeed.format.rawValue)
                        LabeledContent("Articles", value: parsedFeed.articles.count.formatted())
                    }
                }

                if let errorMessage {
                    Section {
                        Label {
                            Text(errorMessage)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Error: \(errorMessage)")
                    }
                }

                Section {
                    if parsedFeed == nil {
                        Button(action: beginCheck) {
                            HStack {
                                Text("Check Feed")
                                Spacer()
                                if isChecking {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
                    } else {
                        Button(action: subscribe) {
                            HStack {
                                Text("Subscribe")
                                Spacer()
                                if isSubscribing {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isSubscribing)
                    }
                }
            }
            .navigationTitle("Add Feed")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }
            }
        }
        .presentationSizing(.form)
        .onAppear {
            isURLFieldFocused = true
        }
        .onChange(of: urlInput) {
            parsedFeed = nil
            errorMessage = nil
        }
        .onDisappear {
            checkTask?.cancel()
        }
    }

    private func beginCheck() {
        guard !isChecking,
              !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        isURLFieldFocused = false
        checkTask?.cancel()
        checkTask = Task { await checkFeed() }
    }

    private func checkFeed() async {
        let submittedInput = urlInput
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }

        do {
            let result = try await feedStore.previewFeed(
                from: submittedInput,
                modelContext: modelContext
            )
            guard !Task.isCancelled, submittedInput == urlInput else { return }
            parsedFeed = result
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, submittedInput == urlInput else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func subscribe() {
        guard let parsedFeed else { return }
        isSubscribing = true
        errorMessage = nil

        do {
            try feedStore.subscribe(to: parsedFeed, modelContext: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSubscribing = false
        }
    }
}
